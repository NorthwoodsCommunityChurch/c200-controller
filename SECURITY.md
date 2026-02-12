# Security Policy

## Supported Versions

This project is in alpha (`v1.0.0-alpha`). Security fixes will be applied to the latest release only.

## Reporting a Vulnerability

Report security issues to the [GitHub Issues](../../issues) page with the label `security`, or contact the repository owner directly.

Please do **not** post credential-related issues in public issues.

## Security Architecture

### Threat Model

This system is designed for use on a **trusted private production network** (church AV booth LAN). It is not hardened for deployment on public or untrusted networks.

### Known Limitations

| Component | Limitation |
|-----------|------------|
| ESP32 HTTP API | No authentication — any device on the same network can send commands |
| ESP32 ↔ Camera | HTTP only (no TLS) — Canon C200 Browser Remote does not support HTTPS |
| Camera credentials | Canon C200 default credentials (`admin` / `admin`) — change if accessible from broader network |
| Mac dashboard | HTTP only to ESP32 bridge — no TLS (same subnet assumption) |

### Network Exposure

The ESP32 bridge exposes these endpoints on the local WiFi network:

- `GET /api/status` — ESP32 and camera status (read-only)
- `GET /api/camera/state` — Current camera settings (read-only)
- `POST /api/camera/rec` — Toggle recording
- `POST /api/camera/iris/{plus|minus}` — Iris adjustment
- `POST /api/camera/iso/{plus|minus}` — ISO adjustment
- `POST /api/camera/shutter/{plus|minus}` — Shutter adjustment
- `POST /api/camera/nd/{plus|minus}` — ND filter adjustment
- `POST /api/camera/wb/{mode}` — White balance mode
- `POST /api/camera/aes/{plus|minus}` — AE shift
- `POST /api/camera/wbk/{plus|minus}` — White balance Kelvin
- `GET /ws` — WebSocket for real-time state push

### Data Storage

The macOS dashboard stores the following in `UserDefaults` (not Keychain):

- Camera names, IP addresses, and connection type
- Camera presets (exposure settings only — no credentials)
- Auto-reconnect preference

No passwords, authentication tokens, or credentials are stored by the macOS app.

### Firmware Credentials

The ESP32 firmware is compiled with WiFi SSID/password and camera IP address baked in. These credentials are set at flash time via the [ESP32Flasher](../ESP32Flasher/) app and are **not stored in this repository**.

**Never commit `main.c` or `sdkconfig` files containing real credentials to a public repository.**

## Checklist

- [x] No hardcoded credentials in this repository
- [x] Dashboard stores camera list in UserDefaults (no sensitive data)
- [x] Firmware credentials set at flash time (not in source)
- [ ] TLS for ESP32 API — not implemented (Canon camera does not support HTTPS)
- [ ] ESP32 API authentication — not implemented (trusted network assumption)
- [ ] Sparkle auto-updates — not yet integrated
