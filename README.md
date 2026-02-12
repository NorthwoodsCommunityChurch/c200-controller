# C200 Controller

macOS dashboard for wireless control of Canon C200 cameras via an ESP32-S3 hardware bridge.

## Screenshots

<!-- Add screenshots to docs/images/ and reference here -->
*Dashboard screenshots pending — see docs/images/ folder*

## Features

- **Multi-camera dashboard** — monitor and control multiple C200s simultaneously
- **Real-time state** — WebSocket push updates from ESP32 bridge (no manual refresh)
- **Camera controls** — iris, ISO, shutter speed, ND filter, white balance, AE shift
- **Record toggle** — start/stop recording remotely with visual feedback
- **Presets** — save and recall camera settings (aperture, ISO, shutter, ND, WB, AE shift)
- **Auto-reconnect** — automatically retry failed connections every 10 seconds
- **Bonjour discovery** — ESP32 bridges appear automatically on the local network
- **Direct connection** — connect to Canon C200 without an ESP32 bridge (limited)
- **Card flip UI** — each camera tile flips to reveal connection settings and controls

## Requirements

- macOS 13.0 or later
- Apple Silicon (primary) or Intel (untested)
- Local network with mDNS/Bonjour (standard on most networks)
- One or more **ESP32-S3 bridge boards** flashed with the matching firmware
  - Use the companion [ESP32Flasher](../ESP32Flasher/) app for one-click flashing
- Canon C200 with **Browser Remote enabled** on its network port
  - Firmware default credentials: `admin` / `admin`

## Installation

1. Download `C200Controller-v1.0.0-alpha-aarch64.zip` from [Releases](../../releases)
2. Extract the zip and move `C200Controller.app` to your Applications folder
3. Double-click to open — macOS will block it the first time
4. Go to **System Settings → Privacy & Security** and click **Open Anyway**
5. The app opens normally from that point on

## Usage

### Adding a Camera

**Via Bonjour (automatic):**
1. Flash the ESP32 bridge with your WiFi credentials
2. Power on the bridge — it appears in the dashboard automatically
3. Click the camera tile to connect

**Manual ESP32:**
1. Click **+** in the toolbar
2. Enter the ESP32's IP address

**Direct camera:**
1. Enable Browser Remote on the Canon C200 (Menu → Network → Browser Remote)
2. Click **+** → **Direct Camera**
3. Enter the camera's IP address

### Using Presets

1. Click **Edit** in the Presets panel (left sidebar)
2. Camera metric circles dim — click each circle you want to include
3. Included circles show the current camera value in green
4. Click **Save** — enter a preset name
5. Click **Recall** to apply a preset to all connected cameras

### Auto-Reconnect

Toggle **Auto-Reconnect** on the camera tile back (flip the card). When enabled, the app retries connections every 10 seconds after a failure.

## Configuration

All configuration is stored in `UserDefaults` — no config files needed.

- Camera list persists across launches
- Presets persist across launches
- Auto-reconnect setting persists across launches

## Building from Source

### Prerequisites

- Xcode Command Line Tools: `xcode-select --install`
- Swift 5.9+

### Build

```bash
git clone https://github.com/NorthwoodsCommunityChurch/avl-c200-controller.git
cd avl-c200-controller/C200Controller
bash build.sh
```

The built app opens automatically. Find it at `C200Controller/.build/release/C200Controller.app`.

## Project Structure

```
avl-c200-controller/
├── C200Controller/              macOS dashboard app (Swift/SwiftUI)
│   ├── Sources/
│   │   ├── C200ControllerApp.swift   App entry point
│   │   ├── Camera.swift              Camera state + control logic
│   │   ├── CameraManager.swift       Multi-camera management + discovery
│   │   ├── ContentView.swift         Main UI
│   │   ├── Logger.swift              Debug log writer
│   │   ├── Preset.swift              Preset data model
│   │   ├── PresetManager.swift       Preset persistence + recall
│   │   └── PresetsPanel.swift        Preset sidebar UI
│   ├── Package.swift
│   └── build.sh
├── companion-module/            Bitfocus Companion integration (incomplete)
│   ├── index.js
│   └── package.json
├── docs/
│   ├── PRD.md                   Product requirements
│   └── images/                  Screenshots
├── CANON_C200_API.md            Canon C200 Browser Remote API reference
├── BUILD.md                     Firmware build instructions
├── CREDITS.md
├── LICENSE
└── SECURITY.md
```

## Network Architecture

```
Canon C200  ←──── Ethernet ────→  ESP32-S3 Bridge
                                         │
                                         └── WiFi ──→  C200 Controller (Mac)
                                         └── mDNS     (Bonjour discovery)

                                                            │
                                                   (future) └──→  Bitfocus Companion
```

## Known Limitations / Alpha Status

- Dashboard has been lightly tested on a single-camera production setup
- Intel Mac compatibility untested
- Bitfocus Companion module is a skeleton — not functional yet
- Sparkle auto-updates not yet integrated (planned for stable release)
- Direct camera connection mode has reduced functionality vs. ESP32 bridge

## License

MIT — see [LICENSE](LICENSE)

## Credits

See [CREDITS.md](CREDITS.md)
