# Muse UI chat, local BLE, settings and Watcher camera audit (2026-10-31)

## Source paths inspected
- `esp32/components/muse/muse_chat_session.cpp` (2,437 lines): task-owned HTTP-over-Noise session, bounded mic stream, caption queue, reply audio stream, generation-fenced cancellation; handshake uses bearer token header and Noise message exchange. Generation prevents old-turn audio being emitted as new-turn audio.
- `esp32/components/muse/muse_audio.c` (450 lines): board-selected codec initialization, audio power and gain/volume control, PCM read/write, loopback/self-test. This is a hardware-dependent audio abstraction, not a universal device guarantee.
- `esp32/components/muse/muse_settings.c` (315 lines): NVS-backed token, volume, microphone, sleep and Wi-Fi/BLE settings; on NVS version/no-space errors, initialization erases NVS. Settings token is stored via `nvs_set_str`; whether the partition is encrypted depends on firmware provisioning/configuration, not this function.
- `esp32/components/muse/muse_ble.c` (370 lines): separate phone-setup BLE command handling, including `hatch.token` and Wi-Fi credentials; explicitly checks authenticated **and** encrypted BLE security state for sensitive setup. This is a distinct BLE setup interface from Home Link pairing.
- `esp32/components/muse/boards/watcher_camera.c` (242 lines): SenseCAP Watcher Himax JPEG capture/preview, atomic busy guard, preview frame reuse, PSRAM frame copy, base64 response, camera power lifecycle; failure distinguishes busy, timeout, unavailable and memory exhaustion.

## Security and lifecycle implications
1. Multiple BLE services and pairing models exist within the same firmware: avoid treating all BLE traffic as sharing Home Link cryptographic guarantees.
2. Browser/console/NVS token flows need end-to-end credential confidentiality review. The `muse_ble.c` encrypted+authenticated check is a meaningful guard, but pairing method, key persistence and reset semantics still matter.
3. NVS erase-on-layout-change is an availability/reprovisioning issue; production recovery must distinguish settings reset from user-authorized factory reset.
4. Watcher camera implementation shows **gadget camera -> command result** is supported on at least one board, separate from phone camera -> gadget display video path. Do not infer camera capture is universal.
5. Camera frame copying and base64 amplify PSRAM pressure; bound capture dimensions, encoded result and concurrent preview in any analogous AWL adapter.
6. Muse's UI chat/voice path is separate from the Linux one-shot CLI; audit session teardown per client.

## AWL decisions
| Finding | Decision | Next gate |
|---|---|---|
| Session generation and bounded mic/audio queues | BORROW invariant (#634/#635) | cancellation/late audio negative tests |
| Authenticated BLE settings channel | REFERENCE (#637) | device-specific trust and consent |
| NVS credential storage | EXCLUDE direct reuse | AWL secure storage per OS |
| Watcher camera.capture semantics | REFERENCE (#633/#638) | Meta DAT snapshot path already exists; test permissions, size and timeout |
| Phone video streaming | EXCLUDE direct reuse | opposite direction to AWL camera-to-agent |

## Limits
Selected source implementations inspected statically, no actual firmware flashing, authenticated BLE attack simulation, camera hardware capture or AWL runtime execution. Full repository all-file content audit still open.
