# PRD: Wireless Canon C200 Camera Controller

**Status:** Alpha (v1.0.0-alpha)
**Last updated:** 2026-02-12

---

## Problem Statement

Camera operators at Northwoods Community Church need to remotely adjust Canon C200 camera settings during live broadcasts without physically accessing the cameras. Currently, exposure changes require an operator to walk to the camera, interrupting the production and potentially disrupting the shot.

---

## Solution Overview

A three-part system:

1. **ESP32-S3 Hardware Bridge** — A small board with both Ethernet (wired to the camera) and WiFi. Bridges the camera's Browser Remote HTTP API to the production WiFi network and pushes state changes via WebSocket.

2. **C200 Controller macOS App** — Dashboard displaying all connected cameras with live status. Operators can adjust settings via buttons or recall saved presets.

3. **Bitfocus Companion Module** *(future)* — Integration with the production control panel (Bitfocus Companion) so presets can be triggered from physical buttons.

---

## Architecture

```
Canon C200 Camera
  (Browser Remote API, HTTP on Ethernet port)
        │
        └── Ethernet ──→  ESP32-S3 Bridge
                                 │
                         WiFi network (LAN)
                                 │
                    ┌────────────┴────────────┐
                    │                         │
             C200 Controller            Bitfocus Companion
             (macOS dashboard)          (future - physical buttons)
```

### ESP32 Bridge Responsibilities

- Connects to Canon C200 via Ethernet (static IP)
- Logs in to Browser Remote API on startup
- Polls camera state every 500ms (recording state) / on-demand (settings)
- After a control command: immediate single-property re-poll → WebSocket broadcast
- Exposes REST API on WiFi for the dashboard to send commands
- Exposes WebSocket (`/ws`) for real-time push updates to dashboard
- Advertises itself via mDNS (`_http._tcp`) for Bonjour auto-discovery

### Dashboard Responsibilities

- Discovers ESP32 bridges via Bonjour, auto-adds to camera list
- Maintains a persistent camera list (UserDefaults)
- Opens WebSocket connection to each bridge for live state
- Sends REST commands to the bridge (`POST /api/camera/{control}/{direction}`)
- Manages presets: saves current camera settings, recalls by sending step-by-step commands

---

## Feature Status

### Implemented and Tested

| Feature | Notes |
|---------|-------|
| ESP32 firmware (C, ESP-IDF) | Running on ESP32-S3-ETH board |
| WebSocket push updates | ~4s polling cycle |
| Record toggle | Start/stop with visual feedback |
| Iris control | Single step per command (fine increment OFF required) |
| ISO control | Single step per command |
| Shutter control | Single step per command |
| ND filter control | Single step per command |
| White balance mode | Set mode directly |
| AE shift control | Single step per command |
| WB Kelvin control | Single step per command |
| Multi-camera dashboard | Grid of camera tiles |
| Bonjour auto-discovery | Requires `_http._tcp` mDNS |
| Manual ESP32 IP entry | Fallback when Bonjour fails |
| Camera presets | Save/recall exposure settings |
| Auto-reconnect | 10s retry on connection loss |
| Card flip UI | Front = controls, back = settings |
| Camera rename | Persisted to UserDefaults |
| Camera remove | Disconnect + remove from list |
| Debug logging | `~/Library/Logs/c200_debug.log` |

### Implemented but Untested in Production

| Feature | Risk |
|---------|------|
| Multi-camera simultaneous preset recall | Each camera recalls independently; no synchronization |
| Direct camera connection mode | Limited testing, different code path |
| Bonjour on production WiFi | Depends on network supporting mDNS multicast |

### Not Yet Implemented

| Feature | Priority | Notes |
|---------|----------|-------|
| Bitfocus Companion module | High | Skeleton exists in `companion-module/` |
| Sparkle auto-updates | Required | Planned for stable release (org requirement) |
| Preset export/import | Low | Would enable sharing presets across Macs |
| Camera connection status indicator | Medium | Currently shows tile state, not connection quality |
| Firmware version display | Low | ESP32 could report build version |
| Multi-camera preset sync timing | Low | All cameras start simultaneously but mechanical differences |

---

## Technical Requirements

### macOS App

- macOS 13.0+ (Ventura)
- Apple Silicon (primary target); Intel untested
- Swift 5.9+, SwiftUI
- No external Swift dependencies (pure Foundation + SwiftUI + Network.framework)
- Local network permission required (NSLocalNetworkUsageDescription)

### ESP32 Bridge

- Hardware: ESP32-S3 with W5500 Ethernet module (or equivalent ETH board)
- Firmware: ESP-IDF 5.x
- WiFi: 2.4 GHz (no 5 GHz tested)
- Ethernet: 100Mbps to Canon C200
- Power: USB-C or 5V DC

### Camera

- Canon C200 (Cinema RAW Light or standard recording)
- Browser Remote must be enabled (menu → Network Settings → Browser Remote)
- Default credentials: `admin` / `admin`
- **Fine Increment must be OFF** (Menu → ISO/Gain → Fine Increment → Off)
  - With Fine Increment ON: each button press = 1/3 stop mechanical, but reporting only updates every ~3 presses, causing multi-step drift
  - With Fine Increment OFF: each button press = 1 full reported stop change

---

## Canon C200 API Notes

The C200 Browser Remote API is an undocumented HTTP API. Key findings:

| Property | API Key | Notes |
|----------|---------|-------|
| Aperture | `av` | Returns string like `"F2.8"`, `"F5.6"` |
| ISO/Gain | `gcv` | Returns integer string like `"800"`, `"1000"` |
| Shutter | `ssv` | Returns string like `"180.00"` (1/180) |
| ND Filter | `ndv` | Returns string value |
| WB Mode | `wbm` | Discrete mode values |
| WB Kelvin | `wbvk` | Returns Kelvin value with "K" suffix |
| AE Shift | `aesv` | Returns decimal string |
| Recording | `rec` | `"stby"` or `"rec"` |

Control commands use `drivelens` (incremental) or `setprop` (absolute):
- `/api/cam/drivelens?iris=plus` — increment aperture
- `/api/cam/drivelens?iso=minus` — decrement ISO
- `/api/cam/setprop?wbm=auto` — set white balance mode

Full API reference: [CANON_C200_API.md](../CANON_C200_API.md)

---

## Open Questions / Decisions

1. **Should the Companion module be in this repo or a separate `avl-c200-companion` repo?** Currently it's a subdirectory here. The Companion module system expects modules in their own repos with a specific naming convention (`companion-module-<manufacturer>-<product>`). Consider splitting.

2. **Multi-camera preset synchronization** — Current behavior: each camera recalls independently (sequential within each camera, concurrent across cameras). Consider a "hold and release" approach for tighter sync.

3. **Sparkle integration** — Required by org standards before stable release. Appcast URL should be `appcast-c200controller.xml`.

---

## Version History

| Version | Status | Notes |
|---------|--------|-------|
| v1.0.0-alpha | Current | Core functionality working in limited testing |
