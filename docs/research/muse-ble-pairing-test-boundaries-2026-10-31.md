# Muse BLE ingress and cross-language pairing test audit (2026-10-31)

## Verified call path (source locations)
- ESP32 `esp32/main/ble_server.c:620+` GATT RX write callback -> chunk handling -> `dispatch_command_ex` (:312); TX is READ/NOTIFY, and `gap_event_cb` (:880) records subscribe and MTU, resets pairing on disconnect.
- `dispatch_command_ex` accepts plaintext `pairing_client_hello` only before setup, routes `pairing_encrypted` to `link_pairing_decrypt_command` and recursively dispatches decrypted payload; `pairing_client_finished` is an exact-first-record condition and confirmation is required for sensitive setup.
- Encrypted status and TX chunks are generation-fenced; `notify_payload` requires subscription and live connection. BLE link/SMP connection and Home Link application pairing are **different** boundaries. Upstream issue #50 documents an observed connected/MTU-but-no-client-hello stall; do not misdiagnose as SMP failure.

## Tests: concrete, classified
- `linux/tests/test_pairing.py` (447 lines): pairing v5 published JSON vectors, transcript/key schedule, invalid hello, replayed or skipped record counter, tampered ciphertext, wrong session, short tag, timeout (60s client finished, 120s confirmed), stale generation and provisioning commit.
- `esp32/tests/test_link_pairing_handshake.py` (127 lines): compiles firmware pairing implementation against **real host crypto** and checks transitions; skips if neither `IDF_PATH` nor `MBEDTLS_SOURCE_DIR` is present.
- `linux/tests/test_link_client.py` (1,244 lines): in-process Noise XX fake VM exercises registration, invoke, result, unpair, invalid control stream, split frames, image and voice-note chunking, TTS/subscription, backpressure, cancellation and slot release, reconnect waiting for disconnected commands. This is substantially stronger than source-string-only tests but still not a physical BLE+TLS device run.
- ESP32 `test_link_encrypted_pairing_contract.py` includes source-order assertions; these are useful regression gates but do not validate actual BLE behavior.

## Static gap and AWL relevance
1. **Transport readiness ≠ authenticated application readiness**. Add explicit state boundaries in any future AWL BLE adapter; relate to #636 and #637.
2. Pairing v5 protocol vectors provide an example of cross-language contract conformance. If AWL implements a second BLE adapter, use vectors and negative cases, not just happy-path mocks (#641).
3. Runtime reconnection and task cancellation must be tested against real transport fault injection (#635/#638).
4. The upstream Android phone-app pairing stall is not evidence of an AWL bug. It demonstrates the necessity of instrumentation between GATT subscription and app-level hello.
5. No upstream source here proves AWL's existing Meta DAT audio and OpenClaw session are fully wired; retain separate physical E2E gate.

## Research decision
- **REFERENCE** explicit GATT readiness and protocol-pairing states.
- **REFERENCE** pairing v5 cross-language vectors and replay/nonce-negative tests.
- **DO NOT COPY** Muse-specific pairing protocol into Meta DAT or WatchConnectivity; each transport has a different trust model.
- **TEST** second adapter state machine, timeout, cancellation and stale-generation behavior.

## Primary sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ble_server.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/tests/test_link_pairing_handshake.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/tests/test_pairing.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/tests/test_link_client.py
- https://github.com/facebookincubator/muse-gadget-sdk/issues/50
