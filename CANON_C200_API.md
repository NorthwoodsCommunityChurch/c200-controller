# Canon C200 Browser Remote API Documentation

**Camera IP:** 10.10.11.35
**Base Path:** `/wpd/VNCX02/`
**Auth:** HTTP Basic (admin:admin)
**Product ID:** VNCX02

---

## VERIFIED WORKING - Your Camera's Current Settings

These were queried live from your C200 at 10.10.11.35:

### Exposure
| Setting | Current | Options | Enabled |
|---------|---------|---------|---------|
| **Aperture (av)** | F5.6 | F1.8-F16 (20 steps) | Yes |
| **Aperture Type (atype)** | T-stop | F, T | Yes |
| **Aperture Step (avst)** | 3fine | 2, 3, 2fine, 3fine | Yes |
| **Iris Mode (am)** | --- | autoiris, maniris | No (disabled) |
| **ISO/Gain Mode (gcm)** | ISO | iso, gain | Yes |
| **ISO Value (gcv)** | 1000 | 160-25600 (23 steps) | Yes |
| **Gain Step (gcvst)** | 1/3 | 1, 1/3 | Yes |
| **Gain Extended (gcext)** | off | off, on | Yes |
| **Shutter Mode (ssm)** | angle | speed, angle, cls, slow, off | Yes |
| **Shutter Value (ssv)** | 180.00° | 11.25°-360° (15 steps) | Yes |
| **Shutter Step (ssvst)** | --- | 3, 4 | No (disabled) |
| **AE Shift (aesv)** | 0 | -2.0 to +2.0 (17 steps) | Yes |

### ND Filter
| Setting | Current | Options | Enabled |
|---------|---------|---------|---------|
| **ND Value (ndv)** | 2 stops | 0, 2, 4, 6, 8, 10 | Yes |
| **ND Extended (ndext)** | on | off, on | Yes |

### White Balance
| Setting | Current | Options | Enabled |
|---------|---------|---------|---------|
| **WB Mode (wbm)** | user1 | awb, seta, setb, daylight, tungsten, user1-5 | Yes |
| **WB Kelvin (wbvk)** | 4760K | 2000K-15000K (88 steps) | Yes |
| **WB Color Comp (wbvc)** | -2 | -20 to +20 (41 steps) | Yes |

### Focus
| Setting | Current | Options | Enabled |
|---------|---------|---------|---------|
| **AF Mode (afm)** | oneshot | oneshot, afboostedmf, continuous | No |
| **AF Position (fpos)** | selectable | selectable, center | No |
| **Face Detection (fdat)** | off | off, on | Yes |
| **Face AF (faf)** | only | priority, only | No |
| **Focus Speed (fsv)** | --- | +2 to -7 (10 steps) | No |
| **Focus Guide (fguide)** | on | off, on | Yes |

---

## Authentication

### Login
```
GET /api/acnt/login
```
Returns: `{"res":"ok"}` or `{"res":"errsession"}` (another client connected)

**Important:** Only ONE client can be connected at a time. The ESP32 will be the sole client.

### Get Device Info
```
GET /api/sys/getdevinfo
```
Returns: `modelName`, `manufacturer`, `serialNum`, `lang`, `mode`, `productId`

---

## Status Polling

### Get Current Properties
```
GET /api/cam/getcurprop?seq={N}
```
- Poll this endpoint every ~1 second
- `seq` starts at 0, camera returns next sequence number
- Returns JSON with all current camera state

**Response Properties:**

| Property | Description | Values |
|----------|-------------|--------|
| `res` | Result | `ok`, `busy`, `errsession` |
| `seq` | Next sequence number | integer |
| `mode` | Camera mode | `ctrl`, `nonctrl`, `ctrlnonlv` |
| `rec` | Recording status | `stby`, `rec`, `sf_stby`, `sf_rec`, `frm_stby`, `frm_rec`, `int_stby`, `int_rec`, `pre_rec`, `pre_rec_stby`, `pre_rec_rec` |
| `extrec` | External recording | `off`, `stby`, `rec` |
| `contrec` | Continuous recording | `off`, `stby`, `rec` |
| `tc` | Timecode | string `HH:MM:SS:FF` |
| `recfmt` | Recording format | `mp4`, `xf-avc`, `raw`, `non` |
| `camid` | Camera ID string | string |
| `msg` | Warning/error message | string |

**Nested Status Objects:**

| Object | Contents |
|--------|----------|
| `Opower` | Battery: `Obatt.percent`, `Obatt.rtime` |
| `Omedia` | Cards: `Ocfa`, `Osda`, `Osdb` with `state`, `rtime` |
| `Owbinfo` | White balance mode, kelvin, CC values |
| `Ondinfo` | ND filter value, extended range |
| `Oirisinfo` | Iris mode, step, value |
| `Oisogaininfo` | ISO/Gain mode, step, value, extended range |
| `Oshutterinfo` | Shutter mode, step, value |
| `Oaesinfo` | AE shift value |
| `Ofocusinfo` | AF mode, position, face detection, speed |
| `Olensinfo` | Lens name, type |
| `Opz` | Power zoom step |

---

## Recording Control

### Toggle Recording
```
GET /api/cam/rec?cmd=trig
```
Starts recording if stopped, stops if recording.

### Switch Recording Slot
```
GET /api/cam/rec?cmd=slot
```
Switches between SD card slots.

---

## Clip Markers

### Mark Clip OK
```
GET /api/cam/markclip?type=ok
```

### Mark Clip Check
```
GET /api/cam/markclip?type=check
```

### Mark Shot 1
```
GET /api/cam/markclip?type=shot1
```

---

## White Balance

### Set White Balance Mode
```
GET /api/cam/setprop?wbm={mode}
```

| Mode | Description |
|------|-------------|
| `awb` | Auto White Balance |
| `seta` | Preset A |
| `setb` | Preset B |
| `daylight` | Daylight (~5600K) |
| `tungsten` | Tungsten (~3200K) |
| `user1` | User Preset 1 |

### AWB Hold (Lock current AWB)
```
GET /api/cam/cmdwb?awbhold=trig
```

### Execute Set A/B (capture white balance)
```
GET /api/cam/cmdwb?wbset=a
GET /api/cam/cmdwb?wbset=b
```

---

## ND Filter

### Adjust ND Filter
```
GET /api/cam/drivelens?nd=plus
GET /api/cam/drivelens?nd=minus
```

---

## Iris / Aperture

### Adjust Iris
```
GET /api/cam/drivelens?iris=plus
GET /api/cam/drivelens?iris=minus
```

### Push Auto Iris (momentary auto exposure)
```
GET /api/cam/drivelens?ai=push
```

---

## ISO / Gain

### Adjust ISO
```
GET /api/cam/drivelens?iso=plus
GET /api/cam/drivelens?iso=minus
```

### Adjust Gain
```
GET /api/cam/drivelens?gain=plus
GET /api/cam/drivelens?gain=minus
```

---

## Shutter

### Adjust Shutter
```
GET /api/cam/drivelens?shutter=plus
GET /api/cam/drivelens?shutter=minus
```

---

## AE Shift

### Adjust AE Shift
```
GET /api/cam/drivelens?aes=plus
GET /api/cam/drivelens?aes=minus
```

---

## Focus Control

### One-Shot AF
```
GET /api/cam/drivelens?focus=oneshotaf
```

### AF Lock
```
GET /api/cam/drivelens?focus=aflock
```

### Face/Subject Tracking AF
```
GET /api/cam/drivelens?focus=track
```

### Cancel Tracking
```
GET /api/cam/drivelens?focus=trackcancel
```

### Manual Focus Adjustment
For continuous focus movement (hold button):
```
GET /api/cam/drivelens?fl=near1start   # Start slow near
GET /api/cam/drivelens?fl=near2start   # Start medium near
GET /api/cam/drivelens?fl=near3start   # Start fast near
GET /api/cam/drivelens?fl=far1start    # Start slow far
GET /api/cam/drivelens?fl=far2start    # Start medium far
GET /api/cam/drivelens?fl=far3start    # Start fast far
GET /api/cam/drivelens?fl=near1stop    # Stop movement
```

For single-step focus (tap):
```
GET /api/cam/drivelens?fl=near1   # Step slow near
GET /api/cam/drivelens?fl=near2   # Step medium near
GET /api/cam/drivelens?fl=near3   # Step fast near
GET /api/cam/drivelens?fl=far1    # Step slow far
GET /api/cam/drivelens?fl=far2    # Step medium far
GET /api/cam/drivelens?fl=far3    # Step fast far
```

---

## Status Property Details

### Recording Status (`rec`)
| Value | Description |
|-------|-------------|
| `stby` | Standby (ready to record) |
| `rec` | Recording |
| `sf_stby` | Slow/Fast standby |
| `sf_rec` | Slow/Fast recording |
| `frm_stby` | Frame recording standby |
| `frm_rec` | Frame recording |
| `int_stby` | Interval recording standby |
| `int_rec` | Interval recording |
| `pre_rec` | Pre-recording enabled |
| `pre_rec_stby` | Pre-recording standby |
| `pre_rec_rec` | Pre-recording active |

### White Balance Info (`Owbinfo`)
```json
{
  "Omode": {"pv": "awb", "en": 1},
  "Oawb": {"kelvinvalue": "5500", "ccvalue": "0", "en": 1},
  "Oseta": {"Ovalue": {...}, "Osts": {"pv": "comp"}},
  "Osetb": {"Ovalue": {...}, "Osts": {"pv": "comp"}},
  "Odaylight": {"kelvinvalue": "5600", "ccvalue": "0"},
  "Otungsten": {"kelvinvalue": "3200", "ccvalue": "0"},
  "Ouser1": {"kelvinvalue": "5500", "ccvalue": "0"},
  "Oawbhold": {"pv": "off", "en": 1}
}
```

### Iris Info (`Oirisinfo`)
```json
{
  "Omode": {"pv": "maniris", "en": 1},     // maniris or autoiris
  "Ostep": {"pv": "1/3", "en": 1},         // 1/2, 1/3, fine
  "Ovalue": {"pv": "F2.8", "en": 1},       // F-stop or T-stop
  "Odisp": {"pv": "F", "en": 1},           // Display type F or T
  "Opushai": {"pv": "stop", "en": 1}       // Push auto iris state
}
```

### ISO/Gain Info (`Oisogaininfo`)
```json
{
  "Omode": {"pv": "iso", "en": 1},         // iso or gain
  "Ostep": {"pv": "1/3", "en": 1},         // 1/3, normal, fine
  "Ovalue": {"pv": "800", "en": 1},        // ISO value or dB
  "Oextrange": {"pv": "off", "en": 1}      // Extended range
}
```

### Shutter Info (`Oshutterinfo`)
```json
{
  "Omode": {"pv": "speed", "en": 1},       // speed, angle, cls, slow, off
  "Ostep": {"pv": "1/3", "en": 1},
  "Ovalue": {"pv": "1/50", "en": 1}        // Speed or angle value
}
```

### ND Filter Info (`Ondinfo`)
```json
{
  "Ovalue": {"pv": "1/4", "en": 1},        // off, 1/4, 1/16, 1/64, etc.
  "Oextrange": {"pv": "off", "en": 1}      // Extended range
}
```

### Focus Info (`Ofocusinfo`)
```json
{
  "Oafmode": {"pv": "continuous", "en": 1},  // oneshot, continuous
  "Oafpos": {"pv": "center", "en": 1},       // center, selectable
  "Ofacedat": {"pv": "on", "en": 1},         // Face detection
  "Ofaceaf": {"pv": "priority", "en": 1},    // priority, only
  "Oafspeed": {"pv": "0", "en": 1},          // AF speed 0-7
  "Ofguide": {"pv": "on", "en": 1},          // Focus guide
  "afctrlen": 1,                              // AF control enabled
  "trctrlen": 0,                              // Tracking control
  "tcctrlen": 0,                              // Track cancel control
  "Ofctrl": {"pv": "", "en": 1}              // Focus control state
}
```

### Media Info (`Omedia`)
```json
{
  "Ocfa": {"state": "n", "rtime": -1},       // CFast: n=none, sel=selected
  "Osda": {"state": "sel", "rtime": 120},    // SD A: minutes remaining
  "Osdb": {"state": "n", "rtime": -1}        // SD B
}
```

### Battery Info (`Opower`)
```json
{
  "Obatt": {"percent": "75", "rtime": "120"}  // Battery % and minutes
}
```

---

## Common Property Patterns

All status values follow a pattern:
```json
{"pv": "value", "en": 1}
```
- `pv` = present value
- `en` = enabled (1) or disabled (0)

When `en` is 0, the control is locked/unavailable.

---

## Error Responses

| Response | Meaning |
|----------|---------|
| `{"res":"ok"}` | Success |
| `{"res":"busy"}` | Camera busy, retry |
| `{"res":"errsession"}` | Another client connected |
| `{"res":"failparam"}` | Invalid parameter |
| `{"res":"failid"}` | Invalid ID |
| `{"res":"rootredirect"}` | Redirect to root |

---

## Live View Stream

The live view is MJPEG served from:
```
GET /lv/lv.mjpg
```
Requires authenticated session.

---

## Reading Individual Properties (VERIFIED WORKING)

The `getcurprop` endpoint may return "busy", but individual properties work reliably:

```
GET /api/cam/getprop?r={property_name}
```

### Working Property Names
| Property | Description |
|----------|-------------|
| `wbm` | White balance mode |
| `wbvk` | White balance kelvin |
| `wbvc` | White balance color compensation |
| `av` | Aperture value |
| `avst` | Aperture step |
| `atype` | Aperture display type (F/T) |
| `am` | Iris mode (auto/manual) |
| `gcm` | ISO/Gain mode |
| `gcv` | ISO/Gain value |
| `gcvst` | ISO/Gain step |
| `gcext` | ISO/Gain extended range |
| `ssm` | Shutter mode |
| `ssv` | Shutter value |
| `ssvst` | Shutter step |
| `aesv` | AE shift value |
| `ndv` | ND filter value |
| `ndext` | ND extended range |
| `afm` | AF mode |
| `fpos` | AF position |
| `fdat` | Face detection |
| `faf` | Face AF mode |
| `fsv` | Focus speed |
| `fguide` | Focus guide |

### Response Format
```json
{
  "res": "ok",
  "O{property}": {
    "pv": "current_value",     // Present value
    "en": 1,                   // Enabled (1) or disabled (0)
    "rvn": 10,                 // Number of options
    "rv": ["opt1", "opt2"]     // Array of valid options
  }
}
```

---

## Live View

### Start Live View
```
GET /api/cam/lv?cmd=start&sz=l
```
- `sz` = size: `l` (large), `s` (small)

### Stop Live View
```
GET /api/cam/lv?cmd=stop
```

### Get Live View Frame (JPEG)
```
GET /api/cam/lvgetimg?d={timestamp}
```
- Poll every 100ms for smooth video
- Returns JPEG image

### Touch to Focus (during live view)
```
GET /api/cam/drivelens?xcoord={X}&ycoord={Y}
```
- Coordinates relative to center of frame
- X range: -543 to 543 (DCI) or -511 to 511 (HD)
- Y range: -287 to 287

---

## Usage Notes

1. **Single Client:** Only one Browser Remote session at a time
2. **Polling:** Use `getcurprop` for status polling (returns everything including `rec` field)
3. **Authentication:** Use HTTP Basic Auth with every request
4. **Cookies:** See CRITICAL COOKIE REQUIREMENTS section below - this is essential!
5. **Live View:** Must start LV session for `getcurprop` to return data
6. **Poll Interval:** Camera expects ~1 second between status polls

---

## CRITICAL: Cookie Requirements (The "Busy" Fix)

### The Problem We Solved

For weeks, `getcurprop` returned `{"res":"busy"}` 90%+ of the time when accessed from ESP32 or curl, but worked perfectly in the browser. This made external recording detection impossible.

**Root Cause:** The camera requires **4 specific cookies** to return full data from `getcurprop`. The browser sent all 4, but we were only sending 2.

### Required Cookies

| Cookie | Value | Source | Purpose |
|--------|-------|--------|---------|
| `acid` | Session ID (e.g., `6f55`) | Set by camera on login | Session identifier |
| `authlevel` | `full` | Set by camera on login | Authorization level |
| `brlang` | `0` | **Must add manually** | Browser language setting |
| `productId` | `VNCX02` | **Must add manually** | Camera product identifier |

### The Fix

After login, append the missing cookies:

```c
// After successful login
strcat(camera_cookies, "; brlang=0; productId=VNCX02");
```

### How We Discovered This

1. Camera on main network (10.10.11.36) - could test with curl directly
2. Used curl with only `acid` + `authlevel` cookies → `{"res":"busy"}`
3. Checked browser DevTools → saw 4 cookies being sent
4. Added all 4 cookies to curl → **FULL DATA RETURNED!**

**Working curl command:**
```bash
curl -s -b "acid=6f55; authlevel=full; brlang=0; productId=VNCX02" \
  "http://10.10.11.36/api/cam/getcurprop?seq=1"
```

**Response with correct cookies:**
```json
{
  "res": "ok",
  "seq": 3,
  "com": 6,
  "mode": "ctrl",
  "camid": "C200    ",
  "rec": "stby",           // ← Recording status!
  "tc": "15:32:00.12",     // ← Timecode!
  "Opower": {"Obatt": {"percent": "25", "rtime": "35"}},
  "Omedia": {...},
  "Owbinfo": {...},
  // ... full camera state
}
```

### Where Does productId Come From?

The `productId` cookie value (`VNCX02`) comes from the camera's URL path:
- Camera serves pages from: `/wpd/VNCX02/...`
- This is the Canon C200's internal product identifier
- It's embedded in the URL when you access Browser Remote

### Browser Cookie Analysis (Chrome DevTools)

When examining Chrome's Network tab → Cookies:

| Cookie | Value | Domain | Path |
|--------|-------|--------|------|
| acid | 6f55 | camera IP | / |
| authlevel | full | camera IP | / |
| brlang | 0 | camera IP | / |
| productId | VNCX02 | camera IP | / |

The browser JavaScript sets `brlang` and `productId` cookies automatically. We need to set them manually.

---

## ESP32 Recording Detection

### Current State (WORKING - 2026-02-12)

- ✅ **Dashboard-triggered recording** - Works perfectly
- ✅ **Physical button detection** - NOW WORKS with cookie fix!
- ✅ **`rec` field available** - Returns `"stby"` or `"rec"`
- ✅ **Timecode available** - Returns `"HH:MM:SS.FF"`

### Network Architecture

```
ESP32 (1.1.1.1) <--Ethernet--> Camera (1.1.1.2)
       |
       WiFi
       |
   Dashboard/Companion
```

- **ESP32 Ethernet IP:** 1.1.1.1
- **Camera Ethernet IP:** 1.1.1.2
- Direct Ethernet connection between ESP32 and camera
- ESP32 exposes API over WiFi for external control

### Recording State Detection

The `rec` field in `getcurprop` response indicates recording state:

| `rec` Value | Meaning |
|-------------|---------|
| `stby` | Standby (not recording) |
| `rec` | Recording |
| `sf_stby` | Slow/Fast standby |
| `sf_rec` | Slow/Fast recording |
| `frm_stby` | Frame recording standby |
| `frm_rec` | Frame recording |
| `int_stby` | Interval recording standby |
| `int_rec` | Interval recording |

### ESP32 Detection Logic

```c
cJSON *rec = cJSON_GetObjectItem(json, "rec");
if (rec && cJSON_IsString(rec)) {
    if (strcmp(rec->valuestring, "rec") == 0) {
        camera_recording = true;
    } else if (strcmp(rec->valuestring, "stby") == 0) {
        camera_recording = false;
    }
}
```

### Full getcurprop Response (When Recording)

```json
{
  "res": "ok",
  "seq": 1,
  "com": 1,
  "mode": "ctrl",
  "camid": "C200    ",
  "rec": "rec",
  "extrec": "off",
  "tc": "15:32:20.23",
  "lvactfarea": "hd_80x80",
  "Opower": {
    "Obatt": {"percent": "25", "rtime": "32"}
  },
  "Omedia": {
    "Ocfa": {"state": "n", "rtime": -1},
    "Osda": {"state": "sel", "rtime": 93},
    "Osdb": {"state": "n", "rtime": -1}
  },
  "Owbinfo": {
    "Omode": {"pv": "user1", "en": 1},
    "Oawb": {"kelvinvalue": "non", "ccvalue": "non", "en": 1},
    "Oseta": {"Ovalue": {"kelvinvalue": "5600", "ccvalue": "0", "en": 1}},
    "Osetb": {"Ovalue": {"kelvinvalue": "5600", "ccvalue": "0", "en": 1}},
    "Odaylight": {"kelvinvalue": "5600", "ccvalue": "0", "en": 1},
    "Otungsten": {"kelvinvalue": "3200", "ccvalue": "0", "en": 1},
    "Ouser1": {"kelvinvalue": "4760", "ccvalue": "-2", "en": 1},
    "Oawbhold": {"pv": "off", "en": 1}
  },
  "Ondinfo": {
    "Ovalue": {"pv": "0", "en": 1},
    "Oextrange": {"pv": "on", "en": 1}
  },
  "Oirisinfo": {
    "Omode": {"pv": "---", "en": 0},
    "Ostep": {"pv": "3fine", "en": 1},
    "Ovalue": {"pv": "F2.2", "en": 1},
    "Opushai": {"pv": "stop", "en": 1}
  }
  // ... additional fields truncated
}
```

### Timecode Behavior

- **When recording:** `tc` field shows running timecode (e.g., `"15:32:20.23"`)
- **When stopped:** `tc` field still present with last recorded timecode
- **Format:** `HH:MM:SS.FF` (hours:minutes:seconds.frames)

---

## Session Initialization Sequence

### Complete Login Flow (ESP32)

1. **Login to camera**
   ```
   GET /api/acnt/login
   ```
   Response: `{"res":"ok"}`
   Camera sets: `acid=XXXX; authlevel=full`

2. **Add required cookies manually**
   ```c
   strcat(camera_cookies, "; brlang=0; productId=VNCX02");
   ```
   Full cookie string: `acid=XXXX; authlevel=full; brlang=0; productId=VNCX02`

3. **Start Live View session**
   ```
   GET /api/cam/lv?cmd=start&sz=s
   ```
   Response: `{"res":"ok"}`
   This enables `getcurprop` to return data.

4. **Poll for status**
   ```
   GET /api/cam/getcurprop?seq=0
   ```
   Now returns full camera state including `rec` field!

### Why Live View is Required

Without an active Live View session, `getcurprop` returns minimal data or `{"res":"busy"}`. The camera needs to know a client is actively viewing before it reports full status.

---

## Investigation History

### What We Tried (Before Cookie Discovery)

| Approach | Result | Why It Failed |
|----------|--------|---------------|
| `getcurprop?seq=N` | `{"res":"busy"}` | Missing cookies |
| `getprop?r=rec` | `{"res":"failparam"}` | "rec" is not a property, it's a status field |
| Start LV first | Still busy | Missing cookies |
| Fetch HTML first | Still busy | Missing cookies |
| Different seq values | Still busy | Missing cookies |
| Longer delays | Still busy | Missing cookies |
| Timecode detection | Worked but not ideal | `tc` present even when not recording |

### The Breakthrough (2026-02-12)

1. Moved camera from ESP32 Ethernet to main network (10.10.11.36)
2. Used curl to test directly (no ESP32 in the middle)
3. Compared browser's cookies to our cookies
4. Found browser sends 4 cookies, we sent 2
5. Added missing `brlang=0` and `productId=VNCX02`
6. **getcurprop now returns full data including `rec` field!**

---

## ESP32 Implementation Details

### Cookie Storage

```c
// Session cookies from camera login
static char camera_cookies[256] = "";
```

### Login Function (with Cookie Fix)

```c
static esp_err_t camera_login(void)
{
    // Clear old cookies before login
    camera_cookies[0] = 0;

    char response[512];
    esp_err_t err = camera_request("/api/acnt/login", response, sizeof(response));

    if (err == ESP_OK) {
        cJSON *json = cJSON_Parse(response);
        if (json) {
            cJSON *res = cJSON_GetObjectItem(json, "res");
            if (res && strcmp(res->valuestring, "ok") == 0) {
                camera_logged_in = true;
                cJSON_Delete(json);

                // CRITICAL: Add required cookies for getcurprop to work
                // Without these, camera returns {"res":"busy"}
                if (strlen(camera_cookies) + 30 < sizeof(camera_cookies)) {
                    strcat(camera_cookies, "; brlang=0; productId=VNCX02");
                }

                // Start live view session
                char lv_response[256];
                camera_request("/api/cam/lv?cmd=start&sz=s", lv_response, sizeof(lv_response));

                return ESP_OK;
            }
        }
    }
    return ESP_FAIL;
}
```

### HTTP Request with Cookies

```c
// Add session cookies if we have them
if (strlen(camera_cookies) > 0) {
    esp_http_client_set_header(client, "Cookie", camera_cookies);
}
```

### Recording Detection Function

```c
static void update_recording_state(void)
{
    if (!camera_logged_in) return;

    char path[64];
    char response[1024];

    snprintf(path, sizeof(path), "/api/cam/getcurprop?seq=%d", getcurprop_seq);
    esp_err_t err = camera_request(path, response, sizeof(response));

    if (err != ESP_OK) return;

    cJSON *json = cJSON_Parse(response);
    if (!json) return;

    // Update seq from response
    cJSON *seq = cJSON_GetObjectItem(json, "seq");
    if (seq && cJSON_IsNumber(seq)) {
        getcurprop_seq = seq->valueint;
    }

    // Check for session error
    cJSON *res = cJSON_GetObjectItem(json, "res");
    if (res && cJSON_IsString(res) && strcmp(res->valuestring, "errsession") == 0) {
        camera_logged_in = false;
        cJSON_Delete(json);
        return;
    }

    // Check "rec" field for recording state
    cJSON *rec = cJSON_GetObjectItem(json, "rec");
    bool was_recording = camera_recording;

    if (rec && cJSON_IsString(rec)) {
        if (strcmp(rec->valuestring, "rec") == 0) {
            camera_recording = true;
        } else if (strcmp(rec->valuestring, "stby") == 0) {
            camera_recording = false;
        }
    }

    cJSON_Delete(json);
}
```

---

## ESP32 API Endpoints

### Status Endpoint

```
GET /api/status
```

Response:
```json
{
  "wifi_connected": true,
  "eth_connected": true,
  "camera_connected": true,
  "is_recording": false,
  "wifi_ip": "10.10.11.229",
  "eth_ip": "1.1.1.1",
  "camera_ip": "1.1.1.2"
}
```

### Proxy Endpoint (for Testing)

```
GET /api/proxy/{camera_path}
```

Forwards requests to camera and returns response. Useful for testing camera APIs from a computer.

Example:
```bash
curl "http://10.10.11.229/api/proxy/api/cam/getcurprop?seq=1"
```

---

## Troubleshooting

### `getcurprop` Returns `{"res":"busy"}`

**Cause:** Missing cookies

**Fix:** Ensure all 4 cookies are sent:
- `acid` (from login)
- `authlevel` (from login)
- `brlang=0` (add manually)
- `productId=VNCX02` (add manually)

### `getcurprop` Returns `{"res":"errsession"}`

**Cause:** Another client connected (browser, etc.)

**Fix:** Close other Browser Remote sessions. Only one client at a time.

### Recording State Not Updating

**Causes:**
1. Live View not started
2. Cookies missing
3. Session expired

**Fix:** Re-login and ensure LV session is started.

### Camera Returns 401 Unauthorized

**Cause:** Basic Auth credentials wrong

**Fix:** Check username/password (default: admin/admin)

---

## Key Learnings

1. **Cookies are CRITICAL** - The camera requires specific cookies beyond just session auth
2. **Browser DevTools reveals all** - Compare what browser sends vs. what you send
3. **Live View enables status** - Must start LV session for full `getcurprop` data
4. **`rec` is NOT a property** - It's a status field in `getcurprop`, not queryable via `getprop`
5. **Product ID from URL** - The `VNCX02` value comes from the camera's URL path structure
