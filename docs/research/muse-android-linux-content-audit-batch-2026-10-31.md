# Muse first-party content review: Android and Linux transport (2026-10-31)

## Content inspected in this pass
Five Android Java sources and five Linux Python sources were fetched and inspected, rather than merely classified by filename.

| Source | Concrete evidence | Review status |
|---|---|---|
| Android `WifiLink.java` | Socket connect timeout 3000ms; synchronized credit counters; reader rejects unexpected protocol type; connector reconnect/close paths | Source inspected; end-to-end tests not run |
| Android `CameraStreamer.java` | Synchronized start/stop; closes capture session, camera, image reader, codec, optional encoders and dump file | Source inspected; race/hardware testing pending |
| Android `VideoLink.java` | Abstract video frame/credits interface | Source inspected |
| Android `ClipStreamer.java` | MediaExtractor/codec lifecycle, start/stop and native encoder closure | Source inspected |
| Android `MainActivity.java` | Runtime CAMERA permission check and denial handling; preview and camera/clip shutdown | Source inspected |
| Linux `ble_server.py` | D-Bus GATT characteristic read/write/notify and advertising; manufacturer paired flag explicitly informational, unauthenticated | Source inspected |
| Linux `ble_setup.py` | Pairing session reset on BLE disconnect; serialized setup commands and provisioning errors | Source inspected |
| Linux `network.py` | Reachability check with 5s timeout; nmcli/wpa_cli subprocess timeout 5s | Source inspected |
| Linux `muse_api.py` | Bearer token VM lookup, 15s HTTP timeout, refresh token rotation and 401 semantics | Source inspected |
| Linux `identity.py` | Stable device identity persisted across unpair/upgrade | Source inspected |

## Review scope and integrity
The path-classified candidate population remains **322 files**, with no discretionary reduction. This document records ten individually retrieved and source-inspected files. The candidate population includes non-code assets and build metadata; each still needs an explicit disposition. Existing research notes inspect other files, but no global unique-file audit ledger has yet been completed.

## Follow-up gates
- Audit remaining Android Java and iOS Swift sources for network/media lifecycle and credential flows.
- Audit remaining Linux modules and tests.
- Audit all ESP32 main, muse component, noise core, camera, board drivers, including oversized generated font assets (classify content as generated binary/table, verify provenance).
- Cross-reference each executable entrypoint with source-level guards and tests.
- No claim of 322/322 review or CI/hardware validation.
