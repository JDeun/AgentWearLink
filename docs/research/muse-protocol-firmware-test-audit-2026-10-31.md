# Muse protocol, firmware and test coverage follow-up (2026-10-31)

**Method:** selective read of upstream actual files and test inventory. Findings are source-verified, not runtime-verified. This is not an exhaustive inspection of every upstream implementation file.

## Protocol boundaries and hard limits

| Layer | Source | Observed contract | AWL relevance |
|---|---|---|---|
| BLE chunking | `linux/src/musegadget/ble_framing.py` | magic 0xFE, 3-byte header, ordered chunk indices, 255 chunks max, 8192-byte reassembly cap, 160-byte packet cap, default ATT MTU 23 | If implementing BLE adapter, enforce order, timeout and per-message caps; no reason to impose these on Meta DAT SDK abstraction |
| Noise framing | `linux/src/musegadget/noise/framing.py` | 65,489-byte max payload/chunk, 256 chunks, 16 pending assemblies, 16MiB max assembly, 60s TTL; decoder poisons after malformed input | Potential DoS and memory test reference; not evidence AWL needs another Noise layer |
| Noise transport | `linux/src/musegadget/noise/transport.py` | encrypted request, streaming body chunks, reset with CANCELLED code; service map and framed messages | Compare semantics, not byte-for-byte protocol reuse |
| Service supervision | `linux/src/musegadget/service.py` | exponential reconnect backoff base 2s/cap 60s, healthy session reset at 30s, auth minimum 15s, local input cap 4MiB, token refresh | AWL `OpenClawGatewaySupervisor.swift` already owns reconnect generations/watchdog; compare tests and credential rotation, do not duplicate supervisor |
| Command sandbox | `linux/src/musegadget/commands.py` and `executor.py` | JSON specs, required/optional typed params, no-shell drop-in commands, separate run-as account; shell built-in exists with configured privileges | Prefer typed allowlisted actions, reject unrestricted shell default |
| Voice tests | `linux/tests/test_voice_call.py` | synthetic Noise duplex WAV, cancellation, hangup, speech-start playback flush, response-cancelled != call-end | Port *failure scenarios* to Swift fake transports; not implementation |
| ESP32 link | `esp32/components/muse/muse_link.c` | link state display and Wi-Fi power policy helpers | Not the full BLE/Wi-Fi handover implementation; inspect actual task/transport modules before making handover guarantees |
| ESP32 host tests | `esp32/tests`, `esp32/simulator/tests` | C/C++ harnesses for noise, link, BLE, camera, power; Python simulator scenarios | Test corpus is extensive, but existence of tests does not establish runtime coverage |

## New risks / explicit nonclaims
1. Noise framing's pending-assembly bound is per decoder; do not claim an application-wide memory cap without tracking all sessions.
2. BLE packet cap and maximum assembled message are independent; require both bounds.
3. Token rotation in Muse service is specific to Muse VM and does not imply OpenClaw should rotate its credentials identically.
4. AWL device adapter receives events, not a generic command dispatcher; adding device commands changes trust direction and must require consent/authorization.
5. Voice `response.cancelled` need not mean call terminated. Distinguish media stream, agent turn, and device session lifecycles.
6. Muse `voice_gate.py` explicitly notes unidentifiable lineage-free audio after a confirmed turn; enforce fail-safe policy or record accepted ambiguity.

## Audit gaps requiring experiments or further targeted inspection
- Trace ESP32 BLE→Wi-Fi/Noise handover and credential storage with specific call graph; verify SDK/version and build configurations.
- Cross-language protocol conformance vectors for Python↔ESP32; then independent Swift PoC if AWL requires that protocol.
- Actual per-test execution results, CI platform matrix, coverage instrumentation and fuzzing; test file inventory is not execution evidence.
- OpenClaw accepted-run recovery under disconnect; no silent replay of accepted mutations.
- Hardware latency, battery, background/locked-phone acceptance with reproducible traces.
- Licensing bill of materials for any code actually copied.

## Decision
Stop adding generic protocol abstractions solely on source similarity. Preserve current AWL Swift Core and Meta DAT snapshot; advance through issues #633–#639, with protocol fuzz and test parity as additional acceptance criteria.

## Primary sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/ble_framing.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/noise/framing.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/noise/transport.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/service.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/tests/test_voice_call.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_link.c
