# C200 Controller — Project Context

## Project Summary

macOS app (SwiftUI) that controls Canon C200 cameras wirelessly via an ESP32-S3 hardware bridge. Production tool used at Northwoods Community Church for live broadcasts.

## Repo

`NorthwoodsCommunityChurch/avl-c200-controller` (private)

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

**Control endpoints (POST):**
- `/api/camera/iris/{plus|minus}`
- `/api/camera/iso/{plus|minus}`
- `/api/camera/shutter/{plus|minus}`
- `/api/camera/nd/{plus|minus}`
- `/api/camera/wb/{mode}` — e.g. `auto`, `tungsten`, `kelvin`
- `/api/camera/aes/{plus|minus}`
- `/api/camera/wbk/{plus|minus}`
- `/api/camera/rec` — toggle recording

**State endpoints (GET):**
- `/api/status` — ESP32 + camera connected/recording status
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
  "ssv": { "value": "180.00", "enabled": true }
}
```

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

## Pending Work

- [ ] Sparkle auto-updates (required before stable release)
- [ ] Bitfocus Companion module (skeleton in `companion-module/`)
- [ ] Production multi-camera testing
- [ ] Intel Mac testing
- [ ] Screenshots for README

## Debug Log

```bash
tail -f ~/Library/Logs/c200_debug.log
```

Log is cleared on each app launch.

## Version

Current: `v1.0.0-alpha` (build 1)
CFBundleVersion: 1
MARKETING_VERSION: 1.0.0
