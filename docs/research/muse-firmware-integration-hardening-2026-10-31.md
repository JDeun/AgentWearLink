# Muse Gadget SDK: concrete firmware integration and production hardening audit (2026-10-31)

**Scope:** static source and official upstream README/AGENTS inspection; no hardware execution. Complements the architecture and call-path research in PR #640.

## Concrete setup and handover wiring

1. `esp32/main/ble_server.c:312+` `dispatch_command_ex` routes pairing hello/finished, decrypts protected setup actions, checks confirmation and launches generation-stamped provisioning work.
2. `esp32/main/app.c:1177-1237` provisioning checks `link_pairing_provisioning_session_valid`, announces Wi-Fi connecting, calls `wifi_mgr_connect`, sets Noise host and proceeds through auth status. `app.c:682-704` commits provisioning with `link_pairing_commit_provisioning` and then either transitions persistent BLE advertising/coexistence or performs `ble_server_full_shutdown`.
3. `esp32/main/app.c:1025` invokes `noise_ctrl_connect(vm_id, auth_token, network_ssid)`. `esp32/main/noise_control.cpp:2522+` owns connection task; `noise_control.cpp:771+` handles Noise handshake and `noise_control.cpp:2102+` increments session generation. `noise_tunnel.cpp` manages a separately reopened data stream.
4. `esp32/main/noise_control.cpp:1726+` handles inbound device invokes and queues generation-bound results; `esp32/main/ble_commands.c:878+` queues BLE command worker with the Noise session generation, returning through `noise_ctrl_send_command_result`.
5. Wi-Fi association loss is handled in `esp32/main/wifi_mgr.c` with 1–60s exponential reconnect. **No guarantee of transaction continuity** follows merely from reconnection.

## Operational caveats directly documented upstream

- ESP-IDF **v6.0.1** pinned for the ordinary ESP32 firmware; some special boards require a distinct vendor pin. Avoid generalizing a single toolchain across all targets.
- BLE is normally shut down and memory reclaimed after setup. `CONFIG_HOMEHUB_BLE_PERSISTENT` retains it and costs approximately **40KiB internal RAM**; coexistence tuning uses private ESP-IDF internals and is version fragile.
- PSRAM-less devices may lack home-network tunnel and video/voice features; capabilities are board- and build-specific.
- SDK token required for Muse pairing; Muse's VM, token refresh and service terms are **not portable** to AWL/OpenClaw.
- Default builds use a **development signing key**, Secure Boot off; Wi-Fi and device tokens may be exposed in unencrypted NVS. Production deployments need a separate hardened security profile, provisioning and rotation policy.
- Community pairing requires physical confirmation and encrypted session but **does not authenticate manufacturer identity or defeat active MITM**.
- Host tests compile firmware C/C++ against fakes. Some real-crypto tests skip without host Mbed TLS or IDF_PATH; a passing suite with skips is not full crypto evidence.
- Video decode, BLE coexistence and radio power consumption need board-level measurements. Firmware power diagnostic figures are **not** production application profiles.

## Implications for AgentWearLink

| Pattern | Decision | Reason |
|---|---|---|
| Explicit BLE→Wi-Fi→Noise lifecycle and generation-bound callbacks | REFERENCE | Reusable invariants for a future ESP32 adapter; no Muse backend dependence |
| Persistent BLE + Wi-Fi | CONDITIONAL | ~40KiB RAM and airtime trade-off; advertise only when measured |
| Per-board/build capability descriptor | PROTOTYPE (#636) | Better than device-type assumptions; second adapter (#642) can validate |
| Typed BLE command execution | PROTOTYPE (#633) | Requires permission and threat model (#637), not broad remote shell |
| Noise VM and Muse token rotation | EXCLUDE | Vendor-specific credentials, protocol and service |
| Secure boot / encrypted NVS / update policy | REQUIRED FOR PRODUCT PROFILE (#637) | Upstream defaults are development-friendly, not production-secure |
| Board-specific audio/video and power benchmarking | TEST (#638/#641) | Hardware and compiler configurations affect outcomes |

## Acceptance evidence still outstanding
- Hardware trace of provision/confirm/connect/reconnect and command results with packet loss.
- Protocol fuzz/interop vector runs and skip-aware test reports.
- End-to-end AWL runtime tests and physical device evidence.
- Concrete security test for provisioning MITM, credential extraction, firmware authenticity and stale commands.

**Research boundary:** This closes the major static call-path *map* with concrete call sites. It does not close hardware conformance or an exhaustive all-branches audit. Track via #633–#639 and #641.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/README.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/AGENTS.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/app.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ble_server.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/noise_control.cpp
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ble_commands.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/wifi_mgr.c
