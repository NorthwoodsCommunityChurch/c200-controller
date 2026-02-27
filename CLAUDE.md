# C200 Controller — Project Context

## Project Summary

macOS app (SwiftUI) that controls Canon C200 cameras wirelessly via an ESP32-S3 hardware bridge. Production tool used at Northwoods Community Church for live broadcasts.

## Repo

`NorthwoodsCommunityChurch/c200-controller` (public)

## Architecture

```
Canon C200 (Ethernet) → ESP32-S3 Bridge (WiFi) → C200Controller.app (macOS)
                                                        ↑
                                              companion-module/ (Bitfocus, future)
```

## Build

```bash
cd C200Controller && bash build.sh
```

App opens automatically after build. No external Swift dependencies.

## Key Files

| File | Purpose |
|------|---------|
| `Camera.swift` | `CameraState` class — connection, polling, all camera commands |
| `CameraManager.swift` | Multi-camera list, Bonjour discovery, persistence |
| `ContentView.swift` | Main UI — grid of CameraTile views, PresetsPanel sidebar |
| `PresetsPanel.swift` | Preset list sidebar, edit/recall UI |
| `PresetManager.swift` | Preset CRUD, UserDefaults persistence |
| `Preset.swift` | `CameraPreset` and `CameraSettings` data models |

## Important: Camera Fine Increment Setting

**Canon C200 Menu → ISO/Gain → Fine Increment must be OFF**

- Fine Increment ON: each command = 1/3 stop physical, but the reported `av` value only updates every ~3 presses → the dashboard overshoots by 3x
- Fine Increment OFF: each command = 1 full stop change in both physical AND reported value

## Connection Types

```swift
enum ConnectionType: String, Codable {
    case esp32   // Via ESP32-S3 bridge (WebSocket push)
    case direct  // Canon Browser Remote directly (HTTP poll only)
}
```

- ESP32 connection: WebSocket push updates + REST control commands
- Direct connection: HTTP poll for state, HTTP control commands (reduced functionality)

## ESP32 Bridge API

**Camera control endpoints (POST):**
- `/api/camera/iris/{plus|minus}`
- `/api/camera/iso/{plus|minus}`
- `/api/camera/shutter/{plus|minus}`
- `/api/camera/nd/{plus|minus}`
- `/api/camera/wb/{mode}` — e.g. `auto`, `tungsten`, `kelvin`
- `/api/camera/aes/{plus|minus}`
- `/api/camera/wbk/{plus|minus}`
- `/api/camera/rec` — toggle recording

**Tally control endpoints (POST):**
- `/api/tally/brightness/{0-255}` — set LED PWM brightness (register BEFORE `/api/tally/*`)
- `/api/tally/program` — red LED on at current brightness
- `/api/tally/preview` — green LED on at current brightness
- `/api/tally/both` — both LEDs on (amber) at current brightness
- `/api/tally/off` — both LEDs off

**Important:** `/api/tally/brightness/*` must be registered before `/api/tally/*` in the HTTP server. ESP-IDF uses first-match ordering for wildcard routes — if the general wildcard is first, it intercepts brightness requests.

**Camera Positions display endpoint (POST):**
- `/api/display` — receives `{"operator": "Name", "lens": "Lens"}` from Camera Positions app; updates OLED rows 1–2

**State endpoints (GET):**
- `/api/status` — ESP32 + camera connected/recording status (includes `camera_number` field)
- `/api/camera/state` — full settings JSON
- `/ws` — WebSocket for push updates

**WebSocket push message format:**
```json
{
  "type": "state",
  "recording": false,
  "camera_connected": true,
  "wifi_connected": true,
  "eth_connected": true,
  "av": { "value": "F2.8", "enabled": true },
  "gcv": { "value": "800", "enabled": true },
  "ssv": { "value": "180.00", "enabled": true },
  "tally": "off"
}
```

**Tally field values:** `"off"`, `"program"`, `"preview"`, `"both"`

## Canon C200 API Property Keys

| Dashboard Label | ESP32 JSON Key | Canon API Key | Example Value |
|-----------------|---------------|---------------|---------------|
| Aperture | `av` | `av` | `"F2.8"` |
| ISO | `gcv` | `gcv` | `"800"` |
| Shutter | `ssv` | `ssv` | `"180.00"` |
| ND Filter | `ndv` | `ndv` | varies |
| WB Mode | `wbm` | `wbm` | `"auto"`, `"tungsten"`, `"kelvin"` |
| WB Kelvin | `wbvk` | `wbvk` | `"5600K"` |
| AE Shift | `aesv` | `aesv` | `"+0.5"` |

## Preset Recall Logic

`applyPreset(_:)` in `Camera.swift` — sequential per-property approach:

1. Single `fetchESP32CameraState()` to get current values
2. For each included property: call `adjustToValue(target:control:inverted:)`
3. `adjustToValue` sends step commands until current == target
4. After each command: adaptive poll (50ms intervals, up to 3000ms for iris, 1500ms for others)
5. Adaptive poll exits early when WebSocket push delivers the new value

**@MainActor serialization note:** `CameraState` is `@MainActor`. All `adjustToValue` calls execute sequentially on the main actor, even when wrapped in `withTaskGroup` or independent `Task {}`. True parallelism would require restructuring to run HTTP requests off-actor with a callback — not currently implemented.

## WebSocket + Polling Architecture

Post-command flow (ESP32 side):
1. Dashboard sends POST command → ESP32 receives
2. ESP32 sets `poll_state_now = true` and `poll_property_hint = "av"` (or appropriate)
3. Main poll loop sees `poll_state_now` → waits 150ms → polls single property via Camera API
4. Broadcasts new value over WebSocket immediately
5. Waits 500ms, then resumes normal polling cycle

Dashboard side:
1. After HTTP POST: waits 300ms (give camera time to process)
2. Adaptive poll: checks `getCurrentValue()` every 50ms
3. Exits poll when value changes OR after timeout (3000ms iris, 1500ms others)

## TSL Tally System

The dashboard receives TSL UMD protocol packets from video switchers (ATEM, etc.) and controls RGB LEDs on each ESP32 bridge.

### Architecture

```
Video Switcher → TSL TCP (port 5201) → Dashboard TSLClient → Camera TSL Assignment → ESP32 /api/tally → RGB LED
```

### Key Files

| File | Purpose |
|------|---------|
| `TSLClient.swift` | TCP listener for TSL 3.1 and 5.0 protocols |
| `TallySettingsView.swift` | UI for TSL port config, camera assignments, LED brightness |
| `Camera.swift` | `tslIndices: [Int]` field, tally state, `updateTallyState()`, `sendBrightness()` |
| `CameraManager.swift` | TSL lifecycle, tally propagation, listening/connected state tracking |
| `ContentView.swift` | Tally border rendering on camera tiles |

### TSL Protocol Support

- **TSL UMD 3.1** (18-byte fixed format) — most common
- **TSL UMD 5.0** (variable length) — newer format
- **TCP only** (port 5201 configurable) — UDP not supported
- Automatic protocol detection based on packet structure

### Camera Assignment

Each camera can be assigned one or more TSL indices (1-127) via a multi-select popover in Tally Settings (Cmd+Shift+T). When a TSL packet arrives with a matching index:
1. Dashboard matches index to all cameras with that index in their `tslIndices` array
2. Sends POST to `/api/tally/{state}` on each matching ESP32
3. ESP32 sets RGB LED at current brightness and broadcasts via WebSocket
4. Dashboard shows tally border (red=program, green=preview)

Multiple cameras can share the same TSL index (both will light up). Multiple indices per camera are supported (e.g., a camera on inputs 1 and 5 will respond to either).

**TSL state logic:** Program always wins over preview — if program=true, "program" is sent regardless of preview state. This avoids the brief amber flash that occurs when some switchers (ATEM) momentarily send both program and preview true during a cut.

**LED brightness:** Global brightness slider (1–100%) in Tally Settings sends PWM value (0–255) to all ESP32s via `/api/tally/brightness/{value}`. Brightness is persisted in UserDefaults and restored when each ESP32 connects.

### LED Wiring

ESP32 GPIO pins for tally LEDs (controlled via LEDC PWM for brightness):
- **GPIO 1** — Red LED (program)
- **GPIO 2** — Green LED (preview)
- Standard 5mm LEDs with 220Ω resistors to GND
- LEDC timer 0, channels 0 (red) and 1 (green), 8-bit resolution (0–255), 1000 Hz

### TSL Status (Three States)

The dashboard TSL indicator shows three states:
- **Gray** — TSL disabled
- **Yellow** — Listening (port bound, no switcher connected)
- **Green** — Switcher connected and sending data

### Testing

**Python test script:**
```bash
python3 test_tsl.py  # automated sequence
python3 test_tsl.py --interactive  # manual testing
```

**Bash ESP32 test:**
```bash
bash test_esp32_tally.sh  # direct ESP32 REST API test
```

## Hardware

- ESP32-S3-ETH board (W5500 Ethernet)
- 16MB flash, PSRAM
- Ethernet → static IP on camera subnet
- WiFi → production network (credentials set at flash time via ESP32Flasher app)

## Network Config (Set at Flash Time)

Firmware is built with network credentials via ESP32Flasher app. **Never hardcode in source.**

```c
// Set in ESP32Flasher UI, compiled into firmware:
#define WIFI_SSID      "your-wifi-name"
#define WIFI_PASSWORD  "your-wifi-password"
#define CAMERA_IP      "1.1.1.2"      // Camera's Ethernet IP
#define ETH_STATIC_IP  "1.1.1.1"      // ESP32 Ethernet IP (must be same subnet)
```

## ESP32 Firmware Development

**IMPORTANT:** The ESP32Flasher GUI app is NOT used for development. Use direct ESP-IDF commands instead.

### Firmware Location

Source file: `ESP32Flasher/FirmwareTemplate/main/main.c`

This is the C firmware that runs on the ESP32-S3 bridge. All camera control, HTTP server, WebSocket, and tally LED logic lives here.

### Build & Flash Workflow

ESP-IDF is installed at `~/esp/esp-idf/`

**Build firmware:**
```bash
cd "/Users/aaronlarson/Library/CloudStorage/OneDrive-NorthwoodsCommunityChurch/VS Code/ESP32 Canon C200/ESP32Flasher/FirmwareTemplate"
source ~/esp/esp-idf/export.sh 2>/dev/null
idf.py build
```

**Flash to ESP32:**
```bash
idf.py -p /dev/cu.usbmodem2101 flash
```

**Monitor serial output:**
```bash
idf.py -p /dev/cu.usbmodem2101 monitor
```

**Note:** Serial port may vary. Use `ls /dev/cu.*` to find the correct port when ESP32 is plugged in.

### Development Notes

- Network credentials (WiFi SSID/password, camera IP, ESP32 static IP) are hardcoded in `main.c` during development
- The ESP32Flasher GUI app exists for end-user firmware flashing but is not used in the dev workflow
- After code changes: clean build recommended (`idf.py fullclean && idf.py build`)
- Build artifacts stored in `FirmwareTemplate/build/`

## OLED Display Layout (128×32, 4 rows)

| Row | When `CAMERA_NUMBER > 0`         | When `CAMERA_NUMBER == 0`       |
|-----|----------------------------------|---------------------------------|
| 0   | `CAM N  Tally: PRG`              | `WiFi:OK  Eth:OK`               |
| 1   | Operator name (from `/api/display`) | Operator name                |
| 2   | First lens name (from `/api/display`) | First lens name             |
| 3   | `Cam:OK  Rec:LIVE`               | `Cam:OK  Rec:LIVE`              |

**To set camera number:** Edit `#define CAMERA_NUMBER N` in `main.c` before flashing.

## Release Rule — Every Change Must Ship

**Any change to the app OR firmware must go through a full release so the client can receive it via Sparkle OTA.**

This means every fix, no matter how small, requires:
1. Bump the version (ask first — usually patch: 1.0.x)
2. Rebuild the app (`bash build.sh`) — bundles the latest firmware automatically
3. Create a signed zip and GitHub release
4. Update the appcast (`app-updates/appcast-c200controller.xml`) and push it

**Why:** The client machine runs the installed app. If we fix something locally and don't release it, the client is still on the old version and can't get the fix. Sparkle is the only delivery path.

**Firmware changes specifically:** Firmware is bundled inside the app at build time. A firmware fix requires an app release too — bump both the firmware version (`#define FIRMWARE_VERSION` in `main.c`) and the app version. The client then pushes firmware to boards via ⌘⇧U.

## Pending Work

- [ ] Bitfocus Companion module (skeleton in `companion-module/`)
- [ ] Production multi-camera testing
- [ ] Intel Mac testing
- [ ] Screenshots for README

## Debug Log

```bash
tail -f ~/Library/Logs/c200_debug.log
```

Log is cleared on each app launch.

## Security Notes

This tool is **local-network-only** (closed church WiFi + Ethernet). Known by-design posture:

- **HTTP not HTTPS**: Canon C200 local API doesn't support HTTPS. All traffic stays on isolated production network.
- **No authentication on ESP32 endpoints**: Intentional for local trusted environment. Anyone on the network can send commands.
- **Camera credentials hardcoded**: `admin:admin` (Canon default) in Camera.swift. Not persisted — change requires rebuild.
- **WiFi credentials in firmware**: Hardcoded in `main.c` during development; provisioned via ESP32Flasher tool for end-user units.
- **CORS wildcard** (`Access-Control-Allow-Origin: *`): Acceptable for local-only — not internet-exposed.

Before any public/shared release: move credentials to Keychain (camera) and NVS/provisioning (WiFi).

## Version

Current: `v1.0.6` (build 5)
CFBundleVersion: 5
MARKETING_VERSION: 1.0.6

