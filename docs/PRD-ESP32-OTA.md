# PRD: ESP32 Firmware Update System (USB + OTA)

**Status:** Shipping — in production use
**Last updated:** 2026-04-24
**Reference implementation:** `NorthwoodsCommunityChurch/c200-controller`

---

## Problem

Embedded ESP32 devices deployed around a facility need firmware updates. Two distinct scenarios:

1. **First-time flash** — a fresh ESP32 board with no firmware. Needs to be brought up to a known-good baseline before deployment.
2. **Field updates** — a deployed board running firmware needs to be upgraded. Pulling each board off-site and connecting USB is not practical; updates must happen over the network while the board is mounted and wired to its target device.

The system must be safe (no bricked boards if an update fails), observable (operator can see progress and outcome), and simple enough for a non-engineer to run.

---

## Goals

- **Initial flash** — one command (`idf.py -p <port> flash`) to get a blank ESP32 to a known baseline.
- **Over-the-air updates** — one button in the operator-facing macOS app to push a new firmware to every board on the network.
- **Safe rollback** — if an update corrupts the firmware or the new image crashes on boot, the board automatically reverts to the previous working image.
- **Observable** — the operator sees per-board status in the app: downloading, flashing, rebooting, done, or a clear error.
- **Tolerant of stale clients** — the app must correctly detect success even if older field firmware has bugs in its own progress-reporting code. The app cannot assume the firmware it's updating is trustworthy.
- **Local-network only** — no internet dependency; no cloud update service. Firmware is served from the operator's Mac to the ESP32 over the local WiFi.

---

## Non-goals

- Public internet distribution (app-store-style update channels). A secondary concern.
- Signed firmware verification (cryptographic signing of the `.bin` file). The current implementation trusts the local network; if this ships outside a closed network, signed OTA via `esp_https_ota` with a pinned cert is the next step.
- Updating non-ESP32 devices. This PRD is ESP32-specific.
- Delta/differential updates. Full firmware image every time. A 1 MB image over local WiFi takes a few seconds; the complexity of delta updates isn't warranted.

---

## Users

- **Operator (primary)** — a non-engineer running the macOS app. Clicks one button (⌘⇧U), picks which boards to update, watches progress. Never sees a terminal.
- **Engineer (initial deployment + development)** — flashes new hardware over USB, develops firmware locally, embeds network credentials at build time.

---

## Functional requirements

### Initial USB flash
- Single command produces a deployable board from a blank ESP32.
- Network credentials (WiFi SSID/password, static IP, etc.) are baked into the firmware at build time. A fresh board with the wrong credentials is a fresh board with the wrong credentials — no broadcast provisioning flow needed in this environment.
- A board flashed this way is immediately ready for OTA from that point on.

### OTA update
- Operator selects one or more boards from a list in the macOS app.
- App serves the firmware binary (bundled inside the app) from a short-lived local HTTP server.
- App POSTs an update trigger to each selected board in parallel.
- App polls each board and shows its status: starting → downloading → flashing → rebooting → done (or error).
- App detects completion authoritatively via a version-change signal on a general status endpoint, not via the OTA-specific status endpoint. (See design doc for why.)
- If an update fails on one board, other boards are unaffected.

### Safety
- Board refuses OTA while doing something it must not interrupt (in the C200 case, while the camera is recording).
- Two-partition OTA with automatic bootloader rollback: if the new image fails to boot cleanly three times, the bootloader reverts to the previous image.
- URL and content-length validation on the OTA trigger endpoint to prevent malformed input from crashing the board.

---

## Success criteria

- A blank ESP32 can be flashed from USB to a deployable state in under 60 seconds.
- A single board can be updated OTA in under 60 seconds end-to-end (POST → download → flash → reboot → version verified).
- A batch of 8 boards can be updated OTA in under 3 minutes (parallel, limited by per-board download speed).
- Zero bricked boards across the production fleet through ordinary use.
- Operator does not need to restart the app or the boards to recover from a normal update.

---

## Constraints and assumptions

- Boards are on a trusted local network (isolated WiFi + wired subnet). HTTP — not HTTPS — is acceptable for the firmware transfer.
- The macOS app is distributed via Sparkle and is always the source of firmware binaries; the app bundles one firmware version internally.
- ESP-IDF is the firmware framework (not Arduino). ESP32-S3 is the primary target chip.
- The operator has network access to every board they want to update (i.e., they're on the same subnet or can route to them).

---

## Open risks

- **Operator-visible "stuck on Starting"** — if the firmware currently on a board has a bug in its own status reporting, the app must not hang forever or falsely report failure. The app's fail/success detection must not depend on the field firmware being correct. *(Addressed in the design doc — use reachability + version-change as the authoritative signal.)*
- **httpd task starvation during heavy download** — the ESP-IDF HTTP server runs in a single task; while OTA download is saturating WiFi, the status handler may take a long time to respond. Any lock held across the download path will make the status endpoint look frozen. *(Addressed: status handler is lock-free.)*
- **No cryptographic firmware verification** — if the threat model ever extends beyond the closed network, move to signed OTA with `esp_https_ota` and a pinned certificate.
