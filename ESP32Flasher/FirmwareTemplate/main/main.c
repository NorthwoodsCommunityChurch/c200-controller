/*
 * ===========================================================================
 *                  CANON C200 CAMERA CONTROLLER
 *                     FOR ESP32-S3 ETHERNET BOARD
 * ===========================================================================
 *
 * This firmware turns the ESP32 into a camera controller that:
 * - Connects to Canon C200 via Ethernet (static IP)
 * - Connects to WiFi network (DHCP)
 * - Exposes HTTP API for Companion/Dashboard control
 *
 * Hardware: ESP32-S3 Ethernet Development Board (with W5500 chip)
 *
 * Network Architecture:
 *   [Dashboard/Companion] --WiFi-- [ESP32] --Ethernet-- [Canon C200]
 *
 * ===========================================================================
 */

#include <string.h>
#include <stdlib.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_eth.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "driver/gpio.h"
#include "driver/ledc.h"
#include "driver/spi_master.h"
#include "driver/spi_common.h"
#include "esp_eth_mac_spi.h"
#include "esp_eth_phy.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "cJSON.h"
#include "mdns.h"
#include "esp_heap_caps.h"
#include "esp_timer.h"
#include "esp_mac.h"
#include "esp_ota_ops.h"
#include "esp_app_format.h"
#include "driver/i2c.h"
#include "nvs.h"
#include "lwip/sockets.h"
#include "lwip/netdb.h"

// ===========================================================================
//          WIFI CREDENTIALS — sourced from local-only wifi_config.h
// ===========================================================================
//
// WIFI_SSID and WIFI_PASSWORD are defined in `wifi_config.h`, which is
// gitignored so credentials never enter the public repo. If you're setting
// up a fresh checkout: copy `wifi_config.example.h` to `wifi_config.h` and
// fill in your real network credentials.

#include "wifi_config.h"

#define WIFI_CHANNEL   0                              // 0 = auto-select

// ===========================================================================
//          CAMERA CONFIGURATION
// ===========================================================================

#define CAMERA_IP       "1.1.1.2"                     // Canon C200 IP
#define CAMERA_USER     "admin"                       // Browser Remote user
#define CAMERA_PASS     "admin"                       // Browser Remote password
#define CAMERA_BASE_URL "http://1.1.1.2"              // Camera base URL

// ESP32 Ethernet static IP (same subnet as camera)
#define ETH_STATIC_IP      "1.1.1.1"
#define ETH_STATIC_NETMASK "255.255.255.0"
#define ETH_STATIC_GW      "1.1.1.2"

// ===========================================================================
//          CAMERA NUMBER (set this per-device at flash time)
// ===========================================================================

#define CAMERA_NUMBER  0   // 0 = unset; 1–5 = camera position in Camera Positions app

// ===========================================================================
//          ETHERNET HARDWARE CONFIGURATION (W5500 SPI)
// ===========================================================================

#define ETH_SPI_HOST        SPI2_HOST
#define ETH_SPI_CLOCK_MHZ   12
#define ETH_SPI_PHY_RST_GPIO 9
#define ETH_SPI_PHY_ADDR     1

// SPI pins - Waveshare ESP32-S3-ETH board:
#define ETH_SPI_CS_GPIO      14
#define ETH_SPI_MOSI_GPIO    11
#define ETH_SPI_MISO_GPIO    12
#define ETH_SPI_SCLK_GPIO    13
#define ETH_SPI_INT_GPIO     10

// RGB LED pins for tally
#define TALLY_LED_RED_GPIO    21
#define TALLY_LED_GREEN_GPIO  17

// LEDC PWM config for brightness control
#define TALLY_LEDC_TIMER      LEDC_TIMER_0
#define TALLY_LEDC_MODE       LEDC_LOW_SPEED_MODE
#define TALLY_LEDC_RED_CH     LEDC_CHANNEL_0
#define TALLY_LEDC_GREEN_CH   LEDC_CHANNEL_1
#define TALLY_LEDC_DUTY_RES   LEDC_TIMER_8_BIT   // 0–255
#define TALLY_LEDC_FREQ_HZ    1000

static const char *TAG = "C200_CTRL";

#define FIRMWARE_VERSION "1.2.2"

// WiFi roaming: trigger an AP rescan when current signal drops below this.
// Pairs with WIFI_ALL_CHANNEL_SCAN + WIFI_CONNECT_AP_BY_SIGNAL so the reconnect
// picks the strongest AP for our SSID. -65 dBm matches the "good signal" bar
// threshold; below that we'd rather try another AP if one is available.
#define WIFI_ROAM_RSSI_THRESHOLD   -65
#define WIFI_ROAM_COOLDOWN_MS      30000

// Event group bits
#define WIFI_CONNECTED_BIT BIT0
#define ETH_CONNECTED_BIT  BIT1
#define ETH_FAIL_BIT       BIT3
#define CAMERA_READY_BIT   BIT4

static EventGroupHandle_t s_event_group;
static int s_retry_num = 0;
// Last time we kicked off a roam scan, in microseconds. Used to enforce
// WIFI_ROAM_COOLDOWN_MS so we don't thrash between two APs at threshold.
static int64_t last_roam_attempt_us = 0;

// Network interfaces
static esp_netif_t *wifi_netif = NULL;
static esp_netif_t *eth_netif = NULL;

// Store IP addresses
static esp_ip4_addr_t s_wifi_ip;
static esp_ip4_addr_t s_eth_ip;
static bool wifi_connected = false;
static bool eth_connected = false;
static bool camera_logged_in = false;
static bool camera_recording = false;
static int getcurprop_seq = 0;           // Current sequence number for polling

// Cached WiFi RSSI (dBm), updated every OLED redraw by fb_wifi_bars(). Read lock-free
// by ws_broadcast_state to avoid calling esp_wifi_sta_get_ap_info on the WS hot path,
// which can stall the camera_poll_task for tens of ms and trigger Canon session timeouts.
static volatile int cached_rssi_dbm = 0;

// HTTP server handle
static httpd_handle_t server = NULL;

// Camera state cache (updated by polling)
static SemaphoreHandle_t camera_state_mutex = NULL;
static cJSON *camera_state = NULL;

// HTTP response buffer
#define HTTP_BUFFER_SIZE 8192
static char http_buffer[HTTP_BUFFER_SIZE];

// Session cookies from camera login
static char camera_cookies[256] = "";

// Rate limiting for camera commands (prevent mashing)
static int64_t last_command_time_us = 0;
#define COMMAND_RATE_LIMIT_MS 200  // Minimum 200ms between commands

// Flag to trigger immediate recording state poll
static volatile bool poll_recording_now = false;

// Flag to pause polling for testing (controlled via /api/polling endpoint)
static volatile bool polling_paused = false;

// WebSocket client tracking
#define MAX_WS_CLIENTS 8
static int ws_fds[MAX_WS_CLIENTS];
static int ws_fd_count = 0;
static SemaphoreHandle_t ws_mutex = NULL;

// Forward declarations
static void update_camera_state(void);
static void update_recording_state(void);

// ===========================================================================
//          DEBUG & MONITORING
// ===========================================================================

// Debug statistics
static uint32_t camera_requests_total = 0;
static uint32_t camera_requests_failed = 0;
static uint32_t api_requests_total = 0;
static int64_t boot_time_us = 0;
static uint32_t min_free_heap = UINT32_MAX;
static char last_camera_error[128] = "none";
static char last_getcurprop_response[512] = "";  // Store last response for debugging

// ===========================================================================
//          OLED ASSIGNMENT DATA (set via POST /api/display)
// ===========================================================================

// Stores the camera assignment pushed from Camera Positions app
static char oled_operator[32] = "";   // operator name
static char oled_lens[32] = "";       // first lens name
static int  oled_camera_number = 0;   // camera number (0 = not set; shows system status)
static SemaphoreHandle_t oled_data_mutex = NULL;

// ===========================================================================
//          OTA UPDATE STATE
// ===========================================================================

typedef enum {
    OTA_STATE_IDLE = 0,
    OTA_STATE_DOWNLOADING,
    OTA_STATE_FLASHING,
    OTA_STATE_REBOOTING,
    OTA_STATE_ERROR
} ota_state_t;

static volatile ota_state_t ota_state = OTA_STATE_IDLE;
static volatile int ota_progress = 0;
static char ota_error[128] = "";
static SemaphoreHandle_t ota_mutex = NULL;
static char ota_url[512] = "";

// ===========================================================================
//          OLED DISPLAY (SSD1306 128x32, I2C)
// ===========================================================================

#define OLED_I2C_PORT   I2C_NUM_0
#define OLED_SDA_GPIO   16
#define OLED_SCL_GPIO   18
#define OLED_I2C_ADDR   0x3C

// 5x7 font, ASCII 32-127, column-major encoding
// Each byte = 1 pixel column; bit 0 = top row, bit 6 = bottom row
static const uint8_t font5x7[96][5] = {
    {0x00,0x00,0x00,0x00,0x00}, // ' '
    {0x00,0x00,0x5F,0x00,0x00}, // '!'
    {0x00,0x07,0x00,0x07,0x00}, // '"'
    {0x14,0x7F,0x14,0x7F,0x14}, // '#'
    {0x24,0x2A,0x7F,0x2A,0x12}, // '$'
    {0x23,0x13,0x08,0x64,0x62}, // '%'
    {0x36,0x49,0x55,0x22,0x50}, // '&'
    {0x00,0x05,0x03,0x00,0x00}, // '\''
    {0x00,0x1C,0x22,0x41,0x00}, // '('
    {0x00,0x41,0x22,0x1C,0x00}, // ')'
    {0x08,0x2A,0x1C,0x2A,0x08}, // '*'
    {0x08,0x08,0x3E,0x08,0x08}, // '+'
    {0x00,0x50,0x30,0x00,0x00}, // ','
    {0x08,0x08,0x08,0x08,0x08}, // '-'
    {0x00,0x60,0x60,0x00,0x00}, // '.'
    {0x20,0x10,0x08,0x04,0x02}, // '/'
    {0x3E,0x51,0x49,0x45,0x3E}, // '0'
    {0x00,0x42,0x7F,0x40,0x00}, // '1'
    {0x42,0x61,0x51,0x49,0x46}, // '2'
    {0x21,0x41,0x45,0x4B,0x31}, // '3'
    {0x18,0x14,0x12,0x7F,0x10}, // '4'
    {0x27,0x45,0x45,0x45,0x39}, // '5'
    {0x3C,0x4A,0x49,0x49,0x30}, // '6'
    {0x01,0x71,0x09,0x05,0x03}, // '7'
    {0x36,0x49,0x49,0x49,0x36}, // '8'
    {0x06,0x49,0x49,0x29,0x1E}, // '9'
    {0x00,0x36,0x36,0x00,0x00}, // ':'
    {0x00,0x56,0x36,0x00,0x00}, // ';'
    {0x00,0x08,0x14,0x22,0x41}, // '<'
    {0x14,0x14,0x14,0x14,0x14}, // '='
    {0x41,0x22,0x14,0x08,0x00}, // '>'
    {0x02,0x01,0x51,0x09,0x06}, // '?'
    {0x32,0x49,0x79,0x41,0x3E}, // '@'
    {0x7E,0x11,0x11,0x11,0x7E}, // 'A'
    {0x7F,0x49,0x49,0x49,0x36}, // 'B'
    {0x3E,0x41,0x41,0x41,0x22}, // 'C'
    {0x7F,0x41,0x41,0x22,0x1C}, // 'D'
    {0x7F,0x49,0x49,0x49,0x41}, // 'E'
    {0x7F,0x09,0x09,0x01,0x01}, // 'F'
    {0x3E,0x41,0x49,0x49,0x7A}, // 'G'
    {0x7F,0x08,0x08,0x08,0x7F}, // 'H'
    {0x00,0x41,0x7F,0x41,0x00}, // 'I'
    {0x20,0x40,0x41,0x3F,0x01}, // 'J'
    {0x7F,0x08,0x14,0x22,0x41}, // 'K'
    {0x7F,0x40,0x40,0x40,0x40}, // 'L'
    {0x7F,0x02,0x04,0x02,0x7F}, // 'M'
    {0x7F,0x04,0x08,0x10,0x7F}, // 'N'
    {0x3E,0x41,0x41,0x41,0x3E}, // 'O'
    {0x7F,0x09,0x09,0x09,0x06}, // 'P'
    {0x3E,0x41,0x51,0x21,0x5E}, // 'Q'
    {0x7F,0x09,0x19,0x29,0x46}, // 'R'
    {0x46,0x49,0x49,0x49,0x31}, // 'S'
    {0x01,0x01,0x7F,0x01,0x01}, // 'T'
    {0x3F,0x40,0x40,0x40,0x3F}, // 'U'
    {0x1F,0x20,0x40,0x20,0x1F}, // 'V'
    {0x3F,0x40,0x38,0x40,0x3F}, // 'W'
    {0x63,0x14,0x08,0x14,0x63}, // 'X'
    {0x03,0x04,0x78,0x04,0x03}, // 'Y'
    {0x61,0x51,0x49,0x45,0x43}, // 'Z'
    {0x00,0x7F,0x41,0x41,0x00}, // '['
    {0x02,0x04,0x08,0x10,0x20}, // '\'
    {0x00,0x41,0x41,0x7F,0x00}, // ']'
    {0x04,0x02,0x01,0x02,0x04}, // '^'
    {0x40,0x40,0x40,0x40,0x40}, // '_'
    {0x00,0x01,0x02,0x04,0x00}, // '`'
    {0x20,0x54,0x54,0x54,0x78}, // 'a'
    {0x7F,0x48,0x44,0x44,0x38}, // 'b'
    {0x38,0x44,0x44,0x44,0x20}, // 'c'
    {0x38,0x44,0x44,0x48,0x7F}, // 'd'
    {0x38,0x54,0x54,0x54,0x18}, // 'e'
    {0x08,0x7E,0x09,0x01,0x02}, // 'f'
    {0x08,0x14,0x54,0x54,0x3C}, // 'g'
    {0x7F,0x08,0x04,0x04,0x78}, // 'h'
    {0x00,0x44,0x7D,0x40,0x00}, // 'i'
    {0x20,0x40,0x44,0x3D,0x00}, // 'j'
    {0x7F,0x10,0x28,0x44,0x00}, // 'k'
    {0x00,0x41,0x7F,0x40,0x00}, // 'l'
    {0x7C,0x04,0x18,0x04,0x78}, // 'm'
    {0x7C,0x08,0x04,0x04,0x78}, // 'n'
    {0x38,0x44,0x44,0x44,0x38}, // 'o'
    {0x7C,0x14,0x14,0x14,0x08}, // 'p'
    {0x08,0x14,0x14,0x18,0x7C}, // 'q'
    {0x7C,0x08,0x04,0x04,0x08}, // 'r'
    {0x48,0x54,0x54,0x54,0x20}, // 's'
    {0x04,0x3F,0x44,0x40,0x20}, // 't'
    {0x3C,0x40,0x40,0x20,0x7C}, // 'u'
    {0x1C,0x20,0x40,0x20,0x1C}, // 'v'
    {0x3C,0x40,0x30,0x40,0x3C}, // 'w'
    {0x44,0x28,0x10,0x28,0x44}, // 'x'
    {0x0C,0x50,0x50,0x50,0x3C}, // 'y'
    {0x44,0x64,0x54,0x4C,0x44}, // 'z'
    {0x00,0x08,0x36,0x41,0x00}, // '{'
    {0x00,0x00,0x7F,0x00,0x00}, // '|'
    {0x00,0x41,0x36,0x08,0x00}, // '}'
    {0x08,0x08,0x2A,0x1C,0x08}, // '~'
    {0x08,0x1C,0x2A,0x08,0x08}, // DEL
};

static esp_err_t oled_write_cmd(uint8_t cmd)
{
    i2c_cmd_handle_t h = i2c_cmd_link_create();
    i2c_master_start(h);
    i2c_master_write_byte(h, (OLED_I2C_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(h, 0x00, true);   // control byte: Co=0, D/C=0 (command)
    i2c_master_write_byte(h, cmd, true);
    i2c_master_stop(h);
    esp_err_t ret = i2c_master_cmd_begin(OLED_I2C_PORT, h, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(h);
    return ret;
}

static esp_err_t oled_write_data(const uint8_t *data, size_t len)
{
    i2c_cmd_handle_t h = i2c_cmd_link_create();
    i2c_master_start(h);
    i2c_master_write_byte(h, (OLED_I2C_ADDR << 1) | I2C_MASTER_WRITE, true);
    i2c_master_write_byte(h, 0x40, true);   // control byte: Co=0, D/C=1 (data)
    i2c_master_write(h, data, len, true);
    i2c_master_stop(h);
    esp_err_t ret = i2c_master_cmd_begin(OLED_I2C_PORT, h, pdMS_TO_TICKS(100));
    i2c_cmd_link_delete(h);
    return ret;
}

static esp_err_t oled_init(void)
{
    // Delete driver first so re-init works cleanly after hot-unplug
    i2c_driver_delete(OLED_I2C_PORT);

    i2c_config_t conf = {
        .mode             = I2C_MODE_MASTER,
        .sda_io_num       = OLED_SDA_GPIO,
        .scl_io_num       = OLED_SCL_GPIO,
        .sda_pullup_en    = GPIO_PULLUP_ENABLE,
        .scl_pullup_en    = GPIO_PULLUP_ENABLE,
        .master.clk_speed = 400000,
    };
    i2c_param_config(OLED_I2C_PORT, &conf);
    i2c_driver_install(OLED_I2C_PORT, I2C_MODE_MASTER, 0, 0, 0);

    vTaskDelay(pdMS_TO_TICKS(100));   // let display power up

    // Probe the device — bail early if nothing responds
    esp_err_t ret = oled_write_cmd(0xAE); // display off
    if (ret != ESP_OK) return ret;

    // Init sequence for SSD1306 128x32
    oled_write_cmd(0xD5); oled_write_cmd(0x80); // clock divider / osc freq
    oled_write_cmd(0xA8); oled_write_cmd(0x1F); // mux ratio = 32 (0x1F = 31)
    oled_write_cmd(0xD3); oled_write_cmd(0x00); // display offset = 0
    oled_write_cmd(0x40);             // start line = 0
    oled_write_cmd(0x8D); oled_write_cmd(0x14); // charge pump on
    oled_write_cmd(0x20); oled_write_cmd(0x00); // horizontal addressing mode
    oled_write_cmd(0xA0);             // segment remap normal (col 0 → SEG0)
    oled_write_cmd(0xC0);             // COM scan direction normal
    oled_write_cmd(0xDA); oled_write_cmd(0x02); // COM pins = 0x02 for 128x32
    oled_write_cmd(0x81); oled_write_cmd(0x8F); // contrast
    oled_write_cmd(0xD9); oled_write_cmd(0xF1); // pre-charge period
    oled_write_cmd(0xDB); oled_write_cmd(0x40); // VCOMH deselect level
    oled_write_cmd(0xA4);             // output follows RAM content
    oled_write_cmd(0xA6);             // normal display (not inverted)
    oled_write_cmd(0xAF);             // display on

    ESP_LOGI(TAG, "OLED: SSD1306 128x32 initialized (SDA=%d SCL=%d)",
             OLED_SDA_GPIO, OLED_SCL_GPIO);
    return ESP_OK;
}

// ---- PORTRAIT FRAMEBUFFER (32 wide × 128 tall logical) ----
//
// The physical tally box was reoriented — the operator now reads the OLED as a portrait
// (32 wide × 128 tall) display, but the panel itself is still a 128×32 landscape SSD1306.
// We render to a logical portrait framebuffer and rotate at flush time so text reads
// correctly from the operator's perspective.
//
// Rotation: 90° CCW. Logical (lx, ly) → physical (px = 127 - ly, py = lx).
// Page/bit unpacking: fb[py/8][px], bit (py % 8).

static uint8_t fb[4][128] = {0};   // page-major, matches SSD1306 layout

static void fb_clear(void) {
    memset(fb, 0, sizeof(fb));
}

static inline void fb_put_pixel(int lx, int ly, int on) {
    if (lx < 0 || lx >= 32 || ly < 0 || ly >= 128) return;
    int px = 127 - ly;
    int py = lx;
    int page = py >> 3;
    int bit  = py & 7;
    if (on) fb[page][px] |=  (uint8_t)(1u << bit);
    else    fb[page][px] &= (uint8_t)~(1u << bit);
}

// Draw a 5x7 character at portrait text coords (row ∈ [0,15], col ∈ [0,4]).
// Font is column-major; each byte = vertical column, bit 0 = top row.
static void fb_draw_char(int row, int col, char ch) {
    if (row < 0 || row > 15 || col < 0 || col > 4) return;
    uint8_t ci = (uint8_t)ch;
    if (ci < 32 || ci > 127) ci = 32;
    const uint8_t *glyph = font5x7[ci - 32];
    int lx = col * 6;   // 6-px horizontal pitch (5 + 1 gap)
    int ly = row * 8;   // 8-px vertical pitch  (7 + 1 gap)
    for (int fc = 0; fc < 5; fc++) {
        uint8_t g = glyph[fc];
        for (int fr = 0; fr < 7; fr++) {
            if (g & (1u << fr)) fb_put_pixel(lx + fc, ly + fr, 1);
        }
    }
}

// Print a string at (row, col). Clips at column 5 (portrait is only 5 chars wide).
static void fb_print(int row, int col, const char *str) {
    while (*str && col < 5) {
        fb_draw_char(row, col, *str);
        col++;
        str++;
    }
}

// Map current WiFi RSSI to a bar count 0-4. Returns 0 if STA not associated.
static int fb_wifi_bars(void) {
    if (!wifi_connected) { cached_rssi_dbm = 0; return 0; }
    wifi_ap_record_t ap_info;
    if (esp_wifi_sta_get_ap_info(&ap_info) != ESP_OK) { cached_rssi_dbm = 0; return 0; }
    int rssi = ap_info.rssi;
    cached_rssi_dbm = rssi;   // publish for ws_broadcast_state
    if (rssi >= -55) return 4;
    if (rssi >= -65) return 3;
    if (rssi >= -75) return 2;
    if (rssi >= -85) return 1;
    return 0;
}

// Draw a 4-bar WiFi signal icon at portrait text row (8 px tall slot), left-aligned at lx=3.
// Filled bars for current level; outlined bars for the rest, so "X of 4" is always visible.
// Bar heights from short to tall: 2, 4, 6, 8 px. Bar width 5 px, gap 2 px.
static void fb_draw_wifi_bars(int row, int bars) {
    int base_y = row * 8 + 7;   // bottom of 8-px slot
    for (int b = 0; b < 4; b++) {
        int x_start = 3 + b * 7;
        int h = 2 + b * 2;
        int filled = (b < bars);
        for (int dx = 0; dx < 5; dx++) {
            for (int dy = 0; dy < h; dy++) {
                int on = filled
                    ? 1
                    : (dx == 0 || dx == 4 || dy == 0 || dy == h - 1);
                fb_put_pixel(x_start + dx, base_y - dy, on);
            }
        }
    }
}

// Flush framebuffer to the physical device (4 × 128 B = 512 B total).
static esp_err_t oled_flush(void) {
    esp_err_t ret;
    ret = oled_write_cmd(0x22); if (ret != ESP_OK) return ret;  // page addr
    ret = oled_write_cmd(0);    if (ret != ESP_OK) return ret;  // page start
    ret = oled_write_cmd(3);    if (ret != ESP_OK) return ret;  // page end
    ret = oled_write_cmd(0x21); if (ret != ESP_OK) return ret;  // col addr
    ret = oled_write_cmd(0);    if (ret != ESP_OK) return ret;  // col start
    ret = oled_write_cmd(127);  if (ret != ESP_OK) return ret;  // col end
    // One page per I2C transaction — keeps payload well within driver limits.
    for (int p = 0; p < 4; p++) {
        ret = oled_write_data(fb[p], 128);
        if (ret != ESP_OK) return ret;
    }
    return ESP_OK;
}

// Log memory stats
static void log_memory_stats(const char *label)
{
    uint32_t free_heap = esp_get_free_heap_size();
    uint32_t free_internal = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    uint32_t free_psram = heap_caps_get_free_size(MALLOC_CAP_SPIRAM);
    uint32_t min_heap = esp_get_minimum_free_heap_size();

    if (free_heap < min_free_heap) {
        min_free_heap = free_heap;
    }

    ESP_LOGI(TAG, "[MEM %s] Heap: %lu KB | Internal: %lu KB | PSRAM: %lu KB | Min: %lu KB",
             label,
             free_heap / 1024,
             free_internal / 1024,
             free_psram / 1024,
             min_heap / 1024);
}

// ===========================================================================
//          TALLY LED CONTROL
// ===========================================================================

typedef enum {
    TALLY_OFF = 0,
    TALLY_PROGRAM,   // Red LED
    TALLY_PREVIEW,   // Green LED
    TALLY_BOTH       // Amber (both LEDs)
} tally_state_t;

static tally_state_t current_tally_state = TALLY_OFF;
static SemaphoreHandle_t tally_mutex = NULL;
// Boot default intentionally dim (~10 %) so a tally command arriving before the
// dashboard has re-sent the saved brightness after a reboot doesn't flash the
// LED at 100 %. The dashboard overrides this within seconds on WS reconnect.
static uint8_t tally_brightness = 25;
static int64_t last_tally_command_us = 0;  // timestamp of last tally command (microseconds)
#define TALLY_WATCHDOG_MS 8000             // dashboard contact lost after this long with no command

// Initialize LEDC PWM for RGB LED brightness control
static void tally_led_init(void)
{
    ESP_LOGI(TAG, "Initializing tally LED PWM (Red=%d, Green=%d)",
             TALLY_LED_RED_GPIO, TALLY_LED_GREEN_GPIO);

    ledc_timer_config_t timer = {
        .speed_mode      = TALLY_LEDC_MODE,
        .timer_num       = TALLY_LEDC_TIMER,
        .duty_resolution = TALLY_LEDC_DUTY_RES,
        .freq_hz         = TALLY_LEDC_FREQ_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ledc_timer_config(&timer);

    ledc_channel_config_t red_ch = {
        .speed_mode = TALLY_LEDC_MODE,
        .channel    = TALLY_LEDC_RED_CH,
        .timer_sel  = TALLY_LEDC_TIMER,
        .gpio_num   = TALLY_LED_RED_GPIO,
        .duty       = 0,
        .hpoint     = 0,
        .intr_type  = LEDC_INTR_DISABLE,
    };
    ledc_channel_config(&red_ch);

    ledc_channel_config_t green_ch = {
        .speed_mode = TALLY_LEDC_MODE,
        .channel    = TALLY_LEDC_GREEN_CH,
        .timer_sel  = TALLY_LEDC_TIMER,
        .gpio_num   = TALLY_LED_GREEN_GPIO,
        .duty       = 0,
        .hpoint     = 0,
        .intr_type  = LEDC_INTR_DISABLE,
    };
    ledc_channel_config(&green_ch);

    tally_mutex = xSemaphoreCreateMutex();
    ESP_LOGI(TAG, "Tally LED PWM initialized");
}

static void display_task(void *pvParameters)
{
    vTaskDelay(pdMS_TO_TICKS(500));   // brief pause for power stability

    bool oled_ok = (oled_init() == ESP_OK);
    if (oled_ok) {
        fb_clear();
        oled_flush();
    }

    TickType_t last_reinit = xTaskGetTickCount();

    // Dirty-flag cache: only redraw + flush when content has changed.
    int   prev_cam        = -2;                     // -2 to force initial draw
    char  prev_op[32]     = {0};
    char  prev_lens[32]   = {0};
    bool  prev_wifi       = !wifi_connected;
    bool  prev_eth        = !eth_connected;
    bool  prev_cam_ok     = !camera_logged_in;
    bool  prev_rec        = !camera_recording;
    int   prev_bars       = -1;                     // force first draw
    tally_state_t prev_tally = (tally_state_t)-1;

    while (1) {
        // If display is absent or was unplugged, retry init every 2 seconds
        if (!oled_ok) {
            if ((xTaskGetTickCount() - last_reinit) >= pdMS_TO_TICKS(2000)) {
                last_reinit = xTaskGetTickCount();
                oled_ok = (oled_init() == ESP_OK);
                if (oled_ok) {
                    ESP_LOGI(TAG, "OLED: display reconnected");
                    fb_clear();
                    oled_flush();
                    prev_cam = -2; // force redraw after reinit
                }
            }
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        // Snapshot display data under mutex
        int snap_cam;
        char snap_op[32], snap_lens[32];
        if (oled_data_mutex && xSemaphoreTake(oled_data_mutex, pdMS_TO_TICKS(50))) {
            snap_cam = oled_camera_number;
            strlcpy(snap_op,   oled_operator, sizeof(snap_op));
            strlcpy(snap_lens, oled_lens,     sizeof(snap_lens));
            xSemaphoreGive(oled_data_mutex);
        } else {
            snap_cam = 0; snap_op[0] = snap_lens[0] = '\0';
        }

        // Poll RSSI bar count — cheap, runs every 500 ms.
        int bars = fb_wifi_bars();

        // Dirty check — skip the flush entirely when nothing has changed.
        bool changed = (snap_cam != prev_cam)
                    || (strcmp(snap_op,   prev_op)   != 0)
                    || (strcmp(snap_lens, prev_lens) != 0)
                    || (wifi_connected   != prev_wifi)
                    || (eth_connected    != prev_eth)
                    || (camera_logged_in != prev_cam_ok)
                    || (camera_recording != prev_rec)
                    || (bars             != prev_bars)
                    || (current_tally_state != prev_tally);
        if (!changed) { vTaskDelay(pdMS_TO_TICKS(500)); continue; }

        // --- Build the new frame in the portrait framebuffer (32w × 128h logical) ---
        fb_clear();
        char buf[8];

        // Oh Hi + WiFi bars always live at the top. Camera details (when assigned) stack below.
        fb_print(0, 0, "Oh Hi");
        fb_print(2, 0, "WiFi");
        fb_draw_wifi_bars(3, bars);

        if (snap_cam > 0) {
            // Runtime camera number set by the dashboard via /api/display.
            // Tally state intentionally NOT rendered as text — the physical LED
            // already communicates program/preview status.
            snprintf(buf, sizeof(buf), "Cam %d", (snap_cam > 99) ? 99 : snap_cam);
            fb_print(5, 0, buf);

            fb_print(7, 0, "Op");
            char o1[6] = {0}, o2[6] = {0};
            strlcpy(o1, snap_op, sizeof(o1));
            if (strlen(snap_op) > 5) strlcpy(o2, snap_op + 5, sizeof(o2));
            fb_print(8, 0, o1);
            fb_print(9, 0, o2);

            fb_print(11, 0, "Lens");
            char l1[6] = {0}, l2[6] = {0};
            strlcpy(l1, snap_lens, sizeof(l1));
            if (strlen(snap_lens) > 5) strlcpy(l2, snap_lens + 5, sizeof(l2));
            fb_print(12, 0, l1);
            fb_print(13, 0, l2);
        }
#if CAMERA_NUMBER > 0
        else {
            // Compile-time camera number fallback (no runtime /api/display yet).
            snprintf(buf, sizeof(buf), "Cam %d", CAMERA_NUMBER);
            fb_print(5, 0, buf);
        }
#endif

        // Flush once per frame. On I2C failure, mark display unreachable for retry.
        if (oled_flush() != ESP_OK) {
            oled_ok = false;
            last_reinit = xTaskGetTickCount();
        } else {
            prev_cam = snap_cam;
            strlcpy(prev_op,   snap_op,   sizeof(prev_op));
            strlcpy(prev_lens, snap_lens, sizeof(prev_lens));
            prev_wifi   = wifi_connected;
            prev_eth    = eth_connected;
            prev_cam_ok = camera_logged_in;
            prev_rec    = camera_recording;
            prev_bars   = bars;
            prev_tally  = current_tally_state;
        }

        vTaskDelay(pdMS_TO_TICKS(500));   // refresh every 500 ms
    }
}

static void ledc_set_tally(ledc_channel_t channel, uint8_t on)
{
    uint32_t duty = on ? (uint32_t)tally_brightness : 0;
    ledc_set_duty(TALLY_LEDC_MODE, channel, duty);
    ledc_update_duty(TALLY_LEDC_MODE, channel);
}

// ---- IDENTIFY (5s red+green blink) ----
//
// An operator taps "Identify" in the app. We blink both LEDs together (amber) at 2 Hz
// for 5 s, then restore whatever tally state was active before. A live program/preview
// command arriving during identify cancels it and wins immediately.
//
// Abort signal is a FreeRTOS task notification, NOT vTaskDelete — the task may be
// holding tally_mutex when asked to stop, and vTaskDelete would leak the mutex.
// xTaskNotifyWait yields between blinks; on notification the task exits cleanly.

static TaskHandle_t identify_task_handle = NULL;
static tally_state_t identify_saved_state = TALLY_OFF;

// Set tally LED state (respects current brightness)
static void tally_led_set(tally_state_t state)
{
    if (!tally_mutex) return;
    if (!xSemaphoreTake(tally_mutex, pdMS_TO_TICKS(100))) return;

    current_tally_state = state;

    switch (state) {
        case TALLY_OFF:
            ledc_set_tally(TALLY_LEDC_RED_CH, 0);
            ledc_set_tally(TALLY_LEDC_GREEN_CH, 0);
            ESP_LOGI(TAG, "Tally: OFF");
            break;
        case TALLY_PROGRAM:
            ledc_set_tally(TALLY_LEDC_RED_CH, 1);
            ledc_set_tally(TALLY_LEDC_GREEN_CH, 0);
            ESP_LOGI(TAG, "Tally: PROGRAM (red, brightness=%d)", tally_brightness);
            break;
        case TALLY_PREVIEW:
            ledc_set_tally(TALLY_LEDC_RED_CH, 0);
            ledc_set_tally(TALLY_LEDC_GREEN_CH, 1);
            ESP_LOGI(TAG, "Tally: PREVIEW (green, brightness=%d)", tally_brightness);
            break;
        case TALLY_BOTH:
            ledc_set_tally(TALLY_LEDC_RED_CH, 1);
            ledc_set_tally(TALLY_LEDC_GREEN_CH, 1);
            ESP_LOGI(TAG, "Tally: BOTH (amber, brightness=%d)", tally_brightness);
            break;
    }

    xSemaphoreGive(tally_mutex);
}

// Blinks both LEDs (amber) at 2 Hz for 5 s, then restores saved_state.
// Aborts cleanly on task notification.
static void identify_task(void *pvParameters)
{
    for (int i = 0; i < 10; i++) {   // 10 × 250 ms = 5 s
        tally_led_set((i & 1) ? TALLY_OFF : TALLY_BOTH);
        // Wait up to 250 ms for an abort notification. Any notification cancels.
        uint32_t notified = 0;
        if (xTaskNotifyWait(0, UINT32_MAX, &notified, pdMS_TO_TICKS(250)) == pdTRUE) {
            ESP_LOGI(TAG, "Identify aborted by incoming tally command");
            identify_task_handle = NULL;
            vTaskDelete(NULL);
            return;  // unreachable
        }
    }
    // Completed normally — restore whatever tally was before identify started.
    tally_led_set(identify_saved_state);
    ESP_LOGI(TAG, "Identify complete, restored to state=%d", identify_saved_state);
    identify_task_handle = NULL;
    vTaskDelete(NULL);
}

// Cancels a running identify (if any) so live tally always wins.
// Called from tally_handler before it applies a new state.
static void identify_cancel_if_running(void)
{
    if (identify_task_handle != NULL) {
        xTaskNotify(identify_task_handle, 0x1, eSetBits);
    }
}

// POST /api/tally/identify — 5 s blink on both LEDs to help locate a physical box.
static esp_err_t identify_handler(httpd_req_t *req)
{
    api_requests_total++;

    // If identify is already running, cancel and wait briefly for the task to exit.
    if (identify_task_handle != NULL) {
        xTaskNotify(identify_task_handle, 0x1, eSetBits);
        for (int i = 0; i < 30 && identify_task_handle != NULL; i++) {
            vTaskDelay(pdMS_TO_TICKS(10));
        }
    }

    // Capture current tally state so we can restore it after 5 s.
    identify_saved_state = current_tally_state;

    BaseType_t ok = xTaskCreate(
        identify_task, "identify", 2048, NULL, 5, &identify_task_handle);
    if (ok != pdPASS) {
        identify_task_handle = NULL;
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Failed to start identify");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Identify started (saved state=%d)", identify_saved_state);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"status\":\"ok\"}");
    return ESP_OK;
}

// ===========================================================================
//          TSL UMD DIRECT LISTENER (phase 2 — board is the tally endpoint)
// ===========================================================================
//
// Each board listens directly to the video switcher's TSL feed on a TCP port,
// filters by its configured tally index, applies the LED. The dashboard is no
// longer in the tally critical path. Config (index, port, swap) is pushed from
// the dashboard over the existing /ws WebSocket and persisted to NVS so the
// board comes back configured after any reboot.
//
// Two pieces of behavior are ported from the dashboard's TSLClient/Camera.swift
// so the board renders correctly on its own:
//   - Program-wins resolution: PGM beats PVW when both bits are set (Ross sends
//     T1+T2 on a PGM packet because it considers PGM "currently visible").
//   - 150 ms OFF debounce: Ross emits a transient OFF between a camera leaving
//     PGM and the auto-PVW that follows the next cut. Applying the OFF
//     immediately makes the LED visibly blink dark in fast-cut sequences.
//     Deferring the OFF for 150 ms absorbs the transient.

#define TSL_NVS_NAMESPACE   "tally_cfg"
#define TSL_NVS_KEY_INDEX   "idx"
#define TSL_NVS_KEY_PORT    "port"
#define TSL_NVS_KEY_SWAP    "swap"

#define TSL_DEFAULT_PORT    5200
#define TSL_RECV_BUFSZ      1024
#define TSL_OFF_DEBOUNCE_US (150LL * 1000LL)

static int      s_tsl_index = 0;          // 0 = unconfigured; board does nothing
static uint16_t s_tsl_port  = TSL_DEFAULT_PORT;
static bool     s_tsl_swap  = false;
static SemaphoreHandle_t s_tsl_cfg_mutex = NULL;

// Most recent applied state, used to detect transitions for the OFF debounce.
static bool     s_tsl_state_program = false;
static bool     s_tsl_state_preview = false;
// 0 = no OFF pending; else absolute timestamp (esp_timer microseconds) when the
// deferred OFF should be applied. Cancelled if a new non-OFF packet arrives.
static int64_t  s_tsl_pending_off_us = 0;

// ---- Diagnostic counters (1.3.0+) ----
// All exposed via /api/status so the dashboard can prove each link of the
// Carbonite → TCP → parser → filter chain is working. Single-writer (TSL
// listener task) / single-reader (HTTP handler) pattern; volatile so the
// reader sees fresh values without a mutex. int64 has potential read tearing
// on 32-bit reads, but for diagnostics we accept the rare half-update.
static volatile bool     s_tsl_diag_client_connected = false;
static volatile uint32_t s_tsl_diag_clients_ever     = 0;   // accept() count since boot
static volatile uint32_t s_tsl_diag_packets_total    = 0;   // every successfully parsed packet
static volatile uint32_t s_tsl_diag_packets_matched  = 0;   // packets where index == s_tsl_index
static volatile int64_t  s_tsl_diag_last_packet_us   = 0;   // esp_timer time of last parsed pkt
static volatile int      s_tsl_diag_last_index_seen  = 0;   // index field of last parsed pkt
static volatile uint8_t  s_tsl_diag_last_state       = 0;   // 0=off 1=pgm 2=pvw 3=both

// Parse one TSL UMD packet starting at &data[*offset]. Advances *offset past
// the packet on success. Returns false if data is incomplete (don't advance) or
// the header byte is unrecognizable (advances by 1 to resync). Supports both
// TSL UMD 3.1 (fixed 18 bytes) and TSL UMD 5.0 (variable length).
static bool tsl_parse_one(const uint8_t *data, size_t len, size_t *offset,
                          int *out_index, bool *out_program, bool *out_preview)
{
    if (*offset + 4 > len) return false;
    const uint8_t *p = data + *offset;
    size_t remaining = len - *offset;

    int pbc = (int)p[0] | ((int)p[1] << 8);
    uint8_t version = p[2];
    size_t total_msg_len = (size_t)pbc + 2;

    // TSL UMD 5.0: PBC field plus version byte = 0
    if (pbc >= 10 && pbc <= 1000 && version == 0x00) {
        if (total_msg_len > remaining) return false;   // incomplete, wait
        if (total_msg_len < 12) {                       // malformed
            *offset += 1;
            return false;
        }
        int index = (int)p[6] | ((int)p[7] << 8);
        int control = (int)p[8] | ((int)p[9] << 8);
        int t1 = control & 0x03;
        int t2 = (control >> 2) & 0x03;
        *out_index = index;
        *out_program = t1 > 0;
        *out_preview = t2 > 0;
        *offset += total_msg_len;
        return true;
    }

    // TSL UMD 3.1: fixed 18-byte packets — the first two bytes don't form a
    // valid PBC because byte 0 is the address (0-126) and byte 1 is the
    // control byte, so pbc > 1000 here indicates 3.1.
    if (pbc > 1000) {
        if (remaining < 18) return false;
        uint8_t address = p[0];
        uint8_t control = p[1];
        int t1 = control & 0x03;
        int t2 = (control >> 2) & 0x03;
        *out_index   = (int)address + 1;  // 3.1 addresses are 0-based; we use 1-based
        *out_program = t1 > 0;
        *out_preview = t2 > 0;
        *offset += 18;
        return true;
    }

    // Unrecognizable byte — skip one to resync rather than dropping the buffer.
    *offset += 1;
    return false;
}

// Apply incoming tally state (after parser + index filter). Implements the
// program-wins rule and the OFF debounce.
static void tsl_apply_state(bool program, bool preview)
{
    if (s_tsl_swap) { bool t = program; program = preview; preview = t; }
    bool resolved_prog = program;
    bool resolved_prev = preview && !program;     // program wins

    bool going_dark = !resolved_prog && !resolved_prev;
    bool was_lit    = s_tsl_state_program || s_tsl_state_preview;

    if (going_dark && was_lit) {
        // Defer the OFF — Ross transient OFF absorber. Don't change the LED yet.
        // Seed the timer ONLY the first time we see going_dark. Subsequent
        // OFF packets within the debounce window must NOT reset the timer,
        // otherwise a switcher that streams OFF packets continuously will hold
        // the LED green forever (the stuck-green bug).
        if (s_tsl_pending_off_us == 0) {
            s_tsl_pending_off_us = esp_timer_get_time() + TSL_OFF_DEBOUNCE_US;
        }
        return;
    }

    // Any non-OFF packet cancels a pending OFF immediately.
    s_tsl_pending_off_us = 0;
    s_tsl_state_program  = resolved_prog;
    s_tsl_state_preview  = resolved_prev;

    tally_state_t led = resolved_prog ? TALLY_PROGRAM
                       : resolved_prev ? TALLY_PREVIEW
                       : TALLY_OFF;
    tally_led_set(led);
    last_tally_command_us = esp_timer_get_time();
}

// Called periodically while idle to apply a deferred OFF when its time arrives.
static void tsl_tick_pending_off(void)
{
    if (s_tsl_pending_off_us > 0 &&
        esp_timer_get_time() >= s_tsl_pending_off_us) {
        s_tsl_pending_off_us = 0;
        s_tsl_state_program  = false;
        s_tsl_state_preview  = false;
        tally_led_set(TALLY_OFF);
        last_tally_command_us = esp_timer_get_time();
    }
}

static esp_err_t tsl_config_load(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(TSL_NVS_NAMESPACE, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "TSL: no saved config (factory state)");
        return ESP_OK;
    }
    if (err != ESP_OK) return err;

    int32_t  idx  = 0;
    uint16_t port = TSL_DEFAULT_PORT;
    uint8_t  swap = 0;
    nvs_get_i32(h, TSL_NVS_KEY_INDEX, &idx);
    nvs_get_u16(h, TSL_NVS_KEY_PORT,  &port);
    nvs_get_u8 (h, TSL_NVS_KEY_SWAP,  &swap);
    nvs_close(h);

    xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
    s_tsl_index = (int)idx;
    s_tsl_port  = port ? port : TSL_DEFAULT_PORT;
    s_tsl_swap  = swap != 0;
    xSemaphoreGive(s_tsl_cfg_mutex);
    ESP_LOGI(TAG, "TSL: loaded config index=%d port=%u swap=%d",
             (int)idx, (unsigned)port, (int)swap);
    return ESP_OK;
}

static esp_err_t tsl_config_save(int index, uint16_t port, bool swap)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(TSL_NVS_NAMESPACE, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    nvs_set_i32(h, TSL_NVS_KEY_INDEX, index);
    nvs_set_u16(h, TSL_NVS_KEY_PORT,  port ? port : TSL_DEFAULT_PORT);
    nvs_set_u8 (h, TSL_NVS_KEY_SWAP,  swap ? 1 : 0);
    err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) return err;

    xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
    s_tsl_index = index;
    s_tsl_port  = port ? port : TSL_DEFAULT_PORT;
    s_tsl_swap  = swap;
    xSemaphoreGive(s_tsl_cfg_mutex);
    ESP_LOGI(TAG, "TSL: saved config index=%d port=%u swap=%d",
             index, (unsigned)(port ? port : TSL_DEFAULT_PORT), (int)swap);
    return ESP_OK;
}

// TSL TCP listener task. Owns the listening socket, accepts one switcher at a
// time, parses incoming bytes, filters by configured index, applies LED state.
// Polls every ~250 ms (via socket recv timeout) so config changes propagate
// promptly and the OFF debounce fires on schedule even with no incoming traffic.
static void tsl_listener_task(void *pvParameters)
{
    ESP_LOGI(TAG, "TSL listener task started");

    while (1) {
        // Snapshot current config under lock
        int my_index;
        uint16_t port;
        xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
        my_index = s_tsl_index;
        port = s_tsl_port;
        xSemaphoreGive(s_tsl_cfg_mutex);

        if (my_index <= 0) {
            // Not configured yet — wait for dashboard to push tsl_config.
            // Re-check every second; debounce still ticks but there shouldn't
            // be any pending OFF when we've never received a packet.
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }

        int listen_sock = socket(AF_INET, SOCK_STREAM, 0);
        if (listen_sock < 0) {
            ESP_LOGE(TAG, "TSL: socket() failed errno=%d", errno);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        int yes = 1;
        setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_in bind_addr = { 0 };
        bind_addr.sin_family      = AF_INET;
        bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
        bind_addr.sin_port        = htons(port);

        if (bind(listen_sock, (struct sockaddr*)&bind_addr, sizeof(bind_addr)) < 0) {
            ESP_LOGE(TAG, "TSL: bind(%u) failed errno=%d", (unsigned)port, errno);
            close(listen_sock);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        if (listen(listen_sock, 1) < 0) {
            ESP_LOGE(TAG, "TSL: listen() failed errno=%d", errno);
            close(listen_sock);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        ESP_LOGI(TAG, "TSL: listening on :%u, filtering for index %d",
                 (unsigned)port, my_index);

        struct timeval rcv_tv = { .tv_sec = 0, .tv_usec = 250 * 1000 };
        setsockopt(listen_sock, SOL_SOCKET, SO_RCVTIMEO, &rcv_tv, sizeof(rcv_tv));

        bool restart = false;
        while (!restart) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_sock = accept(listen_sock,
                                     (struct sockaddr*)&client_addr, &client_len);

            if (client_sock < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    tsl_tick_pending_off();
                    // Check for config changes between accept polls
                    xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
                    bool changed = (s_tsl_index != my_index) || (s_tsl_port != port);
                    xSemaphoreGive(s_tsl_cfg_mutex);
                    if (changed) {
                        ESP_LOGI(TAG, "TSL: config changed, restarting listener");
                        restart = true;
                    }
                    continue;
                }
                ESP_LOGW(TAG, "TSL: accept() errno=%d", errno);
                vTaskDelay(pdMS_TO_TICKS(100));
                continue;
            }
            ESP_LOGI(TAG, "TSL: switcher connected from %s",
                     inet_ntoa(client_addr.sin_addr));
            s_tsl_diag_client_connected = true;
            s_tsl_diag_clients_ever++;

            setsockopt(client_sock, SOL_SOCKET, SO_RCVTIMEO, &rcv_tv, sizeof(rcv_tv));

            uint8_t buf[TSL_RECV_BUFSZ];
            size_t buffered = 0;
            while (1) {
                ssize_t n = recv(client_sock, buf + buffered,
                                 sizeof(buf) - buffered, 0);
                if (n > 0) {
                    buffered += (size_t)n;
                    size_t consumed = 0;
                    while (consumed < buffered) {
                        size_t before = consumed;
                        int idx; bool prog, prev;
                        if (!tsl_parse_one(buf, buffered, &consumed,
                                           &idx, &prog, &prev)) {
                            if (consumed == before) break;   // incomplete; wait for more
                            continue;                         // resync byte skipped
                        }
                        // Diagnostic counters — record every successfully
                        // parsed packet, not just the ones matching our index.
                        // Lets the dashboard show "we ARE receiving packets but
                        // the Carbonite is sending ID X while we filter for Y".
                        s_tsl_diag_packets_total++;
                        s_tsl_diag_last_packet_us = esp_timer_get_time();
                        s_tsl_diag_last_index_seen = idx;
                        s_tsl_diag_last_state = (uint8_t)((prog ? 1 : 0) | (prev ? 2 : 0));
                        if (idx == my_index) {
                            s_tsl_diag_packets_matched++;
                            tsl_apply_state(prog, prev);
                        }
                    }
                    if (consumed > 0) {
                        memmove(buf, buf + consumed, buffered - consumed);
                        buffered -= consumed;
                    }
                    if (buffered == sizeof(buf)) {
                        ESP_LOGW(TAG, "TSL: recv buffer full with no complete packet, resyncing");
                        buffered = 0;
                    }
                    // Apply any deferred OFF whose debounce window has expired.
                    // Previously this only ran on recv() EAGAIN — which never
                    // fired while a switcher streamed packets continuously,
                    // causing the LED to stick at PVW/PGM after the source
                    // genuinely went idle (the stuck-green bug).
                    tsl_tick_pending_off();
                } else if (n == 0) {
                    ESP_LOGI(TAG, "TSL: switcher disconnected");
                    break;
                } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    tsl_tick_pending_off();
                    xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
                    bool changed = (s_tsl_index != my_index) || (s_tsl_port != port);
                    xSemaphoreGive(s_tsl_cfg_mutex);
                    if (changed) {
                        ESP_LOGI(TAG, "TSL: config changed mid-session, dropping switcher");
                        close(client_sock);
                        restart = true;
                        break;
                    }
                    continue;
                } else {
                    ESP_LOGW(TAG, "TSL: recv errno=%d", errno);
                    break;
                }
            }
            close(client_sock);
            s_tsl_diag_client_connected = false;
        }

        close(listen_sock);
        s_tsl_diag_client_connected = false;
    }
}

// ===========================================================================
//          CAMERA API CLIENT FUNCTIONS
// ===========================================================================

// HTTP event handler for camera requests - captures cookies and response data
static esp_err_t camera_http_event_handler(esp_http_client_event_t *evt)
{
    static int output_len = 0;

    switch(evt->event_id) {
        case HTTP_EVENT_ON_HEADER:
            // Capture Set-Cookie headers
            if (strcasecmp(evt->header_key, "Set-Cookie") == 0) {
                // Extract just the cookie name=value part (before any ;)
                char *semicolon = strchr(evt->header_value, ';');
                size_t cookie_len = semicolon ? (size_t)(semicolon - evt->header_value) : strlen(evt->header_value);

                // Append to existing cookies
                size_t current_len = strlen(camera_cookies);
                if (current_len > 0 && current_len + cookie_len + 2 < sizeof(camera_cookies)) {
                    // Add "; " separator
                    strcat(camera_cookies, "; ");
                    strncat(camera_cookies, evt->header_value, cookie_len);
                } else if (current_len == 0 && cookie_len < sizeof(camera_cookies)) {
                    strncpy(camera_cookies, evt->header_value, cookie_len);
                    camera_cookies[cookie_len] = 0;
                }
                ESP_LOGI(TAG, "Captured cookie: %.*s", (int)cookie_len, evt->header_value);
            }
            break;
        case HTTP_EVENT_ON_DATA:
            if (!esp_http_client_is_chunked_response(evt->client)) {
                if (output_len + evt->data_len < HTTP_BUFFER_SIZE - 1) {
                    memcpy(http_buffer + output_len, evt->data, evt->data_len);
                    output_len += evt->data_len;
                    http_buffer[output_len] = 0;
                }
            }
            break;
        case HTTP_EVENT_ON_FINISH:
            output_len = 0;
            break;
        case HTTP_EVENT_DISCONNECTED:
            output_len = 0;
            break;
        default:
            break;
    }
    return ESP_OK;
}

// Make authenticated request to camera
static esp_err_t camera_request(const char *path, char *response, size_t resp_size)
{
    char url[256];
    snprintf(url, sizeof(url), "%s%s", CAMERA_BASE_URL, path);

    http_buffer[0] = 0;
    camera_requests_total++;

    esp_http_client_config_t config = {
        .url = url,
        .username = CAMERA_USER,
        .password = CAMERA_PASS,
        .auth_type = HTTP_AUTH_TYPE_BASIC,
        .event_handler = camera_http_event_handler,
        .timeout_ms = 2000,
    };

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        camera_requests_failed++;
        snprintf(last_camera_error, sizeof(last_camera_error), "Failed to init HTTP client");
        ESP_LOGE(TAG, "Failed to init HTTP client for %s", path);
        return ESP_FAIL;
    }

    // Add session cookies if we have them
    if (strlen(camera_cookies) > 0) {
        esp_http_client_set_header(client, "Cookie", camera_cookies);
    }

    esp_err_t err = esp_http_client_perform(client);

    if (err == ESP_OK) {
        int status = esp_http_client_get_status_code(client);
        if (status == 200 && response != NULL) {
            strncpy(response, http_buffer, resp_size - 1);
            response[resp_size - 1] = 0;
            ESP_LOGD(TAG, "Camera OK: %s (len=%d)", path, (int)strlen(response));
        } else if (status != 200) {
            camera_requests_failed++;
            snprintf(last_camera_error, sizeof(last_camera_error), "HTTP %d on %s", status, path);
            ESP_LOGW(TAG, "Camera returned status %d for %s", status, path);
            err = ESP_FAIL;
        }
    } else {
        camera_requests_failed++;
        snprintf(last_camera_error, sizeof(last_camera_error), "%s on %s", esp_err_to_name(err), path);
        ESP_LOGE(TAG, "Camera request failed: %s for %s", esp_err_to_name(err), path);
    }

    esp_http_client_cleanup(client);
    return err;
}

// Login to camera
static esp_err_t camera_login(void)
{
    // Clear old cookies before login to get fresh session
    camera_cookies[0] = 0;

    char response[512];
    esp_err_t err = camera_request("/api/acnt/login", response, sizeof(response));

    if (err == ESP_OK) {
        cJSON *json = cJSON_Parse(response);
        if (json) {
            cJSON *res = cJSON_GetObjectItem(json, "res");
            if (res && strcmp(res->valuestring, "ok") == 0) {
                ESP_LOGI(TAG, "Camera login successful (cookies: %s)", camera_cookies);
                camera_logged_in = true;
                cJSON_Delete(json);

                // Add required cookies for getcurprop to work
                // The browser sends these and without them camera returns "busy"
                // productId=VNCX02 is the Canon C200 product ID
                if (strlen(camera_cookies) + 30 < sizeof(camera_cookies)) {
                    strcat(camera_cookies, "; brlang=0; productId=VNCX02");
                }
                ESP_LOGI(TAG, "Full cookies: %s", camera_cookies);

                // Start live view session to enable full remote control
                // getcurprop returns "busy" without an active LV session
                ESP_LOGI(TAG, "Starting live view session...");
                char lv_response[256];
                camera_request("/api/cam/lv?cmd=start&sz=s", lv_response, sizeof(lv_response));
                ESP_LOGI(TAG, "LV start response: %s", lv_response);
                vTaskDelay(pdMS_TO_TICKS(500));

                return ESP_OK;
            } else if (res && strcmp(res->valuestring, "errsession") == 0) {
                ESP_LOGW(TAG, "Another client is connected to camera");
            }
            cJSON_Delete(json);
        }
    }

    camera_logged_in = false;
    return ESP_FAIL;
}

// Get camera property
static esp_err_t camera_get_property(const char *prop, cJSON **result)
{
    char path[128];
    char response[1024];

    snprintf(path, sizeof(path), "/api/cam/getprop?r=%s", prop);
    esp_err_t err = camera_request(path, response, sizeof(response));

    if (err == ESP_OK) {
        *result = cJSON_Parse(response);
        if (*result == NULL) {
            ESP_LOGW(TAG, "Failed to parse camera response");
            return ESP_FAIL;
        }

        // Check for session error - another client took over
        cJSON *res = cJSON_GetObjectItem(*result, "res");
        if (res && cJSON_IsString(res) && strcmp(res->valuestring, "errsession") == 0) {
            ESP_LOGW(TAG, "Session lost - another client connected. Will re-login.");
            camera_logged_in = false;
            cJSON_Delete(*result);
            *result = NULL;
            return ESP_ERR_INVALID_STATE;
        }
    }

    return err;
}

// Send camera command
static esp_err_t camera_command(const char *cmd, cJSON **result)
{
    char response[512];
    esp_err_t err = camera_request(cmd, response, sizeof(response));

    if (err == ESP_OK && result != NULL) {
        *result = cJSON_Parse(response);
    }

    return err;
}

// Check if enough time has passed since the last command (rate limiting)
static bool check_rate_limit(void)
{
    int64_t now = esp_timer_get_time();
    int64_t elapsed_ms = (now - last_command_time_us) / 1000;

    if (elapsed_ms < COMMAND_RATE_LIMIT_MS) {
        ESP_LOGD(TAG, "Rate limited: %lld ms since last command", elapsed_ms);
        return false;  // Too soon
    }

    last_command_time_us = now;
    return true;
}

// Flag to trigger immediate state poll after command
static volatile bool poll_state_now = false;
// Which property to re-poll after command (set before poll_state_now = true)
// Empty string = fall back to full update_camera_state()
static char poll_property_hint[16] = "";

// Send rate-limited camera command
// Returns: 0 = success, 1 = rate limited, -1 = failed
static int send_rate_limited_command(const char *cmd, httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    if (!check_rate_limit()) {
        // Rate limited - tell the client to wait
        httpd_resp_send(req, "{\"ok\":false,\"rate_limited\":true}", -1);
        return 1;
    }

    cJSON *result = NULL;
    esp_err_t err = camera_command(cmd, &result);

    if (err == ESP_OK) {
        // Set flag to trigger state refresh from background task
        // Don't call update_camera_state() here - avoid nested HTTP from handler
        poll_state_now = true;

        httpd_resp_send(req, "{\"ok\":true}", -1);
        if (result) cJSON_Delete(result);
        return 0;
    } else {
        httpd_resp_send(req, "{\"ok\":false,\"error\":\"command_failed\"}", -1);
        if (result) cJSON_Delete(result);
        return -1;
    }
}

// ===========================================================================
//          CAMERA STATE POLLING
// ===========================================================================

// Re-poll a single camera property and update the cache.
// Used after a button press for near-instant feedback.
static void update_single_property(const char *prop_name)
{
    if (!camera_logged_in || !prop_name || !prop_name[0]) return;

    cJSON *prop_result = NULL;
    esp_err_t err = camera_get_property(prop_name, &prop_result);
    if (err != ESP_OK || !prop_result) return;

    char key[32];
    snprintf(key, sizeof(key), "O%s", prop_name);
    cJSON *prop_obj = cJSON_GetObjectItem(prop_result, key);
    if (prop_obj) {
        cJSON *pv = cJSON_GetObjectItem(prop_obj, "pv");
        cJSON *en = cJSON_GetObjectItem(prop_obj, "en");
        if (pv) {
            cJSON *prop_copy = cJSON_CreateObject();
            if (cJSON_IsString(pv) && pv->valuestring) {
                cJSON_AddStringToObject(prop_copy, "value", pv->valuestring);
            } else if (cJSON_IsNumber(pv)) {
                char num_str[32];
                if (pv->valuedouble == (int)pv->valuedouble) {
                    snprintf(num_str, sizeof(num_str), "%d", (int)pv->valuedouble);
                } else {
                    snprintf(num_str, sizeof(num_str), "%.2f", pv->valuedouble);
                }
                cJSON_AddStringToObject(prop_copy, "value", num_str);
            } else {
                cJSON_AddStringToObject(prop_copy, "value", "--");
            }
            cJSON_AddBoolToObject(prop_copy, "enabled",
                en ? cJSON_IsTrue(en) || (cJSON_IsNumber(en) && en->valueint) : true);

            if (xSemaphoreTake(camera_state_mutex, pdMS_TO_TICKS(1000))) {
                if (camera_state) {
                    cJSON_DeleteItemFromObject(camera_state, prop_name);
                    cJSON_AddItemToObject(camera_state, prop_name, prop_copy);
                } else {
                    cJSON_Delete(prop_copy);
                }
                xSemaphoreGive(camera_state_mutex);
            } else {
                cJSON_Delete(prop_copy);
            }
        }
    }
    cJSON_Delete(prop_result);
}

// Update cached camera state
static void update_camera_state(void)
{
    if (!camera_logged_in) return;

    // Properties to poll
    const char *properties[] = {
        "av", "gcv", "ssv", "ndv", "wbm", "wbvk", "wbvc",
        "aesv", "gcm", "ssm", "afm", "fdat", "fguide"
    };
    int num_props = sizeof(properties) / sizeof(properties[0]);

    cJSON *new_state = cJSON_CreateObject();

    for (int i = 0; i < num_props; i++) {
        // If a command came in, bail out so the main loop handles it quickly
        if (poll_state_now) {
            cJSON_Delete(new_state);
            return;
        }
        cJSON *prop_result = NULL;
        esp_err_t err = camera_get_property(properties[i], &prop_result);
        if (err == ESP_OK && prop_result) {
            // Debug: print first property response
            if (i == 0) {
                char *debug_str = cJSON_PrintUnformatted(prop_result);
                if (debug_str) {
                    ESP_LOGI(TAG, "Camera prop '%s' response: %.200s", properties[i], debug_str);
                    free(debug_str);
                }
            }
            // Extract the property value from response
            char key[32];
            snprintf(key, sizeof(key), "O%s", properties[i]);
            cJSON *prop_obj = cJSON_GetObjectItem(prop_result, key);
            if (prop_obj) {
                cJSON *pv = cJSON_GetObjectItem(prop_obj, "pv");
                cJSON *en = cJSON_GetObjectItem(prop_obj, "en");
                if (pv) {
                    cJSON *prop_copy = cJSON_CreateObject();
                    // Handle both string and number values
                    if (cJSON_IsString(pv) && pv->valuestring) {
                        cJSON_AddStringToObject(prop_copy, "value", pv->valuestring);
                    } else if (cJSON_IsNumber(pv)) {
                        char num_str[32];
                        if (pv->valuedouble == (int)pv->valuedouble) {
                            snprintf(num_str, sizeof(num_str), "%d", (int)pv->valuedouble);
                        } else {
                            snprintf(num_str, sizeof(num_str), "%.2f", pv->valuedouble);
                        }
                        cJSON_AddStringToObject(prop_copy, "value", num_str);
                    } else {
                        cJSON_AddStringToObject(prop_copy, "value", "--");
                    }
                    cJSON_AddBoolToObject(prop_copy, "enabled", en ? cJSON_IsTrue(en) || (cJSON_IsNumber(en) && en->valueint) : true);
                    cJSON_AddItemToObject(new_state, properties[i], prop_copy);
                }
            }
            cJSON_Delete(prop_result);
        }
        vTaskDelay(pdMS_TO_TICKS(20)); // Delay between requests
    }

    // Update cached state
    if (xSemaphoreTake(camera_state_mutex, pdMS_TO_TICKS(1000))) {
        if (camera_state) {
            cJSON_Delete(camera_state);
        }
        camera_state = new_state;
        xSemaphoreGive(camera_state_mutex);
    } else {
        cJSON_Delete(new_state);
    }
}

// Poll recording status using getcurprop API - simple like Chrome's network tab
// Just send the request, log the response, use the seq from the response
static void update_recording_state(void)
{
    if (!camera_logged_in) return;

    char path[64];
    char response[4096];  // Increased from 1024 - getcurprop returns ~2KB

    snprintf(path, sizeof(path), "/api/cam/getcurprop?seq=%d", getcurprop_seq);
    esp_err_t err = camera_request(path, response, sizeof(response));

    if (err != ESP_OK) {
        ESP_LOGW(TAG, "getcurprop request failed");
        snprintf(last_getcurprop_response, sizeof(last_getcurprop_response), "ERROR: %s", esp_err_to_name(err));
        return;
    }

    // Store response for debugging (first 500 chars)
    strncpy(last_getcurprop_response, response, sizeof(last_getcurprop_response) - 1);
    last_getcurprop_response[sizeof(last_getcurprop_response) - 1] = 0;

    // Log the raw response like Chrome's network tab
    ESP_LOGI(TAG, "getcurprop?seq=%d -> %s", getcurprop_seq, response);

    cJSON *json = cJSON_Parse(response);
    if (!json) return;

    // Always update seq from whatever the camera sends
    cJSON *seq = cJSON_GetObjectItem(json, "seq");
    if (seq && cJSON_IsNumber(seq)) {
        getcurprop_seq = seq->valueint;
    }

    // Check for session error
    cJSON *res = cJSON_GetObjectItem(json, "res");
    if (res && cJSON_IsString(res) && strcmp(res->valuestring, "errsession") == 0) {
        ESP_LOGW(TAG, "Session lost - will re-login");
        camera_logged_in = false;
        cJSON_Delete(json);
        return;
    }

    // Check for "rec" field to detect recording state
    // "rec": "stby" = Standby (not recording)
    // "rec": "rec"  = Recording
    cJSON *rec = cJSON_GetObjectItem(json, "rec");
    bool was_recording = camera_recording;

    if (rec && cJSON_IsString(rec)) {
        if (strcmp(rec->valuestring, "rec") == 0) {
            camera_recording = true;
        } else if (strcmp(rec->valuestring, "stby") == 0) {
            camera_recording = false;
        }
        // If rec field exists, log the state change
        if (was_recording != camera_recording) {
            ESP_LOGI(TAG, "Recording: %s (rec=%s)", camera_recording ? "YES" : "NO", rec->valuestring);
        }
    }

    cJSON_Delete(json);
}

// ===========================================================================
//          WEBSOCKET PUSH
// ===========================================================================

// Build and send current state to all connected WebSocket clients
static void ws_broadcast_state(void)
{
    if (!ws_mutex) return;
    if (!xSemaphoreTake(ws_mutex, pdMS_TO_TICKS(50))) return;
    int client_count = ws_fd_count;
    xSemaphoreGive(ws_mutex);
    if (client_count == 0) return;

    // Build combined JSON: status + camera state
    cJSON *msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "type", "state");
    cJSON_AddBoolToObject(msg, "recording", camera_recording);
    cJSON_AddBoolToObject(msg, "camera_connected", camera_logged_in);
    cJSON_AddBoolToObject(msg, "wifi_connected", wifi_connected);
    cJSON_AddBoolToObject(msg, "eth_connected", eth_connected);

    // Live RSSI so the dashboard can draw matching signal bars in the OLED preview.
    // Read from cache — calling esp_wifi_sta_get_ap_info here stalls camera_poll_task
    // for tens of ms and breaks the Canon HTTP session.
    cJSON_AddNumberToObject(msg, "wifi_rssi", cached_rssi_dbm);

    // Add tally state
    const char *tally_str = "off";
    if (xSemaphoreTake(tally_mutex, pdMS_TO_TICKS(50))) {
        switch (current_tally_state) {
            case TALLY_PROGRAM: tally_str = "program"; break;
            case TALLY_PREVIEW: tally_str = "preview"; break;
            case TALLY_BOTH: tally_str = "both"; break;
            default: tally_str = "off"; break;
        }
        xSemaphoreGive(tally_mutex);
    }
    cJSON_AddStringToObject(msg, "tally", tally_str);

    // Include current OLED camera number so the app can detect when the display
    // needs to be (re)populated after a reboot — app pushes /api/display whenever it sees 0
    if (oled_data_mutex && xSemaphoreTake(oled_data_mutex, pdMS_TO_TICKS(50))) {
        cJSON_AddNumberToObject(msg, "oled_number", oled_camera_number);
        xSemaphoreGive(oled_data_mutex);
    } else {
        cJSON_AddNumberToObject(msg, "oled_number", 0);
    }

    // Deep-copy camera state properties into message
    if (xSemaphoreTake(camera_state_mutex, pdMS_TO_TICKS(100))) {
        if (camera_state) {
            cJSON *prop = camera_state->child;
            while (prop) {
                cJSON *copy = cJSON_Duplicate(prop, 1);
                if (copy) cJSON_AddItemToObject(msg, prop->string, copy);
                prop = prop->next;
            }
        }
        xSemaphoreGive(camera_state_mutex);
    }

    char *json_str = cJSON_PrintUnformatted(msg);
    cJSON_Delete(msg);
    if (!json_str) return;

    httpd_ws_frame_t ws_pkt = {
        .final = true,
        .fragmented = false,
        .type = HTTPD_WS_TYPE_TEXT,
        .payload = (uint8_t *)json_str,
        .len = strlen(json_str),
    };

    // Send to all clients, remove any that have disconnected
    if (xSemaphoreTake(ws_mutex, pdMS_TO_TICKS(50))) {
        int i = 0;
        while (i < ws_fd_count) {
            esp_err_t ret = httpd_ws_send_frame_async(server, ws_fds[i], &ws_pkt);
            if (ret != ESP_OK) {
                ESP_LOGW(TAG, "WS client fd=%d disconnected, removing", ws_fds[i]);
                ws_fds[i] = ws_fds[--ws_fd_count];
            } else {
                i++;
            }
        }
        xSemaphoreGive(ws_mutex);
    }

    free(json_str);
}

// WebSocket connection handler — called on new connection and on incoming frames
static esp_err_t ws_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        // HTTP upgrade to WebSocket — new client connecting
        int fd = httpd_req_to_sockfd(req);
        ESP_LOGI(TAG, "WebSocket client connected: fd=%d", fd);
        if (xSemaphoreTake(ws_mutex, pdMS_TO_TICKS(100))) {
            if (ws_fd_count < MAX_WS_CLIENTS) {
                ws_fds[ws_fd_count++] = fd;
                ESP_LOGI(TAG, "WS clients now: %d", ws_fd_count);
            } else {
                ESP_LOGW(TAG, "WS max clients reached, rejecting fd=%d", fd);
            }
            xSemaphoreGive(ws_mutex);
        }
        return ESP_OK;
    }

    // Incoming frame from a client. Today the only message we accept is
    // {"type":"tsl_config","index":N,"port":P,"swap":B} from the dashboard,
    // which persists the board's TSL configuration to NVS and restarts the
    // TSL listener with the new settings.
    httpd_ws_frame_t ws_pkt = { 0 };
    ws_pkt.type = HTTPD_WS_TYPE_TEXT;

    // First call with max_len=0 returns the frame length without copying.
    esp_err_t err = httpd_ws_recv_frame(req, &ws_pkt, 0);
    if (err != ESP_OK) return err;
    if (ws_pkt.len == 0 || ws_pkt.len > 1024) return ESP_OK;

    uint8_t *buf = (uint8_t *)malloc(ws_pkt.len + 1);
    if (!buf) return ESP_ERR_NO_MEM;
    ws_pkt.payload = buf;
    err = httpd_ws_recv_frame(req, &ws_pkt, ws_pkt.len);
    if (err != ESP_OK) { free(buf); return err; }
    buf[ws_pkt.len] = '\0';

    cJSON *root = cJSON_Parse((const char *)buf);
    free(buf);
    if (!root) return ESP_OK;

    cJSON *type_j = cJSON_GetObjectItem(root, "type");
    if (cJSON_IsString(type_j) && strcmp(type_j->valuestring, "tsl_config") == 0) {
        cJSON *idx_j  = cJSON_GetObjectItem(root, "index");
        cJSON *port_j = cJSON_GetObjectItem(root, "port");
        cJSON *swap_j = cJSON_GetObjectItem(root, "swap");
        int idx       = cJSON_IsNumber(idx_j)  ? idx_j->valueint  : 0;
        uint16_t port = cJSON_IsNumber(port_j) ? (uint16_t)port_j->valueint : TSL_DEFAULT_PORT;
        bool swap     = cJSON_IsBool(swap_j)   ? cJSON_IsTrue(swap_j) : false;

        if (tsl_config_save(idx, port, swap) != ESP_OK) {
            ESP_LOGW(TAG, "TSL: failed to persist config");
        }
    }

    cJSON_Delete(root);
    return ESP_OK;
}

// Camera polling task
static void camera_poll_task(void *pvParameters)
{
    ESP_LOGI(TAG, "Camera polling task started");

    while (1) {
        // Wait for Ethernet connection (with timeout to allow retries)
        EventBits_t bits = xEventGroupWaitBits(s_event_group, ETH_CONNECTED_BIT,
                                                pdFALSE, pdTRUE, pdMS_TO_TICKS(5000));

        if (!(bits & ETH_CONNECTED_BIT)) {
            // Ethernet not connected, wait and retry
            continue;
        }

        // Skip polling if paused (for testing)
        if (polling_paused) {
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;
        }

        // Ensure logged in to camera
        if (!camera_logged_in) {
            ESP_LOGI(TAG, "Attempting camera login...");
            if (camera_login() != ESP_OK) {
                ESP_LOGW(TAG, "Camera login failed, retrying in 5s...");
                vTaskDelay(pdMS_TO_TICKS(5000));
                continue;
            }
            ESP_LOGI(TAG, "Camera login successful!");
            xEventGroupSetBits(s_event_group, CAMERA_READY_BIT);
        }

        // Check if immediate state poll was requested (after command)
        if (poll_state_now) {
            poll_state_now = false;
            // Wait a bit for camera to process the command
            vTaskDelay(pdMS_TO_TICKS(150));
            // Poll only the property that changed (fast) or all if no hint
            if (poll_property_hint[0]) {
                update_single_property(poll_property_hint);
                poll_property_hint[0] = '\0';
            } else {
                update_camera_state();
            }
            ws_broadcast_state();   // Push updated state right away
            vTaskDelay(pdMS_TO_TICKS(500));
            continue;               // Skip the redundant regular poll this cycle
        }

        // Check if immediate recording poll was requested
        if (poll_recording_now) {
            poll_recording_now = false;
            // Wait a bit for camera to process the record command
            vTaskDelay(pdMS_TO_TICKS(300));
            update_recording_state();
            // Poll a few more times to catch the state change
            for (int i = 0; i < 4; i++) {
                vTaskDelay(pdMS_TO_TICKS(500));
                update_recording_state();
            }
        }

        // Update recording state (faster poll)
        update_recording_state();

        // Update camera settings state
        update_camera_state();

        // Tally watchdog: log only, do NOT alter the physical LED. The earlier
        // behavior forced the LED to amber after 8s of dashboard silence — but
        // on a degraded WiFi link where dashboard *off* commands time out, that
        // turned a should-be-dark tally into a fake amber. Talent reads amber as
        // "abnormal, don't move" but it can also be misread as "preview/standby"
        // depending on the operator. Either way, lying with the physical light
        // is worse than holding the last commanded state. Detection of dashboard
        // loss now lives in the dashboard itself (and, after phase 2, becomes
        // moot because boards listen to TSL directly).
        if (current_tally_state != TALLY_OFF && last_tally_command_us > 0) {
            int64_t now = esp_timer_get_time();
            if ((now - last_tally_command_us) > ((int64_t)TALLY_WATCHDOG_MS * 1000)) {
                ESP_LOGW(TAG, "Tally watchdog: no command for %d ms (LED unchanged)", TALLY_WATCHDOG_MS);
                last_tally_command_us = 0;
            }
        }

        // Push updated state to all connected WebSocket clients
        ws_broadcast_state();

        // Poll every 500ms
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

// ===========================================================================
//          HTTP SERVER API HANDLERS
// ===========================================================================

// GET /api/status - Get camera status and ESP32 status
static esp_err_t status_handler(httpd_req_t *req)
{
    // Log current recording state for debugging
    ESP_LOGI(TAG, "Status request: camera_recording=%d", camera_recording);

    cJSON *response = cJSON_CreateObject();

    // ESP32 unique identifier (MAC address)
    uint8_t mac[6];
    esp_efuse_mac_get_default(mac);
    char mac_str[18];
    snprintf(mac_str, sizeof(mac_str), "%02X:%02X:%02X:%02X:%02X:%02X",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    cJSON_AddStringToObject(response, "esp_id", mac_str);
    cJSON_AddStringToObject(response, "esp_name", "c200-controller");  // TODO: Make configurable

    cJSON_AddBoolToObject(response, "wifi_connected", wifi_connected);
    cJSON_AddBoolToObject(response, "eth_connected", eth_connected);
    cJSON_AddBoolToObject(response, "camera_connected", camera_logged_in);
    cJSON_AddBoolToObject(response, "is_recording", camera_recording);

    char ip_str[16];
    snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&s_wifi_ip));
    cJSON_AddStringToObject(response, "wifi_ip", ip_str);
    snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&s_eth_ip));
    cJSON_AddStringToObject(response, "eth_ip", ip_str);
    cJSON_AddStringToObject(response, "camera_ip", CAMERA_IP);
    cJSON_AddStringToObject(response, "firmware_version", FIRMWARE_VERSION);
    cJSON_AddNumberToObject(response, "camera_number", CAMERA_NUMBER);

    // Current WiFi RSSI in dBm (e.g. -55). 0 when not associated. Lets the
    // dashboard draw live signal bars in the tile's OLED preview.
    int rssi = 0;
    if (wifi_connected) {
        wifi_ap_record_t ap_info;
        if (esp_wifi_sta_get_ap_info(&ap_info) == ESP_OK) {
            rssi = ap_info.rssi;
        }
    }
    cJSON_AddNumberToObject(response, "wifi_rssi", rssi);

    // Current TSL listener config — lets the dashboard confirm a tsl_config
    // push was persisted, and surface unconfigured boards in the UI.
    xSemaphoreTake(s_tsl_cfg_mutex, portMAX_DELAY);
    int tsl_idx = s_tsl_index;
    uint16_t tsl_port_now = s_tsl_port;
    bool tsl_swap_now = s_tsl_swap;
    xSemaphoreGive(s_tsl_cfg_mutex);
    cJSON_AddNumberToObject(response, "tsl_index", tsl_idx);
    cJSON_AddNumberToObject(response, "tsl_port",  (double)tsl_port_now);
    cJSON_AddBoolToObject  (response, "tsl_swap",  tsl_swap_now);

    // TSL diagnostic counters (1.2.1+). Snapshot all into locals first to avoid
    // any read tearing across the JSON serialization. These let the dashboard
    // prove each link of the Carbonite → TCP → parser → filter chain.
    bool     diag_client     = s_tsl_diag_client_connected;
    uint32_t diag_clients_ev = s_tsl_diag_clients_ever;
    uint32_t diag_total      = s_tsl_diag_packets_total;
    uint32_t diag_matched    = s_tsl_diag_packets_matched;
    int64_t  diag_last_us    = s_tsl_diag_last_packet_us;
    int      diag_last_idx   = s_tsl_diag_last_index_seen;
    uint8_t  diag_last_state = s_tsl_diag_last_state;
    cJSON_AddBoolToObject  (response, "tsl_client_connected", diag_client);
    cJSON_AddNumberToObject(response, "tsl_clients_ever",     (double)diag_clients_ev);
    cJSON_AddNumberToObject(response, "tsl_packets_total",    (double)diag_total);
    cJSON_AddNumberToObject(response, "tsl_packets_matched",  (double)diag_matched);
    // Time since the last successfully parsed packet, in milliseconds. -1 means
    // "we have never received one" — easier to render in the dashboard than null.
    int64_t age_ms = -1;
    if (diag_last_us > 0) {
        age_ms = (esp_timer_get_time() - diag_last_us) / 1000;
        if (age_ms < 0) age_ms = 0;
    }
    cJSON_AddNumberToObject(response, "tsl_last_packet_age_ms", (double)age_ms);
    cJSON_AddNumberToObject(response, "tsl_last_index_seen",    (double)diag_last_idx);
    const char *state_str = "off";
    switch (diag_last_state) {
        case 1: state_str = "program"; break;
        case 2: state_str = "preview"; break;
        case 3: state_str = "both";    break;
        default: state_str = "off";    break;
    }
    cJSON_AddStringToObject(response, "tsl_last_state", state_str);

    char *json_str = cJSON_Print(response);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, json_str, strlen(json_str));

    free(json_str);
    cJSON_Delete(response);
    return ESP_OK;
}

// POST /api/display - Receive camera assignment from Camera Positions app
// Body: {"operator": "Aaron Larson", "lens": "70-200mm F4L"}
// The ESP32 stores operator and lens for display on the OLED screen.
static esp_err_t display_handler(httpd_req_t *req)
{
    char body[256];
    int len = httpd_req_recv(req, body, sizeof(body) - 1);
    if (len <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "No body");
        return ESP_OK;
    }
    body[len] = '\0';

    cJSON *json = cJSON_Parse(body);
    if (!json) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid JSON");
        return ESP_OK;
    }

    cJSON *op     = cJSON_GetObjectItem(json, "operator");
    cJSON *lens   = cJSON_GetObjectItem(json, "lens");
    cJSON *cam_n  = cJSON_GetObjectItem(json, "camera");

    if (oled_data_mutex && xSemaphoreTake(oled_data_mutex, pdMS_TO_TICKS(1000))) {
        if (cJSON_IsString(op) && op->valuestring) {
            strlcpy(oled_operator, op->valuestring, sizeof(oled_operator));
        } else {
            oled_operator[0] = '\0';
        }
        if (cJSON_IsString(lens) && lens->valuestring) {
            strlcpy(oled_lens, lens->valuestring, sizeof(oled_lens));
        } else {
            oled_lens[0] = '\0';
        }
        if (cJSON_IsNumber(cam_n)) {
            oled_camera_number = (int)cam_n->valuedouble;
        }
        xSemaphoreGive(oled_data_mutex);
        ESP_LOGI(TAG, "Display updated: cam=%d op=\"%s\" lens=\"%s\"", oled_camera_number, oled_operator, oled_lens);
    }

    cJSON_Delete(json);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_sendstr(req, "{\"ok\":true}");
    return ESP_OK;
}

// GET /api/camera/state - Get cached camera state
static esp_err_t camera_state_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    if (xSemaphoreTake(camera_state_mutex, pdMS_TO_TICKS(1000))) {
        if (camera_state) {
            char *json_str = cJSON_Print(camera_state);
            httpd_resp_send(req, json_str, strlen(json_str));
            free(json_str);
        } else {
            httpd_resp_send(req, "{}", 2);
        }
        xSemaphoreGive(camera_state_mutex);
    } else {
        httpd_resp_send(req, "{\"error\":\"busy\"}", -1);
    }

    return ESP_OK;
}

// POST /api/camera/rec - Toggle recording
static esp_err_t rec_handler(httpd_req_t *req)
{
    cJSON *result = NULL;
    esp_err_t err = camera_command("/api/cam/rec?cmd=trig", &result);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    if (err == ESP_OK) {
        if (result) cJSON_Delete(result);

        // Wait for camera to process the command
        vTaskDelay(pdMS_TO_TICKS(200));

        // Poll camera to get actual recording state
        update_recording_state();

        ESP_LOGI(TAG, "Record toggled - actual state: %s", camera_recording ? "RECORDING" : "STANDBY");

        // Return success with actual recording state from camera
        char response[64];
        snprintf(response, sizeof(response), "{\"ok\":true,\"recording\":%s}",
                 camera_recording ? "true" : "false");
        httpd_resp_send(req, response, -1);
    } else {
        httpd_resp_send(req, "{\"error\":\"failed\"}", -1);
    }

    return ESP_OK;
}

// POST /api/camera/iris/{plus|minus}
static esp_err_t iris_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/iris/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 6;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?iris=%s", dir);
    strncpy(poll_property_hint, "av", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/iso/{plus|minus}
static esp_err_t iso_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/iso/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 5;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?iso=%s", dir);
    strncpy(poll_property_hint, "gcv", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/shutter/{plus|minus}
static esp_err_t shutter_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/shutter/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 9;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?shutter=%s", dir);
    strncpy(poll_property_hint, "ssv", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/nd/{plus|minus}
static esp_err_t nd_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/nd/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 4;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?nd=%s", dir);
    strncpy(poll_property_hint, "ndv", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/wb/{mode}
static esp_err_t wb_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *mode = strstr(uri, "/wb/");
    if (!mode) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing mode");
        return ESP_FAIL;
    }
    mode += 4;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/setprop?wbm=%s", mode);
    strncpy(poll_property_hint, "wbm", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/focus/{action}
static esp_err_t focus_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *action = strstr(uri, "/focus/");
    if (!action) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing action");
        return ESP_FAIL;
    }
    action += 7;

    char cmd[64];

    // Map friendly names to camera commands
    if (strcmp(action, "oneshot") == 0) {
        snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?focus=oneshotaf");
    } else if (strcmp(action, "lock") == 0) {
        snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?focus=aflock");
    } else if (strcmp(action, "track") == 0) {
        snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?focus=track");
    } else if (strncmp(action, "near", 4) == 0 || strncmp(action, "far", 3) == 0) {
        snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?fl=%s", action);
    } else {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Unknown focus action");
        return ESP_FAIL;
    }

    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/aes/{plus|minus}
static esp_err_t aes_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/aes/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 5;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?aes=%s", dir);
    strncpy(poll_property_hint, "aesv", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// POST /api/camera/wbk/{plus|minus} - White Balance Kelvin adjustment
static esp_err_t wbk_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *dir = strstr(uri, "/wbk/");
    if (!dir) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing direction");
        return ESP_FAIL;
    }
    dir += 5;

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "/api/cam/drivelens?wbk=%s", dir);
    strncpy(poll_property_hint, "wbvk", sizeof(poll_property_hint));
    send_rate_limited_command(cmd, req);
    return ESP_OK;
}

// GET /api/debug - Get debug info and memory stats
static esp_err_t debug_handler(httpd_req_t *req)
{
    api_requests_total++;

    cJSON *response = cJSON_CreateObject();

    // Memory stats
    cJSON *memory = cJSON_CreateObject();
    cJSON_AddNumberToObject(memory, "free_heap_kb", esp_get_free_heap_size() / 1024);
    cJSON_AddNumberToObject(memory, "free_internal_kb", heap_caps_get_free_size(MALLOC_CAP_INTERNAL) / 1024);
    cJSON_AddNumberToObject(memory, "free_psram_kb", heap_caps_get_free_size(MALLOC_CAP_SPIRAM) / 1024);
    cJSON_AddNumberToObject(memory, "min_free_heap_kb", esp_get_minimum_free_heap_size() / 1024);
    cJSON_AddNumberToObject(memory, "largest_free_block_kb", heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT) / 1024);
    cJSON_AddItemToObject(response, "memory", memory);

    // Camera request stats
    cJSON *camera_stats = cJSON_CreateObject();
    cJSON_AddNumberToObject(camera_stats, "requests_total", camera_requests_total);
    cJSON_AddNumberToObject(camera_stats, "requests_failed", camera_requests_failed);
    cJSON_AddStringToObject(camera_stats, "last_error", last_camera_error);
    cJSON_AddBoolToObject(camera_stats, "logged_in", camera_logged_in);
    cJSON_AddBoolToObject(camera_stats, "is_recording", camera_recording);
    cJSON_AddStringToObject(camera_stats, "last_getcurprop", last_getcurprop_response);
    cJSON_AddItemToObject(response, "camera", camera_stats);

    // API stats
    cJSON *api_stats = cJSON_CreateObject();
    cJSON_AddNumberToObject(api_stats, "requests_total", api_requests_total);
    cJSON_AddItemToObject(response, "api", api_stats);

    // Uptime
    int64_t uptime_us = esp_timer_get_time() - boot_time_us;
    int uptime_sec = (int)(uptime_us / 1000000);
    cJSON_AddNumberToObject(response, "uptime_seconds", uptime_sec);

    // Network status
    cJSON *network = cJSON_CreateObject();
    cJSON_AddBoolToObject(network, "wifi_connected", wifi_connected);
    cJSON_AddBoolToObject(network, "eth_connected", eth_connected);
    char ip_str[16];
    snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&s_wifi_ip));
    cJSON_AddStringToObject(network, "wifi_ip", ip_str);
    snprintf(ip_str, sizeof(ip_str), IPSTR, IP2STR(&s_eth_ip));
    cJSON_AddStringToObject(network, "eth_ip", ip_str);
    cJSON_AddItemToObject(response, "network", network);

    // Task info
    cJSON *tasks = cJSON_CreateObject();
    cJSON_AddNumberToObject(tasks, "task_count", uxTaskGetNumberOfTasks());
    cJSON_AddItemToObject(response, "tasks", tasks);

    char *json_str = cJSON_Print(response);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, json_str, strlen(json_str));

    free(json_str);
    cJSON_Delete(response);

    // Log memory after debug request
    log_memory_stats("DEBUG");

    return ESP_OK;
}

// GET /api/proxy/* - Proxy requests to camera for testing
// Usage: GET /api/proxy/api/cam/getcurprop?seq=0
//        GET /api/proxy/wpd/VNCX02/images/rc/RcPBt_N.png
static esp_err_t proxy_handler(httpd_req_t *req)
{
    api_requests_total++;
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    // Extract the path after /api/proxy
    const char *proxy_prefix = "/api/proxy";
    const char *camera_path = req->uri + strlen(proxy_prefix);

    if (!camera_path || strlen(camera_path) == 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing camera path");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "Proxy request: %s", camera_path);

    // Allocate response buffer
    char *response = heap_caps_malloc(8192, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (!response) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "Memory allocation failed");
        return ESP_FAIL;
    }

    esp_err_t err = camera_request(camera_path, response, 8192);

    if (err == ESP_OK) {
        // Detect content type based on path
        if (strstr(camera_path, ".png") || strstr(camera_path, ".jpg")) {
            httpd_resp_set_type(req, "image/png");
        } else if (strstr(camera_path, ".htm")) {
            httpd_resp_set_type(req, "text/html");
        } else {
            httpd_resp_set_type(req, "application/json");
        }
        httpd_resp_send(req, response, strlen(response));
    } else {
        httpd_resp_set_type(req, "application/json");
        char error_json[128];
        snprintf(error_json, sizeof(error_json), "{\"error\":\"%s\",\"path\":\"%s\"}", esp_err_to_name(err), camera_path);
        httpd_resp_send(req, error_json, -1);
    }

    free(response);
    return ESP_OK;
}

// GET /api/ping - Simple ping for connection testing
static esp_err_t ping_handler(httpd_req_t *req)
{
    api_requests_total++;
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_send(req, "{\"pong\":true}", -1);
    return ESP_OK;
}

// POST /api/polling - Control polling (pause/resume for testing)
// POST /api/polling?pause=true  - Pause polling
// POST /api/polling?pause=false - Resume polling
// GET  /api/polling            - Get current state
static esp_err_t polling_handler(httpd_req_t *req)
{
    api_requests_total++;
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    // Check for pause parameter in query string
    char query[64] = "";
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
        char param[16];
        if (httpd_query_key_value(query, "pause", param, sizeof(param)) == ESP_OK) {
            if (strcmp(param, "true") == 0 || strcmp(param, "1") == 0) {
                polling_paused = true;
                ESP_LOGI(TAG, "Polling PAUSED for testing");
            } else if (strcmp(param, "false") == 0 || strcmp(param, "0") == 0) {
                polling_paused = false;
                ESP_LOGI(TAG, "Polling RESUMED");
            }
        }
    }

    // Return current state
    char response[64];
    snprintf(response, sizeof(response), "{\"polling_paused\":%s}", polling_paused ? "true" : "false");
    httpd_resp_send(req, response, -1);
    return ESP_OK;
}

// POST /api/tally/{state} - Set tally LED state
static esp_err_t tally_handler(httpd_req_t *req)
{
    api_requests_total++;

    // Extract state from URI: /api/tally/program, /api/tally/preview, /api/tally/off
    const char *uri = req->uri;
    const char *state_str = strrchr(uri, '/');
    if (!state_str) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing tally state");
        return ESP_FAIL;
    }
    state_str++;

    tally_state_t new_state = TALLY_OFF;

    if (strcmp(state_str, "program") == 0) {
        new_state = TALLY_PROGRAM;
    } else if (strcmp(state_str, "preview") == 0) {
        new_state = TALLY_PREVIEW;
    } else if (strcmp(state_str, "off") == 0) {
        new_state = TALLY_OFF;
    } else if (strcmp(state_str, "both") == 0) {
        new_state = TALLY_BOTH;
    } else {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Invalid state");
        return ESP_FAIL;
    }

    // Live tally wins over identify — cancel any identify blink before applying.
    identify_cancel_if_running();

    last_tally_command_us = esp_timer_get_time();  // feed watchdog
    tally_led_set(new_state);
    ws_broadcast_state();

    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"status\":\"ok\"}");
    return ESP_OK;
}

// POST /api/tally/brightness/{0-255} - Set LED brightness
static esp_err_t tally_brightness_handler(httpd_req_t *req)
{
    const char *uri = req->uri;
    const char *val_str = strrchr(uri, '/');
    if (!val_str) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Missing brightness value");
        return ESP_FAIL;
    }
    val_str++;

    int val = atoi(val_str);
    if (val < 0) val = 0;
    if (val > 255) val = 255;

    tally_brightness = (uint8_t)val;
    // Re-apply current state at new brightness
    tally_led_set(current_tally_state);
    ws_broadcast_state();

    ESP_LOGI(TAG, "Tally brightness set to %d", val);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"status\":\"ok\"}");
    return ESP_OK;
}

// ===========================================================================
//          OTA UPDATE HANDLERS
// ===========================================================================

static void ota_update_task(void *pvParameter)
{
    if (xSemaphoreTake(ota_mutex, portMAX_DELAY) != pdTRUE) {
        vTaskDelete(NULL);
        return;
    }
    ota_state = OTA_STATE_DOWNLOADING;
    ota_progress = 0;
    ota_error[0] = '\0';
    xSemaphoreGive(ota_mutex);

    // Refuse update while recording
    if (camera_recording) {
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        // Error string FIRST, then state — lock-free readers snapshot state first
        // and only read the error string when state==ERROR, so writing the string
        // before the state flip keeps them consistent.
        strncpy(ota_error, "Cannot update while recording", sizeof(ota_error) - 1);
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "OTA: Starting download from %s", ota_url);

    const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);
    if (update_partition == NULL) {
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        strncpy(ota_error, "No OTA partition found", sizeof(ota_error) - 1);
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "OTA: Writing to partition subtype %d at offset 0x%x",
             update_partition->subtype, (unsigned int)update_partition->address);

    esp_http_client_config_t http_config = {
        .url = ota_url,
        .timeout_ms = 30000,
        .buffer_size = 4096,
    };

    esp_http_client_handle_t client = esp_http_client_init(&http_config);
    if (client == NULL) {
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        strncpy(ota_error, "HTTP client init failed", sizeof(ota_error) - 1);
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        vTaskDelete(NULL);
        return;
    }

    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: HTTP open failed: %s", esp_err_to_name(err));
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        snprintf(ota_error, sizeof(ota_error), "HTTP open failed: %s", esp_err_to_name(err));
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        esp_http_client_cleanup(client);
        vTaskDelete(NULL);
        return;
    }

    int content_length = esp_http_client_fetch_headers(client);
    ESP_LOGI(TAG, "OTA: Content-Length: %d", content_length);

    esp_ota_handle_t ota_handle = 0;
    err = esp_ota_begin(update_partition, OTA_WITH_SEQUENTIAL_WRITES, &ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: esp_ota_begin failed: %s", esp_err_to_name(err));
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        snprintf(ota_error, sizeof(ota_error), "OTA begin failed: %s", esp_err_to_name(err));
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        esp_http_client_cleanup(client);
        vTaskDelete(NULL);
        return;
    }

    char *buf = malloc(4096);
    if (!buf) {
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        strncpy(ota_error, "Out of memory", sizeof(ota_error) - 1);
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        esp_ota_abort(ota_handle);
        esp_http_client_cleanup(client);
        vTaskDelete(NULL);
        return;
    }

    int total_read = 0;
    int read_len;

    while ((read_len = esp_http_client_read(client, buf, 4096)) > 0) {
        err = esp_ota_write(ota_handle, buf, read_len);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "OTA: Write failed: %s", esp_err_to_name(err));
            xSemaphoreTake(ota_mutex, portMAX_DELAY);
            snprintf(ota_error, sizeof(ota_error), "Write failed: %s", esp_err_to_name(err));
            ota_state = OTA_STATE_ERROR;
            xSemaphoreGive(ota_mutex);
            free(buf);
            esp_ota_abort(ota_handle);
            esp_http_client_cleanup(client);
            vTaskDelete(NULL);
            return;
        }
        total_read += read_len;
        if (content_length > 0) {
            xSemaphoreTake(ota_mutex, portMAX_DELAY);
            ota_progress = (total_read * 100) / content_length;
            xSemaphoreGive(ota_mutex);
        }
    }

    free(buf);
    esp_http_client_cleanup(client);
    ESP_LOGI(TAG, "OTA: Download complete, %d bytes total", total_read);

    // Finalize — brief FLASHING state while committing
    xSemaphoreTake(ota_mutex, portMAX_DELAY);
    ota_state = OTA_STATE_FLASHING;
    xSemaphoreGive(ota_mutex);

    err = esp_ota_end(ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: esp_ota_end failed: %s", esp_err_to_name(err));
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        snprintf(ota_error, sizeof(ota_error), "OTA end failed: %s", esp_err_to_name(err));
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        vTaskDelete(NULL);
        return;
    }

    err = esp_ota_set_boot_partition(update_partition);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA: Set boot partition failed: %s", esp_err_to_name(err));
        xSemaphoreTake(ota_mutex, portMAX_DELAY);
        snprintf(ota_error, sizeof(ota_error), "Set boot failed: %s", esp_err_to_name(err));
        ota_state = OTA_STATE_ERROR;
        xSemaphoreGive(ota_mutex);
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "OTA: Update complete! Rebooting in 2 seconds...");
    xSemaphoreTake(ota_mutex, portMAX_DELAY);
    ota_state = OTA_STATE_REBOOTING;
    ota_progress = 100;
    xSemaphoreGive(ota_mutex);

    vTaskDelay(pdMS_TO_TICKS(2000));
    esp_restart();
}

// POST /api/ota/update - Start OTA firmware update
static esp_err_t ota_update_handler(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    // Reject if already in progress
    if (xSemaphoreTake(ota_mutex, pdMS_TO_TICKS(100)) == pdTRUE) {
        bool busy = (ota_state != OTA_STATE_IDLE && ota_state != OTA_STATE_ERROR);
        xSemaphoreGive(ota_mutex);
        if (busy) {
            httpd_resp_set_status(req, "409 Conflict");
            httpd_resp_set_type(req, "application/json");
            httpd_resp_send(req, "{\"error\":\"OTA already in progress\"}", -1);
            return ESP_OK;
        }
    }

    int content_len = req->content_len;
    if (content_len <= 0 || content_len > 512) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Invalid body\"}", -1);
        return ESP_OK;
    }

    char body[513];
    int received = httpd_req_recv(req, body, content_len);
    if (received <= 0) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"No body\"}", -1);
        return ESP_OK;
    }
    body[received] = '\0';

    cJSON *json = cJSON_Parse(body);
    if (!json) {
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Invalid JSON\"}", -1);
        return ESP_OK;
    }

    cJSON *url_item = cJSON_GetObjectItem(json, "url");
    if (!url_item || !cJSON_IsString(url_item)) {
        cJSON_Delete(json);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"Missing url field\"}", -1);
        return ESP_OK;
    }

    const char *url = url_item->valuestring;
    if (strncmp(url, "http://", 7) != 0) {
        cJSON_Delete(json);
        httpd_resp_set_status(req, "400 Bad Request");
        httpd_resp_set_type(req, "application/json");
        httpd_resp_send(req, "{\"error\":\"URL must start with http://\"}", -1);
        return ESP_OK;
    }

    strncpy(ota_url, url, sizeof(ota_url) - 1);
    ota_url[sizeof(ota_url) - 1] = '\0';
    cJSON_Delete(json);

    xTaskCreate(ota_update_task, "ota_task", 8192, NULL, 5, NULL);

    httpd_resp_set_type(req, "application/json");
    httpd_resp_send(req, "{\"status\":\"started\"}", -1);
    return ESP_OK;
}

// GET /api/ota/status - Check OTA update progress
static esp_err_t ota_status_handler(httpd_req_t *req)
{
    httpd_resp_set_type(req, "application/json");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");

    // Lock-free reads: ota_state and ota_progress are volatile ints (atomic on xtensa).
    // ota_error is char[128] — only read when state==ERROR, and ota_update_task writes
    // the string BEFORE setting state=ERROR, then exits (never rewrites). So if we see
    // state==ERROR, subsequent reads of ota_error are stable.
    //
    // Taking the mutex here was causing "stuck on Starting" — the httpd worker could
    // not win the lock within 500 ms during heavy download, and the response fell
    // through to default "idle".
    ota_state_t snapshot_state = ota_state;
    int progress = ota_progress;
    char error_copy[128] = "";
    const char *state_str = "idle";

    switch (snapshot_state) {
        case OTA_STATE_IDLE:        state_str = "idle";        break;
        case OTA_STATE_DOWNLOADING: state_str = "downloading"; break;
        case OTA_STATE_FLASHING:    state_str = "flashing";    break;
        case OTA_STATE_REBOOTING:   state_str = "rebooting";   break;
        case OTA_STATE_ERROR:
            state_str = "error";
            strncpy(error_copy, ota_error, sizeof(error_copy) - 1);
            break;
    }

    cJSON *response = cJSON_CreateObject();
    cJSON_AddStringToObject(response, "state", state_str);
    cJSON_AddNumberToObject(response, "progress", progress);
    cJSON_AddStringToObject(response, "error", error_copy);

    char *json_str = cJSON_Print(response);
    httpd_resp_send(req, json_str, strlen(json_str));
    free(json_str);
    cJSON_Delete(response);
    return ESP_OK;
}

// OPTIONS handler for CORS preflight
static esp_err_t options_handler(httpd_req_t *req)
{
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Headers", "Content-Type");
    httpd_resp_send(req, NULL, 0);
    return ESP_OK;
}

// Initialize mDNS for Bonjour discovery
static void init_mdns(void)
{
    ESP_ERROR_CHECK(mdns_init());
    ESP_ERROR_CHECK(mdns_hostname_set("c200-controller"));
    ESP_ERROR_CHECK(mdns_instance_name_set("Canon C200 ESP32 Controller"));

    // Register HTTP service for Bonjour discovery
    mdns_service_add(NULL, "_http", "_tcp", 80, NULL, 0);

    ESP_LOGI(TAG, "mDNS initialized: c200-controller.local");
}

// Start HTTP server
static httpd_handle_t start_webserver(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 22;
    config.uri_match_fn = httpd_uri_match_wildcard;

    if (httpd_start(&server, &config) == ESP_OK) {
        // Status endpoints
        httpd_uri_t status_uri = {
            .uri = "/api/status",
            .method = HTTP_GET,
            .handler = status_handler,
        };
        httpd_register_uri_handler(server, &status_uri);

        httpd_uri_t camera_state_uri = {
            .uri = "/api/camera/state",
            .method = HTTP_GET,
            .handler = camera_state_handler,
        };
        httpd_register_uri_handler(server, &camera_state_uri);

        // Control endpoints
        httpd_uri_t rec_uri = {
            .uri = "/api/camera/rec",
            .method = HTTP_POST,
            .handler = rec_handler,
        };
        httpd_register_uri_handler(server, &rec_uri);

        httpd_uri_t iris_uri = {
            .uri = "/api/camera/iris/*",
            .method = HTTP_POST,
            .handler = iris_handler,
        };
        httpd_register_uri_handler(server, &iris_uri);

        httpd_uri_t iso_uri = {
            .uri = "/api/camera/iso/*",
            .method = HTTP_POST,
            .handler = iso_handler,
        };
        httpd_register_uri_handler(server, &iso_uri);

        httpd_uri_t shutter_uri = {
            .uri = "/api/camera/shutter/*",
            .method = HTTP_POST,
            .handler = shutter_handler,
        };
        httpd_register_uri_handler(server, &shutter_uri);

        httpd_uri_t nd_uri = {
            .uri = "/api/camera/nd/*",
            .method = HTTP_POST,
            .handler = nd_handler,
        };
        httpd_register_uri_handler(server, &nd_uri);

        httpd_uri_t wb_uri = {
            .uri = "/api/camera/wb/*",
            .method = HTTP_POST,
            .handler = wb_handler,
        };
        httpd_register_uri_handler(server, &wb_uri);

        httpd_uri_t focus_uri = {
            .uri = "/api/camera/focus/*",
            .method = HTTP_POST,
            .handler = focus_handler,
        };
        httpd_register_uri_handler(server, &focus_uri);

        httpd_uri_t aes_uri = {
            .uri = "/api/camera/aes/*",
            .method = HTTP_POST,
            .handler = aes_handler,
        };
        httpd_register_uri_handler(server, &aes_uri);

        httpd_uri_t wbk_uri = {
            .uri = "/api/camera/wbk/*",
            .method = HTTP_POST,
            .handler = wbk_handler,
        };
        httpd_register_uri_handler(server, &wbk_uri);

        // Camera Positions display endpoint
        httpd_uri_t display_uri = {
            .uri = "/api/display",
            .method = HTTP_POST,
            .handler = display_handler,
        };
        httpd_register_uri_handler(server, &display_uri);

        // Debug endpoint
        httpd_uri_t debug_uri = {
            .uri = "/api/debug",
            .method = HTTP_GET,
            .handler = debug_handler,
        };
        httpd_register_uri_handler(server, &debug_uri);

        // Ping endpoint
        httpd_uri_t ping_uri = {
            .uri = "/api/ping",
            .method = HTTP_GET,
            .handler = ping_handler,
        };
        httpd_register_uri_handler(server, &ping_uri);

        // Tally brightness endpoint (must be registered BEFORE /api/tally/* wildcard)
        httpd_uri_t tally_brightness_uri = {
            .uri = "/api/tally/brightness/*",
            .method = HTTP_POST,
            .handler = tally_brightness_handler,
            .user_ctx = NULL
        };
        httpd_register_uri_handler(server, &tally_brightness_uri);

        // Identify endpoint (must also be registered BEFORE /api/tally/* wildcard —
        // httpd first-match rule; without this, "identify" would fall through to tally_handler)
        httpd_uri_t identify_uri = {
            .uri = "/api/tally/identify",
            .method = HTTP_POST,
            .handler = identify_handler,
            .user_ctx = NULL
        };
        httpd_register_uri_handler(server, &identify_uri);

        // Tally LED control endpoint
        httpd_uri_t tally_uri = {
            .uri = "/api/tally/*",
            .method = HTTP_POST,
            .handler = tally_handler,
            .user_ctx = NULL
        };
        httpd_register_uri_handler(server, &tally_uri);

        // WebSocket endpoint — dashboard connects here for push updates
        httpd_uri_t ws_uri = {
            .uri = "/ws",
            .method = HTTP_GET,
            .handler = ws_handler,
            .is_websocket = true,
            .handle_ws_control_frames = true,
        };
        httpd_register_uri_handler(server, &ws_uri);

        // Polling control endpoint (GET to check, POST with ?pause=true/false to control)
        httpd_uri_t polling_get_uri = {
            .uri = "/api/polling",
            .method = HTTP_GET,
            .handler = polling_handler,
        };
        httpd_register_uri_handler(server, &polling_get_uri);

        httpd_uri_t polling_post_uri = {
            .uri = "/api/polling",
            .method = HTTP_POST,
            .handler = polling_handler,
        };
        httpd_register_uri_handler(server, &polling_post_uri);

        // Proxy endpoint - forwards requests to camera for testing
        httpd_uri_t proxy_uri = {
            .uri = "/api/proxy/*",
            .method = HTTP_GET,
            .handler = proxy_handler,
        };
        httpd_register_uri_handler(server, &proxy_uri);

        // OTA update endpoints
        httpd_uri_t ota_update_uri = {
            .uri = "/api/ota/update",
            .method = HTTP_POST,
            .handler = ota_update_handler,
        };
        httpd_register_uri_handler(server, &ota_update_uri);

        httpd_uri_t ota_status_uri = {
            .uri = "/api/ota/status",
            .method = HTTP_GET,
            .handler = ota_status_handler,
        };
        httpd_register_uri_handler(server, &ota_status_uri);

        // CORS preflight handler
        httpd_uri_t options_uri = {
            .uri = "/api/*",
            .method = HTTP_OPTIONS,
            .handler = options_handler,
        };
        httpd_register_uri_handler(server, &options_uri);

        ESP_LOGI(TAG, "HTTP server started on port %d", config.server_port);
        return server;
    }

    ESP_LOGE(TAG, "Failed to start HTTP server");
    return NULL;
}

// ===========================================================================
//          NETWORK EVENT HANDLERS
// ===========================================================================

static void wifi_event_handler(void* arg, esp_event_base_t event_base,
                              int32_t event_id, void* event_data)
{
    // Tracks the first disconnect in the current outage so we can self-reboot
    // if WiFi stays down too long. Reset on GOT_IP. File-scoped so a sustained
    // outage isn't measured as several short ones.
    static int64_t first_disconnect_us = 0;

    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
        ESP_LOGI(TAG, "WiFi connecting...");
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_connected = false;
        s_retry_num++;

        // Reconnect forever. Earlier code gave up after a bounded number of
        // retries, which bricked boards until power-cycled when an AP burped
        // long enough to exhaust the cap. The WiFi stack rate-limits its own
        // retry cadence — the next disconnect event won't fire until the
        // radio has actually tried again — so calling esp_wifi_connect()
        // every event is safe.
        esp_wifi_connect();
        ESP_LOGI(TAG, "WiFi reconnect attempt %d", s_retry_num);

        // Self-reboot escalation: if WiFi has been down >30 s but Ethernet is
        // up, the board is reachable to the camera but useless for tally/control.
        // Most root causes of a stuck WiFi state recover from a clean reboot.
        int64_t now = esp_timer_get_time();
        if (first_disconnect_us == 0) {
            first_disconnect_us = now;
        } else if (eth_connected
                   && (now - first_disconnect_us) > 30LL * 1000LL * 1000LL) {
            ESP_LOGE(TAG, "WiFi down >30s with Ethernet up — restarting to recover");
            esp_restart();
        }
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_BSS_RSSI_LOW) {
        // Signal dropped below the roam threshold. With WIFI_ALL_CHANNEL_SCAN +
        // WIFI_CONNECT_AP_BY_SIGNAL, esp_wifi_disconnect() + auto-reconnect will
        // re-evaluate every AP for our SSID and pick the strongest.
        wifi_event_bss_rssi_low_t *evt = (wifi_event_bss_rssi_low_t *)event_data;
        int64_t now = esp_timer_get_time();
        if ((now - last_roam_attempt_us) < ((int64_t)WIFI_ROAM_COOLDOWN_MS * 1000)) {
            ESP_LOGI(TAG, "RSSI low (%d dBm) but roam cooldown active; re-arming threshold", (int)evt->rssi);
            // The event only fires once per arm — re-arm so we get notified again later.
            esp_wifi_set_rssi_threshold(WIFI_ROAM_RSSI_THRESHOLD);
        } else {
            last_roam_attempt_us = now;
            ESP_LOGW(TAG, "WiFi RSSI dropped to %d dBm — initiating roam scan", (int)evt->rssi);
            esp_wifi_disconnect();
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t* event = (ip_event_got_ip_t*) event_data;
        s_wifi_ip = event->ip_info.ip;
        ESP_LOGI(TAG, "WiFi connected - IP:" IPSTR, IP2STR(&event->ip_info.ip));
        s_retry_num = 0;
        first_disconnect_us = 0;  // clear self-reboot timer on recovery
        wifi_connected = true;
        esp_ota_mark_app_valid_cancel_rollback();
        xEventGroupSetBits(s_event_group, WIFI_CONNECTED_BIT);

        // Arm the roam trigger. Fires WIFI_EVENT_STA_BSS_RSSI_LOW exactly once
        // when current AP's RSSI falls below WIFI_ROAM_RSSI_THRESHOLD.
        esp_wifi_set_rssi_threshold(WIFI_ROAM_RSSI_THRESHOLD);

        // Start HTTP server when WiFi is connected
        if (server == NULL) {
            start_webserver();
        }

        // Initialize mDNS for Bonjour discovery
        init_mdns();
    }
}

static void eth_event_handler(void *arg, esp_event_base_t event_base,
                             int32_t event_id, void *event_data)
{
    uint8_t mac_addr[6] = {0};
    esp_eth_handle_t eth_handle = *(esp_eth_handle_t *)event_data;

    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        esp_eth_ioctl(eth_handle, ETH_CMD_G_MAC_ADDR, mac_addr);
        ESP_LOGI(TAG, "Ethernet Link Up");
        ESP_LOGI(TAG, "  MAC: %02x:%02x:%02x:%02x:%02x:%02x",
                 mac_addr[0], mac_addr[1], mac_addr[2], mac_addr[3], mac_addr[4], mac_addr[5]);
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "Ethernet Link Down");
        eth_connected = false;
        camera_logged_in = false;
        xEventGroupClearBits(s_event_group, CAMERA_READY_BIT);
        break;
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "Ethernet Started");
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGI(TAG, "Ethernet Stopped");
        eth_connected = false;
        camera_logged_in = false;
        break;
    default:
        break;
    }
}

static void got_ip_event_handler(void *arg, esp_event_base_t event_base,
                                int32_t event_id, void *event_data)
{
    if (event_id == IP_EVENT_ETH_GOT_IP) {
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        s_eth_ip = event->ip_info.ip;
        ESP_LOGI(TAG, "Ethernet got IP:" IPSTR, IP2STR(&event->ip_info.ip));
        eth_connected = true;
        xEventGroupSetBits(s_event_group, ETH_CONNECTED_BIT);

        // Try to login to camera
        vTaskDelay(pdMS_TO_TICKS(1000)); // Give camera time
        if (camera_login() == ESP_OK) {
            xEventGroupSetBits(s_event_group, CAMERA_READY_BIT);
        }
    }
}

// ===========================================================================
//          ETHERNET INITIALIZATION (W5500 with Static IP)
// ===========================================================================

static esp_err_t ethernet_init_w5500(void)
{
    ESP_LOGI(TAG, "Initializing W5500 Ethernet with static IP...");
    ESP_LOGI(TAG, "  Static IP: %s", ETH_STATIC_IP);
    ESP_LOGI(TAG, "  Gateway: %s", ETH_STATIC_GW);
    ESP_LOGI(TAG, "  Using pins: CS=%d MOSI=%d MISO=%d SCLK=%d INT=%d",
             ETH_SPI_CS_GPIO, ETH_SPI_MOSI_GPIO, ETH_SPI_MISO_GPIO,
             ETH_SPI_SCLK_GPIO, ETH_SPI_INT_GPIO);

    ESP_ERROR_CHECK(gpio_install_isr_service(0));

    // Create network interface for Ethernet
    esp_netif_inherent_config_t esp_netif_config = ESP_NETIF_INHERENT_DEFAULT_ETH();
    esp_netif_config_t cfg = {
        .base = &esp_netif_config,
        .stack = ESP_NETIF_NETSTACK_DEFAULT_ETH,
    };
    eth_netif = esp_netif_new(&cfg);

    // Configure static IP
    esp_netif_dhcpc_stop(eth_netif);

    esp_netif_ip_info_t ip_info;
    ip_info.ip.addr = esp_ip4addr_aton(ETH_STATIC_IP);
    ip_info.netmask.addr = esp_ip4addr_aton(ETH_STATIC_NETMASK);
    ip_info.gw.addr = esp_ip4addr_aton(ETH_STATIC_GW);
    esp_netif_set_ip_info(eth_netif, &ip_info);

    s_eth_ip = ip_info.ip;

    // Configure SPI bus
    spi_bus_config_t buscfg = {
        .mosi_io_num = ETH_SPI_MOSI_GPIO,
        .miso_io_num = ETH_SPI_MISO_GPIO,
        .sclk_io_num = ETH_SPI_SCLK_GPIO,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
    };

    ESP_ERROR_CHECK(spi_bus_initialize(ETH_SPI_HOST, &buscfg, SPI_DMA_CH_AUTO));

    // Configure SPI device for W5500
    spi_device_interface_config_t devcfg = {
        .mode = 0,
        .clock_speed_hz = ETH_SPI_CLOCK_MHZ * 1000 * 1000,
        .queue_size = 20,
        .spics_io_num = ETH_SPI_CS_GPIO,
    };

    spi_device_handle_t spi_handle = NULL;
    ESP_ERROR_CHECK(spi_bus_add_device(ETH_SPI_HOST, &devcfg, &spi_handle));

    // W5500 MAC and PHY configuration
    eth_w5500_config_t w5500_config = ETH_W5500_DEFAULT_CONFIG(ETH_SPI_HOST, &devcfg);
    w5500_config.int_gpio_num = ETH_SPI_INT_GPIO;

    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.phy_addr = ETH_SPI_PHY_ADDR;
    phy_config.reset_gpio_num = ETH_SPI_PHY_RST_GPIO;

    esp_eth_mac_t *mac = esp_eth_mac_new_w5500(&w5500_config, &mac_config);
    esp_eth_phy_t *phy = esp_eth_phy_new_w5500(&phy_config);

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_config, &eth_handle));

    // Attach Ethernet driver to TCP/IP stack
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, esp_eth_new_netif_glue(eth_handle)));

    // Register event handlers
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &got_ip_event_handler, NULL));

    // Start Ethernet driver
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    ESP_LOGI(TAG, "W5500 Ethernet initialization complete");
    return ESP_OK;
}

// ===========================================================================
//          WIFI INITIALIZATION (DHCP)
// ===========================================================================

static void wifi_init_sta(void)
{
    wifi_netif = esp_netif_create_default_wifi_sta();
    assert(wifi_netif);

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    ESP_ERROR_CHECK(esp_event_handler_instance_register(WIFI_EVENT,
                                                        ESP_EVENT_ANY_ID,
                                                        &wifi_event_handler,
                                                        NULL,
                                                        NULL));
    ESP_ERROR_CHECK(esp_event_handler_instance_register(IP_EVENT,
                                                        IP_EVENT_STA_GOT_IP,
                                                        &wifi_event_handler,
                                                        NULL,
                                                        NULL));

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = WIFI_SSID,
            .password = WIFI_PASSWORD,
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
            // Scan every channel and pick the strongest matching AP, instead of
            // grabbing the first one to respond. Adds ~2 s to boot but means a
            // box near a strong AP no longer associates with a weak one.
            .scan_method = WIFI_ALL_CHANNEL_SCAN,
            .sort_method = WIFI_CONNECT_AP_BY_SIGNAL,
            .pmf_cfg = {
                .capable = true,
                .required = false
            },
        },
    };

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi_config));
    ESP_ERROR_CHECK(esp_wifi_start());

    // Disable WiFi modem sleep. Default WIFI_PS_MIN_MODEM parks the radio between
    // DTIM beacons (100–300 ms), producing exactly the RTT jitter that broke tally
    // on Cam 3 (84–443 ms, stddev 179). Boards are wall-powered; the ~70 mA extra
    // draw is irrelevant. Latency stability is non-negotiable for a tally light.
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    ESP_LOGI(TAG, "WiFi init finished. Connecting to SSID:%s", WIFI_SSID);
}

// ===========================================================================
//          MAIN APPLICATION
// ===========================================================================

void app_main(void)
{
    // Record boot time for uptime calculation
    boot_time_us = esp_timer_get_time();

    ESP_LOGI(TAG, "===========================================================");
    ESP_LOGI(TAG, "     Canon C200 Camera Controller - Firmware v3.0");
    ESP_LOGI(TAG, "===========================================================");

    // Log initial memory stats
    log_memory_stats("BOOT");
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "Network Architecture:");
    ESP_LOGI(TAG, "  [Dashboard/Companion] --WiFi-- [ESP32] --Ethernet-- [C200]");
    ESP_LOGI(TAG, "");

    // Initialize NVS
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // Create synchronization primitives
    s_event_group = xEventGroupCreate();
    camera_state_mutex = xSemaphoreCreateMutex();
    ws_mutex = xSemaphoreCreateMutex();
    ota_mutex = xSemaphoreCreateMutex();
    oled_data_mutex = xSemaphoreCreateMutex();

    // Initialize tally LED
    tally_led_init();

    // Initialize TSL listener state and load saved config from NVS. Listener
    // task is started later, after networking is up. If no config has been
    // saved, the task idles waiting for a tsl_config push over WebSocket.
    s_tsl_cfg_mutex = xSemaphoreCreateMutex();
    tsl_config_load();

    // Initialize TCP/IP stack
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    // Initialize Ethernet FIRST (for camera connection)
    ESP_LOGI(TAG, "Step 1: Initializing Ethernet (camera connection)...");
    ret = ethernet_init_w5500();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "Ethernet initialization FAILED!");
        ESP_LOGE(TAG, "  Check your board's SPI pin configuration");
    }

    // Initialize WiFi (for dashboard/Companion)
    ESP_LOGI(TAG, "Step 2: Connecting to WiFi (upstream network)...");
    wifi_init_sta();

    // Start camera polling task
    xTaskCreate(camera_poll_task, "camera_poll", 8192, NULL, 5, NULL);

    // Start OLED display task
    xTaskCreate(display_task, "oled_display", 4096, NULL, 3, NULL);

    // Start TSL listener task — receives tally state directly from the
    // switcher, removing the dashboard from the tally critical path.
    xTaskCreate(tsl_listener_task, "tsl_listen", 4096, NULL, 5, NULL);

    // Wait for connections
    ESP_LOGI(TAG, "Step 3: Waiting for network connections...");
    EventBits_t bits = xEventGroupWaitBits(s_event_group,
                                           WIFI_CONNECTED_BIT | ETH_CONNECTED_BIT,
                                           pdFALSE,
                                           pdFALSE,
                                           pdMS_TO_TICKS(30000));

    ESP_LOGI(TAG, "===========================================================");

    if (bits & WIFI_CONNECTED_BIT) {
        ESP_LOGI(TAG, "WiFi: CONNECTED (IP: " IPSTR ")", IP2STR(&s_wifi_ip));
        ESP_LOGI(TAG, "  API Server: http://" IPSTR "/api/", IP2STR(&s_wifi_ip));
    } else {
        ESP_LOGE(TAG, "WiFi: FAILED - Check SSID and password");
    }

    if (eth_connected) {
        ESP_LOGI(TAG, "Ethernet: CONNECTED (IP: " IPSTR ")", IP2STR(&s_eth_ip));
        ESP_LOGI(TAG, "  Camera: http://%s", CAMERA_IP);
    } else {
        ESP_LOGW(TAG, "Ethernet: Waiting for link...");
    }

    if (camera_logged_in) {
        ESP_LOGI(TAG, "Camera: LOGGED IN");
    }

    ESP_LOGI(TAG, "===========================================================");
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "API Endpoints:");
    ESP_LOGI(TAG, "  GET  /api/status          - System status");
    ESP_LOGI(TAG, "  GET  /api/camera/state    - Camera settings");
    ESP_LOGI(TAG, "  GET  /api/debug           - Debug info & memory stats");
    ESP_LOGI(TAG, "  GET  /api/ping            - Connectivity test");
    ESP_LOGI(TAG, "  POST /api/camera/rec      - Toggle recording");
    ESP_LOGI(TAG, "  POST /api/camera/iris/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/iso/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/shutter/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/nd/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/aes/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/wbk/{plus|minus}");
    ESP_LOGI(TAG, "  POST /api/camera/wb/{awb|daylight|tungsten|user1}");
    ESP_LOGI(TAG, "  POST /api/camera/focus/{oneshot|lock|near1|far1}");
    ESP_LOGI(TAG, "  POST /api/tally/{program|preview|off|both} - Set tally LED");
    ESP_LOGI(TAG, "");
    ESP_LOGI(TAG, "===========================================================");

    // Status monitoring loop
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(30000)); // Every 30 seconds

        // Log memory stats periodically
        log_memory_stats("MONITOR");

        // Calculate uptime
        int64_t uptime_us = esp_timer_get_time() - boot_time_us;
        int uptime_min = (int)(uptime_us / 60000000);

        ESP_LOGI(TAG, "Status: WiFi[%s] Eth[%s] Camera[%s] | Uptime: %dm | Cam reqs: %lu (fail: %lu)",
                 wifi_connected ? "UP" : "DOWN",
                 eth_connected ? "UP" : "DOWN",
                 camera_logged_in ? "OK" : "NO",
                 uptime_min,
                 camera_requests_total,
                 camera_requests_failed);
    }
}
