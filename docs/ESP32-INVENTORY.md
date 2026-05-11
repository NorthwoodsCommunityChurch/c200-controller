# ESP32 Bridge Board Inventory

Hardware inventory for the ESP32-S3-ETH boards bridging Canon C200 cameras to the C200 Controller dashboard. Source of truth for MAC addresses, current production WiFi IPs, and TSL index assignments.

The boards aren't SSH-accessible — they're bare microcontrollers running custom firmware — so they don't appear in `VS Code/SSH-ACCESS.md`. This doc is their inventory.

---

## Production Boards (Northwoods main sanctuary)

All five boards run firmware **1.2.0** (TSL listener, NVS config). All share the Espressif OUI prefix `3C:0F:02`; the last three bytes uniquely identify each board.

| Camera | WiFi IP (DHCP) | MAC | TSL index | Position # |
|--------|----------------|-----|-----------|------------|
| Cam 1  | `10.11.4.92`   | `3C:0F:02:DE:F7:54` | 1 | 1 |
| Cam 2  | `10.11.4.11`   | `3C:0F:02:DE:E3:48` | 2 | 2 |
| Cam 3  | `10.11.4.86`   | `3C:0F:02:DE:EC:A4` | 3 | 3 |
| Cam 4  | `10.11.4.82`   | `3C:0F:02:DE:EE:90` | 4 | 4 |
| Cam 5  | `10.11.4.81`   | `3C:0F:02:DE:DA:58` | 5 | 5 |

**Ethernet side** (camera subnet, static): every board uses `1.1.1.1` for its own Ethernet IP and reaches the Canon C200 at `1.1.1.2`. The Ethernet subnet is isolated from the production network.

---

## Network Configuration

**WiFi (production network):**
- SSID: `Northwoods - Production`
- DHCP-assigned IPv4
- Modem-sleep disabled (`WIFI_PS_NONE`) for stable RTT in a packed sanctuary
- Reconnects forever; if WiFi is down >30 s while Ethernet stays up, the board self-reboots

**TSL feed (from Ross Ultrix Carbonite):**
- TCP, port 5200 (configurable per board via WS `tsl_config` message from the dashboard)
- Ross must be configured with one TSL output per destination — five boards plus the director Mac (`10.11.1.104`) — six outputs total

---

## Finding a board if its IP changed

Bonjour/mDNS is unreliable on the production network (see `VS Code/SSH-ACCESS.md`). To find a board after a DHCP renewal:

1. Locate the board's MAC in the table above.
2. Ping-sweep the production subnet from any reachable Mac, then look up the MAC in the ARP table:
   ```bash
   for i in $(seq 1 254); do ping -c 1 -W 100 10.11.4.$i > /dev/null 2>&1 & done; wait
   arp -an | grep -i 'MAC_LAST_THREE_BYTES'
   ```
3. Update this doc once you have the new IP. (DHCP leases tend to be sticky, but a router reset or extended power-off will reshuffle them.)

If a board is fully offline (no ARP response, no `/api/status`):
- Check the OLED — boards with WiFi up but Canon API broken still light up
- Check the Ethernet cable to the Canon
- Power-cycle (5 s off, then on) — fixes most stuck states

---

## Firmware OTA

Firmware updates land via the dashboard's Firmware Update sheet (⌘⇧U). The dashboard:
1. Lists discovered boards with their current firmware version
2. Bundles the latest firmware binary at app build time (`c200_bridge.bin`)
3. Serves it over a temporary HTTP server; boards download via `/api/ota/update`

Boards verify the OTA image (CRC + version) before swap. A failed flash falls back to the previous partition automatically.

---

## Replacement Procedure

If a board needs replacement:

1. **Flash the new board** via USB with the ESP32Flasher GUI app or directly:
   ```bash
   cd ESP32Flasher/FirmwareTemplate
   source ~/esp/esp-idf/export.sh
   idf.py -p /dev/cu.usbmodem2101 flash
   ```
2. **Connect it to the production network** (WiFi credentials are baked into the firmware build).
3. **Auto-discovery** picks up the new board via mDNS on the dashboard.
4. **Reassign** to the correct camera in Tally Settings (⌘⇧T) — pick the right TSL index. The dashboard pushes the config over WS automatically once selected.
5. **Update this doc** with the new MAC.

The old board's MAC entry can stay in this doc with a `(retired)` note, in case the board is repaired and returns to service.

---

## Document History

| Date | Change |
|------|--------|
| 2026-05-11 | Initial creation. Captured MACs from the director Mac's `known_cameras_v2` plist after the v1.2.0 phase 2 rollout. |
