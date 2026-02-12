# ESP32 Firmware Build Guide

> **Note:** The recommended way to build and flash firmware is with the [ESP32Flasher](../ESP32Flasher/) macOS app, which handles credentials and flashing automatically. Use this guide only for manual builds or development.

## Prerequisites

- ESP-IDF v5.x installed (typically at `~/esp/esp-idf`)
- ESP32-S3 board connected via USB

## Configuration

Before building, set your network credentials in `ESP32Flasher/FirmwareTemplate/main/main.c`:

```c
#define WIFI_SSID      "YOUR_WIFI_NETWORK"
#define WIFI_PASSWORD  "YOUR_WIFI_PASSWORD"

#define CAMERA_IP       "1.1.1.2"        // Canon C200 Ethernet IP
#define CAMERA_USER     "admin"           // Browser Remote username
#define CAMERA_PASS     "admin"           // Browser Remote password

#define ETH_STATIC_IP      "1.1.1.1"     // ESP32 Ethernet IP (same subnet as camera)
#define ETH_STATIC_NETMASK "255.255.255.0"
#define ETH_STATIC_GW      "1.1.1.2"
```

> **Security:** Never commit `main.c` or `sdkconfig` with real credentials to version control.

## Build Commands

### 1. Set up ESP-IDF environment

```bash
source ~/esp/esp-idf/export.sh
```

### 2. Navigate to firmware

```bash
cd "ESP32Flasher/FirmwareTemplate"
```

### 3. Build firmware

```bash
idf.py build
```

### 4. Find USB port

```bash
ls /dev/cu.usb*
# Typically: /dev/cu.usbmodem2101
```

### 5. Flash firmware

```bash
idf.py -p /dev/cu.usbmodem2101 flash
```

### 6. Monitor serial output (optional)

```bash
idf.py -p /dev/cu.usbmodem2101 monitor
```

Press `Ctrl+]` to exit monitor.

## One-liner Build and Flash

```bash
source ~/esp/esp-idf/export.sh && \
  cd "ESP32Flasher/FirmwareTemplate" && \
  idf.py build && \
  idf.py -p /dev/cu.usbmodem2101 flash
```

## Key Files

| File | Purpose |
|------|---------|
| `main/main.c` | Main firmware source code |
| `sdkconfig` | ESP-IDF build configuration (not committed) |
| `sdkconfig.defaults` | Default configuration values (safe to commit) |
| `CMakeLists.txt` | Build system configuration |

## API Endpoints (exposed on WiFi)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | ESP32 and camera status |
| `/api/camera/state` | GET | Current camera settings |
| `/api/camera/rec` | POST | Toggle recording |
| `/api/camera/iris/{plus\|minus}` | POST | Iris adjustment |
| `/api/camera/iso/{plus\|minus}` | POST | ISO adjustment |
| `/api/camera/shutter/{plus\|minus}` | POST | Shutter adjustment |
| `/api/camera/nd/{plus\|minus}` | POST | ND filter adjustment |
| `/api/camera/wb/{mode}` | POST | White balance mode |
| `/api/camera/aes/{plus\|minus}` | POST | AE shift adjustment |
| `/api/camera/wbk/{plus\|minus}` | POST | WB Kelvin adjustment |
| `/ws` | WebSocket | Real-time state push |

## Recording Detection

The firmware polls `/api/cam/getcurprop?seq=N` from the Canon C200 Browser Remote API:

- `"rec": "stby"` = Standby (not recording)
- `"rec": "rec"` = Recording

The sequence number increments when camera state changes, enabling efficient polling.
