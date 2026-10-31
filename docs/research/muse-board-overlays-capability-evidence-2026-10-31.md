# Muse board overlay and capability evidence audit (2026-10-31)

## Scope
Inspected the complete `esp32/devices` filename inventory (60 blobs), the board support documentation and selected representative Kconfig overlays; **not all 60 file contents were inspected**.

## Evidence
- `esp32/devices/README.md` maintains a board-by-feature matrix, distinguishing checked hardware operation from `Built, not run`, `Enabled (unverified)` and experimental features. Never translate CI firmware build into physical support.
- `esp32/devices/sdkconfig.c6-nopsram`: ESP32-C6 without PSRAM uses internal mbedTLS memory, 4096-byte TLS output, smaller NimBLE pools, and `CONFIG_HOMEHUB_TUNNEL=n`. The comment explains that otherwise BLE provisioning can silently stall under memory pressure.
- `esp32/devices/sdkconfig.muse`: full UI/voice setup uses 16MB flash, PSRAM allocation tuning, BLE MTU 256, NimBLE persistent NVS and OTA enabled.
- `esp32/devices/sdkconfig.muse-video`: phone-to-device video is explicitly opt-in (`CONFIG_MUSE_VIDEO=y`), requires Wi-Fi and mDNS task/buffer allocation from PSRAM.
- `esp32/devices/sdkconfig.muse-sensecap-watcher`: octal PSRAM, external BLE buffers, tickless idle, controller modem sleep and CPU power-down in light sleep. These are board-specific power and memory decisions, not general ESP32 guarantees.
- `esp32/main/Kconfig.projbuild`: persistent BLE has dependency on NimBLE and absence of full Muse UI; default shutdown saves ~40KiB internal RAM. BLE coexistence is chip- and config-dependent. OTA defaults off unless enabled by overlays.
- `esp32/devices/AGENTS.md` cites vendor schematics, driver code and pin mappings; upstream board support is heterogeneous and sometimes relies on vendor-derived source requiring independent license inspection.

## AWL applicability
| Item | Decision | Rationale |
|---|---|---|
| Board-by-feature verification matrix | BORROW methodology (#636/#638) | capability present ≠ tested on hardware |
| PSRAM-specific feature disabling | REFERENCE | constrain per-device capability advertisement and graceful fallback |
| ESP32 board overlays | EXCLUDE direct integration | AWL is vendor-neutral Swift core, not ESP-IDF firmware |
| Vendor BSP licensing | REVIEW (#639) | inspect individual source and binary redistributability before reuse |
| Power measurements and sleep behavior | EXPERIMENT (#638) | board-specific, not extrapolatable to Meta DAT/Apple Watch |

## Static closure status
Inventory complete at filename level; selected representative overlays inspected. Need content-level systematic checks of the remaining board overlays and their compile-time dependencies before any all-files audit claim.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/README.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/AGENTS.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/sdkconfig.c6-nopsram
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/sdkconfig.muse
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/sdkconfig.muse-video
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/devices/sdkconfig.muse-sensecap-watcher
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/Kconfig.projbuild
