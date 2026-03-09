# Security Findings - ESP32 Canon C200

**Review Date**: 2026-03-01
**Reviewer**: Claude Security Review (Clara)
**Severity Summary**: 0 Critical, 1 High, 2 Medium, 1 Low

## Findings

| ID | Severity | Finding | File | Line | Status |
|----|----------|---------|------|------|--------|
| ESP-01 | HIGH | ESP32 HTTP API has no authentication | ESP32 firmware | - | Open |
| ESP-02 | MEDIUM | Camera credentials (admin/admin) transmitted over HTTP | ESP32 firmware | - | Open |
| ESP-03 | MEDIUM | Camera control commands accessible to any network device | ESP32 firmware | - | Open |
| ESP-04 | LOW | WiFi credentials baked into firmware at flash time | ESP32 firmware | - | Open |

## Detailed Findings

### ESP-01 [HIGH] ESP32 HTTP API has no authentication

**Location**: ESP32 firmware HTTP endpoints
**Description**: The ESP32 bridge exposes a full REST API (GET/POST endpoints for camera status, recording, iris, ISO, shutter, ND, white balance, AE shift) and a WebSocket endpoint on the local network with no authentication whatsoever. Any device on the WiFi network can control all connected cameras.
**Impact**: An unauthorized user on the production network could start/stop recording, change camera exposure settings, or disrupt a live production. This is the most significant risk in this system.
**Remediation**: This is documented as a known limitation (trusted network assumption). Consider adding a simple API key or bearer token for defense-in-depth. The Canon C200 itself does not support authentication on its Browser Remote, so the ESP32 bridge inherits this limitation.

### ESP-02 [MEDIUM] Camera credentials transmitted over HTTP

**Location**: ESP32 to Canon C200 communication
**Description**: The ESP32 communicates with the Canon C200's Browser Remote API over plain HTTP. The default camera credentials (`admin`/`admin`) are sent in HTTP requests. The Canon C200 does not support HTTPS.
**Impact**: Credentials can be sniffed on the local network. Since these are default camera credentials on a dedicated production network, the practical risk is low.
**Remediation**: Cannot be fixed — the Canon C200 does not support HTTPS. Mitigate by using a dedicated/isolated VLAN for camera control traffic.

### ESP-03 [MEDIUM] Camera control commands accessible to any network device

**Location**: ESP32 REST API (POST endpoints)
**Description**: POST endpoints like `/api/camera/rec`, `/api/camera/iris/{plus|minus}`, `/api/camera/iso/{plus|minus}` allow any HTTP client to control camera settings without authorization.
**Impact**: An unauthorized client could start/stop recording or change exposure settings during a live production. This is a production reliability concern more than a data security concern.
**Remediation**: See ESP-01. Network isolation is the primary mitigation.

### ESP-04 [LOW] WiFi credentials baked into firmware at flash time

**Location**: ESP32 firmware (compiled with credentials)
**Description**: WiFi SSID and password are compiled into the ESP32 firmware binary. While not stored in this repository (they are set via the ESP32Flasher app), they are stored in the flash memory of the ESP32 device.
**Impact**: Physical access to the ESP32 could allow extraction of WiFi credentials via firmware dump. On a dedicated production network, this is low risk.
**Remediation**: This is documented in the existing security policy. Use a dedicated production WiFi network that is isolated from the main network.

## Security Posture Assessment

**Overall Risk: MEDIUM**

The ESP32 Canon C200 bridge operates in a trust model where the production network is considered trusted. The main risks stem from the Canon C200's own limitations (no HTTPS, default credentials). The macOS dashboard stores no sensitive data (camera presets in UserDefaults, no credentials). The firmware credentials are not in the repository. Network isolation is the primary security control.

## Remediation Priority

1. ESP-01 - Add optional API authentication to ESP32 firmware
2. ESP-03 - Network isolation for camera control VLAN
3. ESP-02 - Cannot fix (Canon hardware limitation)
4. ESP-04 - Use dedicated production WiFi

---

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
