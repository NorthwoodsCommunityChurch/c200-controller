# ESP32 Firmware Update — Design & Implementation Guide

Reference implementation for anyone building a macOS-app-driven OTA system for ESP32 devices.

**Companion doc:** [PRD-ESP32-OTA.md](PRD-ESP32-OTA.md) — what and why.
**This doc:** how it works end-to-end, with code-level detail and pitfalls.

---

## 0. Before you start — what you need

### Hardware

| Item | What to get | Notes |
|------|-------------|-------|
| ESP32 dev board | **ESP32-S3** (e.g., Waveshare ESP32-S3-ETH, Espressif ESP32-S3-DevKitC-1) | S3 has built-in USB, more RAM (PSRAM), and more flash room than the original ESP32. If you have a different variant (ESP32-C3, ESP32-S2), the same OTA approach works but sdkconfig targets and partition sizes may differ. |
| USB cable | **USB-C data cable** (most S3 boards) | Check the cable carries data, not power-only. If `ls /dev/cu.*` doesn't show a new entry when you plug in the board, the cable is power-only. |
| Optional | USB-to-UART dongle | Only needed if your board doesn't have a native USB port (older ESP32 modules). Most S3 dev boards don't need this. |

### Software (Mac)

Install in this order:

**1. Xcode Command Line Tools** — needed by ESP-IDF's toolchain setup:
```bash
xcode-select --install
```

**2. ESP-IDF** (Espressif's official firmware framework) — pin to a stable release:
```bash
mkdir -p ~/esp && cd ~/esp
git clone -b v5.3 --recursive https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32s3        # or "all" for every chip variant
```

Install docs: https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/get-started/

This puts the Xtensa compiler, `idf.py`, and `esptool.py` into `~/.espressif/`. You activate the environment per-shell with:
```bash
source ~/esp/esp-idf/export.sh
```

Put that in a shell alias or a `.command` launcher if you'll do it often.

**3. Python 3.9+** — required by ESP-IDF. macOS ships with an acceptable version, but `brew install python` is cleaner:
```bash
brew install python
```

**4. Xcode (full install, not just CLI tools)** — needed only if you're building the macOS operator app. Install from the App Store. Xcode 15 or newer for Swift 5.9+.

**5. Sparkle framework** (for the macOS app's auto-update) — already managed via Swift Package Manager if you use the C200 project's `Package.swift` as a reference. No separate install.

### Reference documentation — bookmark these

- **ESP-IDF Programming Guide** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/ (the authoritative source for everything below)
- **OTA API reference** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/ota.html (explains `esp_ota_begin`, `esp_ota_write`, `esp_ota_set_boot_partition`, rollback)
- **Partition Tables** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-guides/partition-tables.html
- **esp_http_client** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/protocols/esp_http_client.html (what the firmware uses to fetch the `.bin` from the Mac)
- **esp_http_server (httpd)** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/protocols/esp_http_server.html (what the firmware uses to accept the POST trigger)
- **Bootloader rollback** — https://docs.espressif.com/projects/esp-idf/en/stable/esp32s3/api-reference/system/ota.html#rollback (the safety net)
- **esptool.py** — https://docs.espressif.com/projects/esptool/en/latest/esp32s3/ (what `idf.py flash` calls under the hood; useful for manual recovery)
- **Apple Network.framework / NWListener** — https://developer.apple.com/documentation/network/nwlistener (for the macOS app's tiny HTTP server)

### Sanity check before starting

Before writing a line of firmware, verify these four things in order:

1. `xcode-select -p` returns a path → CLI tools installed.
2. `ls ~/esp/esp-idf/export.sh` succeeds → ESP-IDF cloned.
3. `source ~/esp/esp-idf/export.sh && idf.py --version` prints a version → toolchain active.
4. Plug the board in → `ls /dev/cu.*` shows a new `cu.usbmodem…` entry → USB data cable works, board powered, drivers fine.

If any of those fail, fix them before moving on. They will not self-heal later.

---

## 1. System overview

```
┌─────────────────┐        POST /api/ota/update         ┌──────────────────┐
│   macOS app     │ ─────────────────────────────────▶  │   ESP32 board    │
│                 │   { "url": "http://MAC_IP:8765/     │                  │
│  bundles the    │      firmware.bin" }                │  downloads from  │
│  firmware.bin   │                                     │  the Mac, writes │
│                 │ ◀─────────────────────────────────  │  to inactive OTA │
│  serves HTTP    │   GET /firmware.bin                 │  partition,      │
│  on port 8765   │                                     │  flips boot part,│
│                 │                                     │  reboots         │
│  polls status   │ ─────────────────────────────────▶  │                  │
│                 │   GET /api/status                   │                  │
└─────────────────┘                                     └──────────────────┘
```

**One-line summary:** the app bundles the firmware, stands up a tiny local HTTP server, and sends each ESP32 a URL. The ESP32 pulls the binary over its own WiFi connection and commits it via the standard two-partition ESP-IDF OTA flow.

---

## 2. Initial USB flash (one-time per board)

### 2.1 Partition table

A board that's going to receive OTA updates needs **two app partitions** plus an `otadata` partition that the bootloader uses to track which is active. Standard layout:

```csv
# Name,   Type, SubType, Offset,   Size,
nvs,      data, nvs,     0x9000,   0x6000,
otadata,  data, ota,     0xf000,   0x2000,
app0,     app,  ota_0,   0x20000,  0x200000,
app1,     app,  ota_1,   0x220000, 0x200000,
```

Two 2 MB app slots. If your firmware is larger than 2 MB, bump both slots in lockstep. Size of `otadata` is always 0x2000 (two flash sectors — the bootloader writes to both for atomicity).

### 2.2 sdkconfig flags

The critical flags (in `sdkconfig.defaults` so every dev's build matches):

```
CONFIG_IDF_TARGET="esp32s3"
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_PARTITION_TABLE_CUSTOM_FILENAME="partitions.csv"
CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y
```

`BOOTLOADER_APP_ROLLBACK_ENABLE=y` is what gives you the "three failed boots auto-reverts" safety net.

### 2.3 Build and flash

```bash
# Source ESP-IDF once per shell:
source ~/esp/esp-idf/export.sh

# From the firmware project root (where CMakeLists.txt lives):
idf.py build

# Find the serial port with the board plugged in:
ls /dev/cu.*            # macOS — typically /dev/cu.usbmodemNNNN

# First-ever flash (wipes and programs all partitions):
idf.py -p /dev/cu.usbmodem2101 flash

# Optional — watch boot log to confirm:
idf.py -p /dev/cu.usbmodem2101 monitor
# (Ctrl+] to exit)
```

After this, the board is running firmware, on the network, and ready for OTA. USB is not needed again unless something goes wrong that OTA can't recover from.

### 2.4 What "baking in" credentials looks like

In the C200 codebase, `main.c` has:

```c
#define WIFI_SSID      "production-wifi"
#define WIFI_PASSWORD  "..."
#define CAMERA_IP      "1.1.1.2"
#define ETH_STATIC_IP  "1.1.1.1"
#define FIRMWARE_VERSION "1.0.21"
```

A build-time GUI (ESP32Flasher) lets non-engineers replace these values before flashing, so fresh hardware can be provisioned without editing source. For development, editing the defines directly is fine.

---

## 3. OTA update pipeline

Once a board is running firmware with an OTA HTTP server, updates are pushed from the macOS app.

### 3.1 Firmware endpoints (the contract)

Two endpoints on the ESP32's HTTP server:

| Method | Path               | Purpose |
|--------|--------------------|---------|
| POST   | `/api/ota/update`  | Starts an OTA download. Body: `{"url": "http://..."}`. Returns 200 immediately once the task is spawned. |
| GET    | `/api/ota/status`  | Progress snapshot. Returns `{"state": "idle\|downloading\|flashing\|rebooting\|error", "progress": 0..100, "error": "..."}`. |

Plus one endpoint on the *general* HTTP API (not OTA-specific):

| Method | Path           | Purpose |
|--------|----------------|---------|
| GET    | `/api/status`  | General health endpoint. Includes `"firmware_version": "1.0.21"`. **This is the app's authoritative success signal.** |

### 3.2 Firmware: POST handler — trigger OTA

`ota_update_handler` does four things, in order:

1. Rejects if an OTA is already in progress (`ota_state != IDLE && != ERROR`).
2. Validates request: `content_len <= 512`, body is JSON, has a `url` field, URL starts with `http://`. **This URL validation is required** — it runs through `esp_http_client` which will happily follow arbitrary hostnames. Reject anything that doesn't match the expected prefix. (If you accept HTTPS, verify cert pinning is in place.)
3. Copies the URL into a static buffer.
4. Spawns `ota_update_task` as a FreeRTOS task with 8 KB stack, priority 5.

Then immediately returns `{"status":"started"}`. The POST is non-blocking — the download happens in the task, not in the HTTP handler.

### 3.3 Firmware: OTA download task

`ota_update_task` is the workhorse. Sequence:

```c
// 1. Refuse if doing something critical (e.g., camera recording)
if (camera_recording) { set_error("Cannot update while recording"); return; }

// 2. Get the inactive partition
const esp_partition_t *update_partition = esp_ota_get_next_update_partition(NULL);

// 3. Open HTTP stream from the Mac
esp_http_client_handle_t client = esp_http_client_init(&cfg);
esp_http_client_open(client, 0);
int content_length = esp_http_client_fetch_headers(client);

// 4. Begin writing
esp_ota_handle_t handle;
esp_ota_begin(update_partition, OTA_WITH_SEQUENTIAL_WRITES, &handle);

// 5. Stream chunks into flash
char *buf = malloc(4096);
while ((read_len = esp_http_client_read(client, buf, 4096)) > 0) {
    esp_ota_write(handle, buf, read_len);
    total_read += read_len;
    ota_progress = (total_read * 100) / content_length;
}

// 6. Commit
esp_ota_end(handle);
esp_ota_set_boot_partition(update_partition);

// 7. Reboot into the new image
vTaskDelay(pdMS_TO_TICKS(2000));
esp_restart();
```

`OTA_WITH_SEQUENTIAL_WRITES` is faster than the default and is fine for this streaming pattern.

### 3.4 Firmware: status endpoint — the tricky part

This is the single biggest lesson from this project. **Do not hold a mutex in the status handler.**

The naive implementation looks reasonable:

```c
// BUGGY — do not do this
static esp_err_t ota_status_handler(httpd_req_t *req) {
    xSemaphoreTake(ota_mutex, pdMS_TO_TICKS(100));   // or 500, or whatever
    int progress = ota_progress;
    ota_state_t state = ota_state;
    ...
    xSemaphoreGive(ota_mutex);
    // build JSON and send
}
```

**Why it fails:** ESP-IDF's `httpd` runs in a single task. While the OTA download is saturating WiFi, the httpd task can be stalled by the WiFi/TCP stack holding internal locks — *the status handler may not get to run at all for several seconds*. When it finally does run, the `ota_update_task` has been flipping the mutex on every 4 KB chunk, and the handler can lose the race on `xSemaphoreTake`. If it loses, the handler falls through to the default response (state="idle", progress=0), and the operator sees "Starting..." forever even though the board is actively downloading.

Bumping the timeout (from 100 ms to 500 ms or higher) mitigates but doesn't fix this — the mutex is genuinely contended and sometimes you just can't win the race.

**The fix — lock-free reads with a write-ordering rule:**

```c
static volatile ota_state_t ota_state = OTA_STATE_IDLE;
static volatile int         ota_progress = 0;
static char                 ota_error[128] = "";      // only read when state==ERROR

static esp_err_t ota_status_handler(httpd_req_t *req) {
    // Atomic 32-bit reads on xtensa — no lock needed for int-sized volatiles
    ota_state_t snapshot_state = ota_state;
    int snapshot_progress = ota_progress;
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
    // ...build and send JSON...
}
```

The writer (`ota_update_task`) still uses the mutex to keep its own writes ordered with each other — **but it writes the error string before flipping state to ERROR:**

```c
// Correct write order: error string first, state flag last
xSemaphoreTake(ota_mutex, portMAX_DELAY);
snprintf(ota_error, sizeof(ota_error), "Write failed: %s", esp_err_to_name(err));
ota_state = OTA_STATE_ERROR;   // <-- state flip AFTER error is populated
xSemaphoreGive(ota_mutex);
```

Why this is safe:
- `ota_state` and `ota_progress` are `volatile int` — reads and writes are single-instruction atomic on 32-bit xtensa. The reader never sees a torn state value.
- `ota_error` is a multi-byte buffer that *could* tear under a lock-free read. But the reader only reads it when it sees state==ERROR, and by the time the writer has set state to ERROR, the error string is already fully written (because of the write-order rule). Once state is ERROR, the OTA task exits — there are no more writes — so subsequent reads of `ota_error` are stable.

### 3.5 App side: POST + progress polling

From the macOS app's side (see `FirmwareUpdateManager.swift` in the C200 codebase for the full implementation):

```swift
func updateBoard(camera: Camera, firmwareURL: String) async {
    // 1. Short-timeout URLSession so a hung request doesn't block the poll loop
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 5
    cfg.timeoutIntervalForResource = 10
    let session = URLSession(configuration: cfg)

    // 2. Capture baseline — this is the authoritative success signal
    let baselineVersion = await fetchFirmwareVersion(cameraIP: cameraIP, session: session)

    // 3. POST the trigger
    var req = URLRequest(url: URL(string: "http://\(cameraIP)/api/ota/update")!)
    req.httpMethod = "POST"
    req.httpBody = try JSONSerialization.data(withJSONObject: ["url": firmwareURL])
    _ = try await session.data(for: req)

    // 4. Assume download is in flight — show "Downloading..."
    boardStatuses[id] = .downloading(0)

    // 5. Poll until version changes (success) or timeout
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let currentVersion = await fetchFirmwareVersion(cameraIP: cameraIP, session: session)

        if currentVersion == nil {
            // Board unreachable → flashing/rebooting
            boardStatuses[id] = .rebooting
        } else if currentVersion != baselineVersion {
            // Version changed — DONE
            boardStatuses[id] = .done(currentVersion!)
            return
        } else {
            // Still on old version → try /api/ota/status for progress %
            // (cosmetic only — never fail based on it)
            if let progress = try? await fetchOTAProgress(...) {
                boardStatuses[id] = .downloading(progress)
            }
        }
    }
    boardStatuses[id] = .error("Timeout — try again")
}
```

**The key insight: the app does not trust `/api/ota/status` as the authoritative pass/fail signal.** It uses version change on `/api/status` (general endpoint). This makes the app immune to the "stuck on Starting" bug class — even if the target board has old, buggy firmware that always reports "idle", the app still correctly detects success when the board reboots onto a new version.

`/api/ota/status` is used only to populate a nice progress percentage while the download is in flight. If it reports "idle" forever (buggy firmware), the UI shows "Downloading..." without a percentage — still clear, no false error.

### 3.6 App side: serving the firmware

The app spins up a minimal HTTP server on a known port (8765 in the C200 case) for the duration of the update batch, serves the firmware bytes from memory (no temp files), and tears it down when all boards are done. `NWListener` from `Network.framework` is enough — you need maybe 40 lines of Swift.

```swift
private func handleFirmwareRequest(_ connection: NWConnection) {
    let data = firmwareData  // captured on MainActor before entering the closure
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _,_,_,_ in
        let header = "HTTP/1.1 200 OK\r\n" +
                     "Content-Type: application/octet-stream\r\n" +
                     "Content-Length: \(data.count)\r\n" +
                     "Connection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
    connection.start(queue: .main)
}
```

Point is: this is a few dozen lines, not a web framework. Don't overbuild it.

---

## 4. Rollback safety

With `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y`, the bootloader tracks successful boots of the currently-pending image. If the new image crashes (or fails to call `esp_ota_mark_app_valid_cancel_rollback()` — which is implicit after successful boot + some runtime) three times in a row, the bootloader automatically marks the new slot as invalid and boots the *previous* slot.

Caveats:
- The new firmware has to actually reach a stable runtime for rollback to consider it "validated". If your app has a post-boot initialization that takes 30 seconds, that window is at risk.
- A hung (but not crashed) new image won't auto-roll-back. The watchdog has to trip. Make sure `CONFIG_BOOTLOADER_WDT_ENABLE` is on.
- Manual rollback is always an option: connect USB, `idf.py flash` a known-good image.

---

## 5. Operator UX guardrails

Lessons from operators pushing this in production:

- **Let them close the update modal while it's still running.** An operator watching "Downloading…" across 8 boards may want to step away. Don't lock them out.
- **Show per-board status in a grid** — controller name, current version, new version, checkbox, status. Checkboxes default to unchecked (or selected, depending on whether "update all" is the common case — for C200 it's "pick a specific one" so unchecked is right).
- **Unreachable boards should be obvious and disabled.** A board that's offline can't be updated; show "Offline" in orange and gray out the checkbox.
- **Error messages are for operators, not engineers.** "Update didn't start — try again" is better than "HTTP 500: OTA task creation failed". If the actionable advice is "try again," say that.
- **The app version bumps every time firmware changes.** Because the firmware is bundled inside the app, and the app is delivered via Sparkle, operators get the new firmware by updating the app. A firmware-only release has no delivery path to them.

---

## 6. Security posture (as shipped)

This implementation targets a trusted local network. Explicit non-protections:

- **HTTP, not HTTPS.** The firmware transfer is plaintext; the POST trigger is plaintext. Acceptable because every byte is on an isolated production network.
- **No authentication on OTA endpoints.** Any device on the subnet can POST an update URL. Acceptable because only authorized devices are on the subnet.
- **No firmware signature verification.** The ESP32 trusts whatever it downloads from the URL you gave it. Safe because the URL is always the operator's Mac, and the Mac has the correct binary.

If any of those assumptions break (boards on a shared WiFi, remote operators, public-internet exposure), upgrade to:
- `esp_https_ota` with a pinned server certificate
- `esp_ota_verify_chip_id` + signed images (`CONFIG_SECURE_BOOT_V2_ENABLED` + `CONFIG_SECURE_SIGNED_APPS_ECDSA_V2_SCHEME=y`)
- An auth header on the POST trigger (shared secret or token)

---

## 7. Pitfalls & gotchas (summary)

- **`httpd` is single-task.** Any handler that takes a lock shared with another task can stall for seconds while WiFi/TCP work blocks the httpd task. Keep status handlers lock-free.
- **URLSession.shared default request timeout is 60 seconds.** If you're retrying 5 times, you can block for 5 minutes on a dead board. Always pass an explicit `URLSessionConfiguration` with a short `timeoutIntervalForRequest` to OTA polls.
- **Do not trust the device you're updating.** The field firmware may be buggy in ways the new firmware fixes. Build the app's success detection so it works *even if the firmware it's updating is wrong about its own state*. (The version-change signal does this.)
- **@MainActor in Swift serializes things that look parallel.** `withTaskGroup` of main-actor-isolated methods runs sequentially, not concurrently. Use `Task.detached` for true parallel OTA across many boards.
- **Bundle the firmware inside the app, not side-loaded.** One binary delivered via one channel (Sparkle) is enormously simpler than two-channel updates where the app and firmware can drift.
- **Ad-hoc code signing and Sparkle:** on macOS, the Sparkle framework's nested XPCs need to be re-signed inside-out after bundling, or the app crashes on launch on other machines. See the project's `build.sh` for the signing sequence.

---

## 8. Repo layout reference

For a project built like this, the top-level layout is:

```
project-root/
├── ESP32Flasher/
│   └── FirmwareTemplate/
│       ├── main/main.c            # firmware source (OTA + HTTP + app logic)
│       ├── partitions.csv         # 2 OTA slots + otadata
│       ├── sdkconfig.defaults     # rollback enabled
│       └── build/                 # idf.py output (c200_bridge.bin lives here)
├── MyApp/                         # the macOS app
│   ├── Sources/
│   │   ├── FirmwareUpdateManager.swift   # POST + polling + local HTTP server
│   │   ├── FirmwareUpdateView.swift      # the grid UI
│   │   └── ...
│   └── build.sh                   # bundles firmware .bin into the .app
└── docs/
    ├── PRD-ESP32-OTA.md           # what & why
    └── ESP32-OTA-DESIGN.md        # this file
```

`build.sh` copies the firmware `.bin` into `Contents/Resources/` inside the `.app` bundle at build time, so the running app can always find a firmware to push. Also bundle a plain-text `firmware_version.txt` alongside so the app can show the target version in the UI without parsing the binary.
