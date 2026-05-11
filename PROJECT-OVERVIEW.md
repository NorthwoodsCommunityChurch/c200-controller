# C200 Controller — Complete Project Overview

> **Production camera control system for Northwoods Community Church live broadcasts.**
> macOS dashboard app + ESP32-S3 hardware bridge for wireless Canon C200 control.

---

## Table of Contents

1. [What This Does](#1-what-this-does)
2. [Hardware Overview](#2-hardware-overview)
3. [System Architecture](#3-system-architecture)
4. [Repository Structure](#4-repository-structure)
5. [macOS App — C200Controller](#5-macos-app--c200controller)
   - [Key Swift Files](#key-swift-files)
   - [UI Layout](#ui-layout)
   - [Connection Types](#connection-types)
   - [Camera Control](#camera-control)
   - [Preset System](#preset-system)
   - [Tally System (TSL)](#tally-system-tsl)
   - [Camera Positions Integration](#camera-positions-integration)
   - [Firmware Update (OTA)](#firmware-update-ota)
   - [Auto-Update (Sparkle)](#auto-update-sparkle)
6. [ESP32 Firmware](#6-esp32-firmware)
   - [Firmware Architecture](#firmware-architecture)
   - [REST API Reference](#rest-api-reference)
   - [WebSocket Push Format](#websocket-push-format)
   - [OLED Display](#oled-display)
   - [Tally LED Wiring](#tally-led-wiring)
   - [Network Configuration](#network-configuration)
7. [Build System](#7-build-system)
   - [Build the macOS App](#build-the-macos-app)
   - [Build and Flash Firmware](#build-and-flash-firmware)
8. [Release Process](#8-release-process)
9. [Canon C200 API Reference](#9-canon-c200-api-reference)
10. [TSL Tally Protocol](#10-tsl-tally-protocol)
11. [Data Persistence (UserDefaults)](#11-data-persistence-userdefaults)
12. [Security Posture](#12-security-posture)
13. [Version History](#13-version-history)
14. [Pending Work](#14-pending-work)
15. [Debug & Troubleshooting](#15-debug--troubleshooting)

---

## 1. What This Does

C200 Controller is a macOS app used at Northwoods Community Church to control Canon C200 cinema cameras during live video broadcasts. Operators can:

- Adjust aperture, ISO, shutter speed, ND filter, white balance, and AE shift on multiple cameras from a single dashboard
- Save and recall multi-camera setting presets with a single click
- See real-time tally light feedback from the video switcher (ATEM, etc.)
- Push firmware updates to ESP32 bridge boards over Wi-Fi
- View Camera Positions info (operator name, lens) per camera tile

The app communicates with cameras through ESP32-S3 hardware bridges that sit on the camera's isolated Ethernet subnet and relay commands over Wi-Fi.

---

## 2. Hardware Overview

### Canon C200

- Cinema camera used for broadcast
- Has a wired Ethernet port that exposes a REST API (Canon Browser Remote)
- API provides read/write access to ISO, aperture, shutter, ND, WB, AE shift, recording state
- **Critical setting:** Menu → ISO/Gain → Fine Increment must be **OFF**
  - Fine Increment ON: each command = 1/3 stop physically, but `av` value only updates every ~3 presses → dashboard overshoots by 3x
  - Fine Increment OFF: each command = 1 full stop in both physical value AND reported value

### ESP32-S3-ETH Bridge Board

- ESP32-S3 microcontroller with W5500 Ethernet chip
- 16 MB flash, PSRAM
- **Ethernet port** → static IP on the camera subnet (1.1.1.1) → connects to Canon C200 at 1.1.1.2
- **Wi-Fi** → DHCP on the production network → connects to macOS dashboard app
- RGB tally LEDs on GPIO 1 (red) and GPIO 2 (green) via 220Ω resistors
- OLED display (128×32, 4 rows) for status output
- Network credentials hardcoded at compile time; end-user units provisioned via ESP32Flasher GUI app

---

## 3. System Architecture

```
Canon C200                 ESP32-S3 Bridge               macOS Dashboard
(Ethernet API)    ←→      (WiFi + Ethernet)      ←→     C200Controller.app
1.1.1.2:80                WiFi: DHCP                     Auto-discovers via Bonjour

Video Switcher (ATEM)
      ↓ TSL UMD TCP port 5201
C200Controller.app → /api/tally/program → ESP32 RGB LED

Camera Positions App (HTTP)
      ↓ Poll every 10s
C200Controller.app → /api/display → ESP32 OLED

GitHub Releases (Sparkle)
      ↓ appcast XML
C200Controller.app auto-update
```

- **Camera control:** macOS app POSTs to `/api/camera/*` on ESP32 → ESP32 relays to Canon API → ESP32 broadcasts new state over WebSocket → app receives push update
- **State sync:** WebSocket push for near-real-time updates; HTTP poll fallback for direct-connection cameras
- **Tally:** TSL TCP packets from switcher → parsed by app → REST calls to ESP32 → PWM LEDs on GPIO 1/2
- **Discovery:** ESP32 boards advertise via mDNS (`_http._tcp`); app listens via Bonjour and auto-adds new cameras

---

## 4. Repository Structure

```
ESP32 Canon C200/
├── C200Controller/                  macOS SwiftUI app
│   ├── Sources/                     14 Swift source files
│   ├── Resources/Assets.xcassets/   App icon asset catalog
│   ├── Package.swift                SPM manifest (Sparkle dependency)
│   └── build.sh                     Full build, bundle, sign, and open script
│
├── ESP32Flasher/
│   ├── FirmwareTemplate/            ESP32 firmware project
│   │   ├── main/main.c              98 KB firmware source (all logic)
│   │   ├── CMakeLists.txt
│   │   ├── sdkconfig                ESP-IDF config
│   │   └── build/                   CMake build output
│   ├── ESP-32 Flasher/              Xcode project for GUI flasher app (end-user tool)
│   └── test_esp32.sh
│
├── Icons/
│   ├── AppIcon.icns                 App icon (dark navy squircle, cinema camera)
│   └── PhotoIngest-1024.png
│
├── companion-module/                Bitfocus Companion module (skeleton, not complete)
│   ├── package.json
│   └── index.js
│
├── docs/
│   ├── PRD.md
│   └── images/
│
├── CLAUDE.md                        Project context for Claude Code (checked in)
├── SECURITY.md                      Security review findings
├── CANON_C200_API.md                Canon Browser Remote API reference
├── BUILD.md
├── README.md
├── test_tsl.py                      Python TSL protocol test script
├── test_esp32_tally.sh              Bash ESP32 tally REST test
├── Open Claude.command              Double-click launcher for Claude Code session
└── start-claude-team.sh             Agent team tmux startup script
```

---

## 5. macOS App — C200Controller

### Key Swift Files

| File | Purpose |
|------|---------|
| [C200ControllerApp.swift](C200Controller/Sources/C200ControllerApp.swift) | App entry point — Sparkle updater init, window setup, menu commands (Tally ⌘⇧T, Firmware ⌘⇧U, Positions ⌘⇧P) |
| [Camera.swift](C200Controller/Sources/Camera.swift) | `CameraState` — per-camera connection, polling, WebSocket, all control commands, preset recall |
| [CameraManager.swift](C200Controller/Sources/CameraManager.swift) | Multi-camera list, Bonjour discovery, persistence, TSL tally propagation |
| [ContentView.swift](C200Controller/Sources/ContentView.swift) | Main UI — header bar, camera tile grid, preset sidebar, all sheet presentations |
| [PresetsPanel.swift](C200Controller/Sources/PresetsPanel.swift) | Left sidebar — preset list, add/edit/recall/delete UI, auto-reconnect toggle |
| [Preset.swift](C200Controller/Sources/Preset.swift) | Data models: `CameraPreset`, `PresetSettings`, `CameraSettings`, `PresetSettingType` |
| [PresetManager.swift](C200Controller/Sources/PresetManager.swift) | Preset CRUD, UserDefaults persistence, edit mode, capture/toggle logic |
| [TSLClient.swift](C200Controller/Sources/TSLClient.swift) | TCP listener for TSL UMD 3.1 + 5.0 protocols, packet parsing, state callbacks |
| [TallySettingsView.swift](C200Controller/Sources/TallySettingsView.swift) | TSL settings UI — port, LED brightness, per-camera index assignment |
| [FirmwareUpdateManager.swift](C200Controller/Sources/FirmwareUpdateManager.swift) | OTA firmware detection, per-board status, HTTP delivery server |
| [FirmwareUpdateView.swift](C200Controller/Sources/FirmwareUpdateView.swift) | Firmware update UI — board selection, progress (downloading, flashing, rebooting, done/error) |
| [CameraPositionsClient.swift](C200Controller/Sources/CameraPositionsClient.swift) | HTTP polling client for Camera Positions app (10-second interval) |
| [CameraPositionsSettingsView.swift](C200Controller/Sources/CameraPositionsSettingsView.swift) | Camera Positions settings UI — host, port, enable/disable |
| [Logger.swift](C200Controller/Sources/Logger.swift) | File logger → `~/Library/Logs/c200_debug.log`, cleared on each launch |

### UI Layout

```
┌─────────────────────────────────────────────────────────────┐
│ Header: TSL indicator (gray/yellow/green)  Connected  Rec   │
├──────────┬──────────────────────────────────────────────────┤
│ Presets  │  Camera Tile 1    Camera Tile 2    Camera Tile 3  │
│ Sidebar  │  ┌────────────┐   ┌────────────┐                 │
│          │  │ CAM NAME   │   │ CAM NAME   │                 │
│ [+] Add  │  │ F2.8       │   │ F4.0       │                 │
│          │  │ ISO 800    │   │ ISO 400    │                 │
│ Preset 1 │  │ 1/180      │   │ 1/90       │                 │
│ Preset 2 │  │ ND OFF     │   │ ND 2       │                 │
│          │  │ WB 5600K   │   │ Auto WB    │                 │
│          │  │ AE +0.0    │   │ AE +0.0    │                 │
│          │  └────────────┘   └────────────┘                 │
│ Auto-    │                                                   │
│ Reconnect│                                                   │
└──────────┴──────────────────────────────────────────────────┘
```

Each camera tile has a **front** (settings display) and **back** (OLED preview showing operator name, lens) toggled by clicking. A tally light indicator on the tile front shows PGM (red) or PVW (green).

### Connection Types

```swift
enum ConnectionType: String, Codable {
    case esp32   // Via ESP32-S3 bridge — WebSocket push + REST control
    case direct  // Canon Browser Remote directly — HTTP poll only
}
```

**ESP32 mode** (normal production use):
- REST POST commands to ESP32 → ESP32 relays to Canon
- WebSocket (`/ws`) receives push state updates in real time
- After each command: 300ms wait then adaptive poll (50ms intervals, exit early when WS delivers new value)
- Ping timer every 5s detects zombie WebSocket connections

**Direct mode** (fallback — reduced functionality):
- REST POST directly to Canon Browser Remote
- HTTP poll for state (no push updates)
- No tally LED control

### Camera Control

All control calls are REST POST to ESP32:

| Action | Endpoint | Notes |
|--------|----------|-------|
| Iris open | `POST /api/camera/iris/plus` | 1 stop per call |
| Iris close | `POST /api/camera/iris/minus` | 1 stop per call |
| ISO up | `POST /api/camera/iso/plus` | |
| ISO down | `POST /api/camera/iso/minus` | |
| Shutter faster | `POST /api/camera/shutter/plus` | |
| Shutter slower | `POST /api/camera/shutter/minus` | |
| ND in | `POST /api/camera/nd/plus` | |
| ND out | `POST /api/camera/nd/minus` | |
| WB mode | `POST /api/camera/wb/{mode}` | `auto`, `tungsten`, `kelvin` |
| AE shift up | `POST /api/camera/aes/plus` | |
| AE shift down | `POST /api/camera/aes/minus` | |
| WB Kelvin up | `POST /api/camera/wbk/plus` | |
| WB Kelvin down | `POST /api/camera/wbk/minus` | |
| Toggle recording | `POST /api/camera/rec` | |

#### Canon C200 Property Keys

| Dashboard Label | ESP32/Canon JSON Key | Example Value |
|-----------------|----------------------|---------------|
| Aperture | `av` | `"F2.8"` |
| ISO | `gcv` | `"800"` |
| Shutter | `ssv` | `"180.00"` |
| ND Filter | `ndv` | varies |
| WB Mode | `wbm` | `"auto"`, `"tungsten"`, `"kelvin"` |
| WB Kelvin | `wbvk` | `"5600K"` |
| AE Shift | `aesv` | `"+0.5"` |

### Preset System

Presets save a snapshot of camera settings (one or more cameras, one or more properties) and recall them with a single click.

**Data model:**
```
CameraPreset
  ├── id: UUID
  ├── name: String
  ├── createdAt: Date
  └── settings: PresetSettings
        └── [cameraID: CameraSettings]
              └── aperture, iso, shutter, ndFilter,
                  wbMode, wbKelvin, aeShift  (all Optional)
```

**Recall flow (`applyPreset()` in Camera.swift):**
1. `fetchESP32CameraState()` — one HTTP GET for current values
2. For each included property: call `adjustToValue(target:control:inverted:)`
3. `adjustToValue` sends step commands (+/−) until `currentValue == targetValue`
4. After each step command: adaptive poll
   - Wait 300ms (camera processing time)
   - Poll every 50ms; exit early when WebSocket delivers new value
   - Timeout: 3000ms for iris, 1500ms for other properties
5. Properties are adjusted **sequentially** (not in parallel) because `CameraState` is `@MainActor`

**Settings are persisted** in UserDefaults under key `camera_presets_v1`.

### Tally System (TSL)

**Architecture changed in v1.2.0.** Each ESP32 board now listens directly to the switcher's TSL feed and drives its own LED. The dashboard is no longer in the tally critical path — it pushes configuration to boards over WebSocket and listens to TSL itself only to render the on-screen tile indicators.

#### Architecture

```
Ross Ultrix Carbonite
  │ TSL UMD TCP packets → port 5200, one output per destination
  ├─→ ESP32 board 1  ─┐
  ├─→ ESP32 board 2   │  each board parses, filters by its
  ├─→ ESP32 board 3   │  configured tsl_index, applies LED
  ├─→ ESP32 board 4   │  (program/preview/off via LEDC PWM)
  ├─→ ESP32 board 5  ─┘
  └─→ C200Controller.app  (tile UI rendering + config push)
                        │
                        └─→ ESP32 /ws  {"type":"tsl_config","index":N,"port":P,"swap":B}
```

If the Mac is offline mid-service, the LEDs keep working. If a board reboots, the dashboard re-pushes its TSL config on the next WS handshake — self-healing.

#### TSL Protocol Support

- **TSL UMD 3.1** — 18-byte fixed format, most common
- **TSL UMD 5.0** — variable length, newer format
- **TCP** on port 5200 by default (matches the Ross Ultrix Carbonite at Northwoods); configurable in Tally Settings (⌘⇧T)
- Automatic protocol detection based on packet structure
- Implemented in C in `ESP32Flasher/FirmwareTemplate/main/main.c` (`tsl_parse_one`, `tsl_apply_state`, `tsl_listener_task`) and in Swift in `C200Controller/Sources/TSLClient.swift`

#### Camera Assignment

Each camera has exactly one TSL index (1–127, or 0 = unassigned). Configured via single-select popover in Tally Settings (⌘⇧T) or on each camera tile. v1.2.1 removed multi-index assignment — the firmware never supported it.

The dashboard sends `{"type":"tsl_config","index":N,"port":P,"swap":B}` over the existing `/ws` WebSocket; the board persists to NVS (`tally_cfg` namespace) and immediately restarts its TSL listener with the new settings.

#### Switcher Configuration

The Ross Ultrix Carbonite (or any TSL-emitting switcher) must be configured with one TSL output per board IP, plus one for the dashboard itself. At Northwoods that's six destinations total — five boards + director Mac (`10.11.1.104`) — all on port 5200.

See [docs/ESP32-INVENTORY.md](docs/ESP32-INVENTORY.md) for the current board IPs and MACs.

#### State Logic

Both the firmware and the dashboard apply **program-wins** resolution: if T1 (program) is set, the LED is red regardless of T2 (preview). This handles Ross's PGM packet which sets T1+T2 because Ross considers "currently visible" to include preview.

**150 ms OFF debounce.** Ross emits a transient OFF packet between a camera leaving PGM and the auto-PVW that follows the next cut. Without debouncing, the LED visibly flickers dark during fast cut sequences. The firmware and the dashboard both defer OFF by 150 ms; if a new active state arrives within that window, the pending OFF is cancelled.

#### LED Brightness

Global brightness slider (1–100%) in Tally Settings maps to PWM value 0–255. Set via `/api/tally/brightness/{value}` and persisted in UserDefaults (`tally_brightness`). Brightness is re-sent on every WS reconnect so a board that just rebooted comes back at the correct intensity.

#### TSL Status Indicator (Header Bar)

| Color | Meaning |
|-------|---------|
| Gray | TSL disabled |
| Yellow | Listening — port bound, no switcher connected yet |
| Green | Switcher connected and sending data |

### Camera Positions Integration

The app polls a companion Camera Positions app (separate project) over HTTP every 10 seconds to get camera assignment info. When a camera number is set:

- Operator name and lens name are shown on the camera tile back (OLED preview)
- Data is also sent via `POST /api/display` to the ESP32 for the physical OLED

Configured in Camera Positions Settings (⌘⇧P): host IP, port (default 8765), enable/disable toggle, per-camera assignment.

### Firmware Update (OTA)

The macOS app includes a bundled firmware binary (`c200_bridge.bin`) embedded at build time. Users can push it to connected ESP32 boards via Wi-Fi (no USB cable required in the field).

**Flow:**
1. Open Firmware Update (⌘⇧U)
2. App shows discovered boards + current firmware version per board
3. Check boxes select which boards to update (all selected by default)
4. Progress per board: Downloading → Flashing → Rebooting → Done / Error
5. App serves firmware via temporary HTTP server; ESP32 fetches and self-installs via `/api/ota/update`

Firmware version is reported in `/api/status` as `firmware_version`.

### Auto-Update (Sparkle)

The app uses Sparkle 2 for macOS auto-updates delivered via GitHub Pages.

| Setting | Value |
|---------|-------|
| Appcast URL | `https://northwoodscommunitychurch.github.io/app-updates/appcast-c200controller.xml` |
| Public key | EdDSA, embedded in `Info.plist` as `SUPublicEDKey` |
| Auto-check | Enabled on launch |

**Versioning convention:**
- `CFBundleVersion` (build number) — simple incrementing integers: 1, 2, 3 ... Used by Sparkle for version comparison via `sparkle:version`
- `MARKETING_VERSION` — semantic version displayed to users: 1.0.x
- Both fields must be updated together on each release

---

## 6. ESP32 Firmware

### Firmware Architecture

**Source:** [ESP32Flasher/FirmwareTemplate/main/main.c](ESP32Flasher/FirmwareTemplate/main/main.c) (~98 KB, ~3,000 lines)

The firmware runs on the ESP32-S3 and manages:
- Dual-stack networking (WiFi + Ethernet) with infinite reconnect and 30 s self-reboot if WiFi is down while Ethernet is up
- WiFi modem-sleep disabled (`WIFI_PS_NONE`) for stable RTT under contended 2.4 GHz
- HTTP/REST API server for camera control (relay to Canon)
- WebSocket server for push state updates to dashboard + inbound `tsl_config` messages
- **TSL UMD listener** on a configurable TCP port (default 5200) — filters by board's configured tally index, applies program-wins + 150 ms OFF debounce, drives LED
- NVS-persisted tally config (`tally_cfg` namespace: index, port, swap)
- OLED display (SSD1306, 128×32)
- OTA firmware update reception
- mDNS advertisement for Bonjour discovery

**Key compile-time constants:**

| Constant | Value | Notes |
|----------|-------|-------|
| `FIRMWARE_VERSION` | `"1.2.0"` | Reported in `/api/status` |
| `WIFI_SSID` | `"Northwoods - Production"` | |
| `WIFI_PASSWORD` | `"Ah7eFLoJ"` | |
| `CAMERA_IP` | `"1.1.1.2"` | Canon C200 Ethernet IP |
| `ETH_STATIC_IP` | `"1.1.1.1"` | ESP32 Ethernet IP |
| `CAMERA_NUMBER` | `0` | 0 = unset, 1–5 for Camera Positions |
| `CAMERA_USER` | `"admin"` | Canon Browser Remote credentials |
| `CAMERA_PASS` | `"admin"` | Canon default |

### REST API Reference

#### Camera Control (POST)

| Endpoint | Action |
|----------|--------|
| `/api/camera/iris/plus` | Open aperture 1 stop |
| `/api/camera/iris/minus` | Close aperture 1 stop |
| `/api/camera/iso/plus` | Increase ISO 1 stop |
| `/api/camera/iso/minus` | Decrease ISO 1 stop |
| `/api/camera/shutter/plus` | Faster shutter |
| `/api/camera/shutter/minus` | Slower shutter |
| `/api/camera/nd/plus` | ND filter in |
| `/api/camera/nd/minus` | ND filter out |
| `/api/camera/wb/{mode}` | Set WB mode: `auto`, `tungsten`, `kelvin` |
| `/api/camera/aes/plus` | AE shift + |
| `/api/camera/aes/minus` | AE shift − |
| `/api/camera/wbk/plus` | WB Kelvin up |
| `/api/camera/wbk/minus` | WB Kelvin down |
| `/api/camera/rec` | Toggle recording |

#### State (GET)

| Endpoint | Returns |
|----------|---------|
| `/api/status` | ESP32 + camera connection status, `firmware_version`, `camera_number` |
| `/api/camera/state` | Full camera settings JSON |
| `/ws` | WebSocket endpoint for push updates |

#### Tally Control (POST)

**Important:** `/api/tally/brightness/*` must be registered BEFORE `/api/tally/*` in the HTTP server. ESP-IDF uses first-match routing for wildcards — registering the general wildcard first will intercept brightness requests.

| Endpoint | Action |
|----------|--------|
| `/api/tally/brightness/{0-255}` | Set LED PWM brightness |
| `/api/tally/program` | Red LED on at current brightness |
| `/api/tally/preview` | Green LED on at current brightness |
| `/api/tally/both` | Both LEDs on (amber) |
| `/api/tally/off` | Both LEDs off |

#### Display (POST)

| Endpoint | Body | Action |
|----------|------|--------|
| `/api/display` | `{"operator": "Name", "lens": "Lens"}` | Update OLED rows 1–2 |

#### OTA Firmware (POST/GET)

| Endpoint | Action |
|----------|--------|
| `/api/ota/update` | POST — begin OTA download from URL in body |
| `/api/ota/status` | GET — current OTA status |

### WebSocket Push Format

Sent from ESP32 to all connected clients on any state change:

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
  "ndv": { "value": "OFF", "enabled": true },
  "wbm": { "value": "kelvin", "enabled": true },
  "wbvk": { "value": "5600K", "enabled": true },
  "aesv": { "value": "+0.0", "enabled": true },
  "tally": "off",
  "firmware_version": "1.0.14"
}
```

**`tally` field values:** `"off"`, `"program"`, `"preview"`, `"both"`

#### Post-Command ESP32 Polling Flow

When the ESP32 receives a camera command:
1. Sets `poll_state_now = true` and `poll_property_hint = "av"` (or appropriate key)
2. Main poll loop sees flag → waits 150ms → polls single property via Canon API
3. Broadcasts new value over WebSocket immediately
4. Waits 500ms, then resumes normal polling cycle

### OLED Display

128×32 pixel display, 4 text rows (using SSD1306 driver):

| Row | When `CAMERA_NUMBER > 0` | When `CAMERA_NUMBER == 0` |
|-----|--------------------------|---------------------------|
| 0 | `CAM N  Tally: PRG` | `WiFi:OK  Eth:OK` |
| 1 | Operator name (from `/api/display`) | Operator name |
| 2 | Lens name (from `/api/display`) | Lens name |
| 3 | `Cam:OK  Rec:LIVE` | `Cam:OK  Rec:LIVE` |

### Tally LED Wiring

```
ESP32 GPIO 1 → 220Ω resistor → Red LED → GND    (Program)
ESP32 GPIO 2 → 220Ω resistor → Green LED → GND  (Preview)
```

- LEDC timer 0, channels 0 (red) and 1 (green)
- 8-bit resolution (0–255), 1000 Hz frequency
- **Tally watchdog (v1.1.0+):** 8 s no-command threshold is logged only — the LED is no longer touched. The earlier amber-on-watchdog behavior was actively misleading on degraded WiFi and was removed.

### Network Configuration

**WiFi:**
- SSID/password hardcoded in `main.c` at compile time
- Connects via DHCP to production network
- mDNS name advertised for Bonjour discovery

**Ethernet:**
- Static IP: `1.1.1.1` / mask `255.255.255.0` / gateway `1.1.1.2`
- Connects directly to Canon C200 at `1.1.1.2`
- Isolated subnet — not routed to production network

**End-user provisioning:** The ESP32Flasher GUI app (separate Xcode project) allows setting WiFi SSID/password, camera IP, and ESP32 static IP via a UI before flashing. Used for end-user boards; not used in development.

---

## 7. Build System

### Build the macOS App

```bash
cd C200Controller && bash build.sh
```

This script:
1. Runs `swift build -c release` (SPM)
2. Creates `.app` bundle structure under a temp directory
3. Copies executable, `AppIcon.icns`, and Sparkle framework
4. Generates `Info.plist` with all required keys (version, Bundle ID, Sparkle keys, Bonjour services)
5. Bundles `c200_bridge.bin` firmware binary from `FirmwareTemplate/build/`
6. Signs Sparkle nested components inside-out (XPC services → Updater.app → framework → app)
7. Ad-hoc signs the complete bundle (`codesign --force --deep --sign -`)
8. Moves app to `~/Applications/` (or configured output path)
9. Auto-opens the newly built app

**SPM dependency:** Sparkle ≥2.0.0 — downloaded to `.build/artifacts/sparkle/`

**Important:** `bash build.sh` does NOT recompile the ESP32 firmware. If firmware was changed, run `idf.py build` first.

### Build and Flash Firmware

ESP-IDF must be installed at `~/esp/esp-idf/`.

```bash
# Navigate to firmware project
cd "ESP32Flasher/FirmwareTemplate"

# Source ESP-IDF environment
source ~/esp/esp-idf/export.sh 2>/dev/null

# Build firmware
idf.py build

# Find serial port (ESP32 must be connected via USB)
ls /dev/cu.*
# Usually /dev/cu.usbmodem2101

# Flash to board
idf.py -p /dev/cu.usbmodem2101 flash

# Monitor serial output (Ctrl+] to exit)
idf.py -p /dev/cu.usbmodem2101 monitor
```

**After firmware changes:** Increment `FIRMWARE_VERSION` in `main.c` and rebuild the macOS app (which bundles the new firmware binary) for a release.

**Full clean build:**
```bash
idf.py fullclean && idf.py build
```

---

## 8. Release Process

Every change — whether app code or firmware — must go through a full release so clients can receive it via Sparkle OTA.

### Steps

1. **Bump version** — ask user first. Usually patch (1.0.x). Update in `build.sh`:
   - `APP_VERSION="1.0.X"`
   - `BUILD_NUMBER=N` (increment by 1)
   - If firmware changed: also increment `FIRMWARE_VERSION` in `main.c`

2. **Build firmware** (if firmware changed):
   ```bash
   cd ESP32Flasher/FirmwareTemplate
   source ~/esp/esp-idf/export.sh 2>/dev/null
   idf.py build
   ```

3. **Build app:**
   ```bash
   cd C200Controller && bash build.sh
   ```

4. **Create signed zip:**
   ```bash
   cd ~/Applications
   zip -r --symlinks C200Controller-v1.0.X.zip C200Controller.app
   ```

5. **Create GitHub release** with the zip attached

6. **Sign the zip** (sign what users will download, not the local copy):
   ```bash
   # Download the zip from GitHub releases first, then:
   sign_update C200Controller-v1.0.X.zip
   # Copy the signature output
   ```
   > **Warning:** EdDSA signing is randomized — signing twice produces different (but both valid) signatures. Always sign the file users will download, not a local copy.

7. **Update appcast** (`app-updates/appcast-c200controller.xml`):
   ```xml
   <item>
     <title>Version 1.0.X</title>
     <sparkle:version>N</sparkle:version>
     <sparkle:shortVersionString>1.0.X</sparkle:shortVersionString>
     <enclosure url="https://github.com/.../releases/download/v1.0.X/C200Controller-v1.0.X.zip"
                sparkle:edSignature="THE_SIGNATURE_FROM_STEP_6"
                length="FILE_SIZE_IN_BYTES"
                type="application/octet-stream" />
   </item>
   ```

8. **Push** appcast to GitHub (served via GitHub Pages)

### Versioning Fields

| Field | Example | Where |
|-------|---------|-------|
| `APP_VERSION` in build.sh | `"1.0.28"` | Shown to users, `CFBundleShortVersionString` |
| `BUILD_NUMBER` in build.sh | `27` | Used by Sparkle for comparisons, `CFBundleVersion` |
| `sparkle:version` in appcast | `"27"` | Must match `CFBundleVersion` exactly |
| `sparkle:shortVersionString` | `"1.0.28"` | Displayed in update dialog |

> **Sparkle trap:** If appcast `sparkle:version="1.0.28"` but app's `CFBundleVersion` is `27`, Sparkle sees "1.0.28 > 27" and keeps offering updates forever. Always use incrementing integers for build numbers.

---

## 9. Canon C200 API Reference

The Canon Browser Remote API is HTTP-based, local network only, no HTTPS.

- Base URL: `http://1.1.1.2` (camera Ethernet IP)
- Authentication: HTTP Basic `admin:admin` (Canon defaults)
- Content-Type: `application/json`

### Get Camera State

```
GET /ccapi/ver100/shooting/settings/
```

Returns JSON with all shooting settings. Key properties:

| Key | Type | Example |
|-----|------|---------|
| `av` | string | `"F2.8"` |
| `gcv` | string | `"800"` |
| `ssv` | string | `"180.00"` |
| `ndv` | string | varies |
| `wbm` | string | `"auto"`, `"tungsten"`, `"kelvin"` |
| `wbvk` | string | `"5600K"` |
| `aesv` | string | `"+0.5"` |

### Set Camera Property

```
POST /ccapi/ver100/shooting/settings/{property}
Body: {"value": "F4.0"}
```

### Recording Control

```
POST /ccapi/ver100/shooting/control/movierecording
Body: {"action": "start"} or {"action": "stop"}
```

See [CANON_C200_API.md](CANON_C200_API.md) for the full reference.

---

## 10. TSL Tally Protocol

TSL UMD (Under Monitor Display) is a broadcast industry standard for tally light control.

### TSL UMD 3.1 (18-byte fixed)

```
Byte 0:    0x80 | address (1-based)
Bytes 1-16: display text (fixed 16 chars)
Byte 17:   control byte
  bit 6: RH tally (preview/green)
  bit 7: LH tally (program/red)
```

### TSL UMD 5.0 (variable length)

Variable-length packets with header + payload. Supports more addresses and metadata.

### Testing

**Python test (automated + interactive):**
```bash
python3 test_tsl.py                  # automated sequence
python3 test_tsl.py --interactive    # manual testing
```

**Bash ESP32 direct test:**
```bash
bash test_esp32_tally.sh             # direct REST API test
```

---

## 11. Data Persistence (UserDefaults)

| Key | Type | Purpose |
|-----|------|---------|
| `known_cameras_v2` | Data (JSON) | Persisted camera list |
| `auto_reconnect_enabled` | Bool | Auto-reconnect toggle state |
| `camera_presets_v1` | Data (JSON) | Presets array |
| `tsl_enabled` | Bool | TSL system enable state |
| `tsl_port` | Int | TSL TCP port (default: 5201) |
| `tally_brightness` | Int | LED brightness 0–255 (default: ~3 for 1%) |
| `positions_enabled` | Bool | Camera Positions enable state |
| `positions_host` | String | Camera Positions host/IP |
| `positions_port` | Int | Camera Positions port (default: 8765) |

---

## 12. Security Posture

This tool is **local-network-only** on a closed church production Wi-Fi and Ethernet network.

| Item | Status | Notes |
|------|--------|-------|
| HTTP (not HTTPS) | By design | Canon C200 API doesn't support HTTPS |
| No auth on ESP32 | By design | Trusted local network only |
| Camera credentials hardcoded | Known risk | `admin:admin` Canon defaults; change requires rebuild |
| WiFi credentials in firmware | Known risk | Hardcoded for dev; provisioned via flasher for end-user |
| CORS wildcard | By design | Not internet-exposed |

**Before any public/shared release:**
- Move camera credentials to Keychain
- Move WiFi credentials to NVS/provisioning flow
- Add authentication to ESP32 endpoints

See [SECURITY.md](SECURITY.md) for full security review.

---

## 13. Version History

| Version | Build | Changes |
|---------|-------|---------|
| 1.2.1 | 40 | Single-index UI — collapsed tslIndices array to tslIndex Int (firmware unchanged) |
| 1.2.0 | 39 | **Phase 2:** boards listen to TSL directly; dashboard out of tally critical path. New firmware TSL listener task, NVS-backed config, WS tsl_config push, single-board self-healing on reconnect. Firmware **1.2.0**. |
| 1.1.0 | 38 | **Phase 1:** firmware reconnect-forever (MAX_RETRY removed), modem-sleep off, watchdog stops forcing amber. Dashboard cancel-on-state-change only, 1.0 s timeout w/ retry, default TSL port 5200. Firmware **1.1.0**. |
| 1.0.37 | 36 | Ross transient-OFF 150 ms debounce in dashboard; tally fix for fast cut sequences |
| 1.0.36 | 35 | Swap Program/Preview toggle (Ross/Roland T1/T2 inversion) |
| 1.0.28 | 27 | Fix app icon white border |
| 1.0.27 | 26 | Update app icon (cinema camera, dark navy squircle) |
| 1.0.26 | 25 | Fix stale "Camera Online" after WebSocket disconnect |
| 1.0.25 | 24 | WiFi robustness: WS ping/keepalive, tally task cancel, TSL buffer resync |
| 1.0.24 | 23 | Firmware Update board selection checkboxes (all selected by default) |
| 1.0.23 | 22 | Firmware 1.0.14: tally dead-man switch (ESP32 clears LEDs after 8s) |
| 1.0.22 | 21 | Tally WiFi reliability: retry 3× on failure; periodic re-send every 2.5s |
| 1.0.21 | 20 | Fixed tally flash (ESP32 WS feedback only); fixed tile size shift |
| 1.0.20 | 19 | Tally: brightness sent before tally command to prevent 100% flash |
| 1.0.19 | 18 | OLED preview on tile back; positions strip removed from tile front |
| 1.0.18 | 17 | Fixed camera tiles overlapping (removed hardcoded frame height) |
| 1.0.17 | 16 | clearAllTally() on TSL switcher disconnect; default brightness 1% |
| 1.0.16 | 15 | FrontTallyLight (PGM/PVW) on tile front only |
| 1.0.15 | 14 | Glowing TallyLED dome on tile back; stale isRecording fix |

**Firmware version:** 1.2.0 (TSL listener, NVS config, no false-amber watchdog)

---

## 14. Pending Work

- [ ] **Deploy v1.2.x to production** — director Mac updates via Sparkle; flash firmware 1.2.0 to all 5 boards via ⌘⇧U; configure Ross Ultrix with one TSL output per board IP + director on port 5200
- [ ] **Cam 4 hardware check** — confirm external antenna jumper rework (see memory `external_antenna_jumper.md`) as defense in depth; firmware no longer gives up on reconnect, but RF hygiene still matters
- [ ] **Validate first production service with phase 2 architecture** — confirm dashboard's `kind=tally` HTTP traffic goes quiet and LEDs track Ross correctly
- [ ] **Camera.swift decoder cleanup (~2026-05-25)** — remove the legacy `tslIndices` migration branch once every install has launched v1.2.1 (see memory `decoder_cleanup_future.md`)
- [ ] **Bitfocus Companion module** — skeleton exists in `companion-module/`; needs full implementation
- [ ] **Intel Mac testing** — verify build and run on Intel architecture
- [ ] **README screenshots** — capture and add to `docs/images/`
- [ ] **Battery percentage display** — researched (ADC voltage divider or IP5306 I2C UPS board); not yet implemented

---

## 15. Debug & Troubleshooting

### App Debug Log

```bash
tail -f ~/Library/Logs/c200_debug.log
```

Log is cleared on each app launch.

### ESP32 Serial Monitor

```bash
idf.py -p /dev/cu.usbmodem2101 monitor
```

Use `Ctrl+]` to exit. Shows camera HTTP responses, WebSocket activity, tally commands, OTA progress.

### Common Issues

**Camera shows "Offline" after reconnect:**
- Check that `isConnected` is cleared on WebSocket failure (not just on explicit disconnect)
- Verify ping timer is running (`startWSPingTimer()` called in `startWebSocket()`)

**Tally LEDs flash to 100% on ESP32 reboot:**
- Brightness must be sent before tally state; confirm `sendBrightness()` is called on connect

**Preset recall overshoots:**
- Confirm Canon C200 Menu → ISO/Gain → Fine Increment is **OFF**
- With Fine Increment ON, the reported `av` value only updates every ~3 button presses

**Sparkle keeps offering updates after install:**
- Check that `sparkle:version` in appcast matches `CFBundleVersion` (not marketing version)
- Use incrementing integers for build numbers, not semantic versions

**App won't open on a new Mac:**
1. Move app to `/Applications`
2. Try to open (macOS blocks it)
3. System Settings → Privacy & Security → "Open Anyway"

### Finding ESP32 Serial Port

```bash
ls /dev/cu.*
# Connect ESP32 via USB, run again — new entry is the ESP32
# Usually /dev/cu.usbmodem2101
```

### Testing Tally Without a Switcher

```bash
# Python script — automated TSL test sequence
python3 test_tsl.py

# Python script — manual interactive mode
python3 test_tsl.py --interactive

# Bash — direct REST calls to ESP32
bash test_esp32_tally.sh
```

---

*Last updated: 2026-05-11*
*Repository: NorthwoodsCommunityChurch/c200-controller*
