# Muse ESP32 Main interface and handover audit — 2026-11-25

Refs #643 #641 #639 #637 #634 #635 #660. Same immutable [Muse 1b894f5](https://github.com/facebookincubator/muse-gadget-sdk/tree/1b894f551e64416e2844452ec6056ec56d6a10f1) count-matched historical corpus. Prior [Linux/handover audit](muse-linux-handover-audit-2026-11-25.md) remains historical. This batch adds 62 file-specific reviews (42 headers, 20 implementations) and four targeted large-module records, separately labeled. The file-level notes cover observed declarations/entrypoints/trust/failure paths and selected test evidence; not a line-by-line security certification or complete cross-file reachability. All 66 reviewed files' Apache-2.0 header notices checked at the pinned commit. Asset, transitive dependency and backend/service terms remain independent. No upstream code, binary, credentials or wire constants imported. No firmware operation, hardware access, or independent test execution.

## Cumulative ledger

| Area | File-specific content record | Targeted but not reconciled | Inventory only | Total |
| --- | ---: | ---: | ---: | ---: |
| Linux | 31 | 0 | 0 | 31 |
| ESP32 Main | 64 | 4 | 25 | 93 |
| ESP32 Components | 0 | 0 | 158 | 158 |
| Android | 0 | 0 | 21 | 21 |
| iOS | 0 | 0 | 19 | 19 |
| Total | 95 | 4 | 223 | 322 |

[TSV ledger](muse-runtime-audit-ledger-2026-10-31.tsv) checked against all 322 pinned blob SHA/size values. A header's declaration is evidence of an interface contract, not execution of the corresponding implementation. The cumulative content-record metric is 95/322, not 95 completely audited security/reachability paths. Targeted rows app.c, ble_server.c, link_pairing.c and noise_control.cpp are excluded from that count; finish their full required review before #643 closure.

## Observed handover: provisioning is not capability readiness

| Stage | Pinned source evidence | Boundary |
| --- | --- | --- |
| BLE admission | [ble_server.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_server.c#L315-L492), [link_pairing.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/link_pairing.c#L918-L1010), [link_pairing.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/link_pairing.h#L37-L70) | Confirmation and provisioning advance logical generation. Record-session generation persists across phase changes until keys retire. Worker arguments are freed on startup failure. No assumption that reachable peer owns account. |
| Provisioning owner | [app.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/app.c#L1160-L1253) | Operation gate then validate originating generation; repeat check at network/storage/auth/VM transitions. A callback stale before acquiring ownership cannot wipe a newer setup. |
| Wi-Fi | [wifi_mgr.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/wifi_mgr.c#L151-L195), [connect](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/wifi_mgr.c#L238-L381), [disconnect](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/wifi_mgr.c#L406-L424) | Association/IP are separate; initial retry budget vs post-association bounded-delay recurrent recovery. Explicit disconnect suppresses recovery. Not a blanket automatic retry recommendation. |
| Persisted setup | [app cleanup and commit](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/app.c#L563-L700), [config_store.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/config_store.c#L132-L217) | Generation-gated local setup marker; logical erase with readback. Setup completion does not prove VM registration. |
| VM target | [app.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/app.c#L1013-L1065), [vm_connect.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/vm_connect.h#L54-L79) | Target record owns credential. connect_vm_target returns success when the control task starts, not when link.register ACK is observed. |
| Transport | [noise_control.cpp](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/noise_control.cpp#L2020-L2150) | TLS, WebSocket upgrade, Noise handshake, control stream open and registration send are distinct stages. Generation starts after handshake, not physical identity proof. |
| Capability readiness | [noise_control.cpp](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/noise_control.cpp#L2178-L2211) | Data tunnel opens only after register ACK. A live transport, control registration, and data-plane liveness are separate. |
| Failure and rotation | [noise_upgrade.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/noise_upgrade.h#L118-L157), [app refresh](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/app.c#L876-L1124), [session pump](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/noise_control.cpp#L2290-L2448) | Upgrade auth rejection (401/403) distinct from network error; re-fetch under operation gate, stale results ignored, then teardown and fresh generation. Do not infer live credential rotation proof. |
| Data plane | [noise_tunnel.cpp](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/noise_tunnel.cpp#L232-L369), [tunnel_netif.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/tunnel_netif.c#L107-L267) | Shared session, independent stream keepalive/reopen; bounded pool and queue drops. A stream open or local accepted write is not remote packet delivery. |

**AWL decision:** retain existing scoped OpenClaw grant and readiness models. Do not mark assistant, Speech, snapshot, or target device ready from radio link, task creation, handshake or local write acceptance alone. Use generation-fenced delayed work and explicit typed readiness evidence. #641 still requires independently executed direct cross-language Noise/frame tests and complete caller/feature coverage, not just static source or previous upstream CI.

## Additional reviewed boundaries

| Topic | Evidence | AWL disposition |
| --- | --- | --- |
| State storage | [config_store.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/config_store.c#L31-L65), [clear/readback](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/config_store.c#L132-L217), [wifi_known.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/wifi_known.c#L195-L255) | Encryption feature conditional; refusal to auto-erase on NVS initialization error; distinguish missing/error and verify logical clear. Multi-key writes not proved atomic; preserve AWL Keychain and avoid retaining private credentials. |
| BLE ownership | [ble_client.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_client.h#L19-L51), [ble_central.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_central.c#L128-L181), [probe](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_central.c#L255-L325), [ble_commands.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_commands.h#L55-L72) | Worker and buffer limits; global probe state needs late-callback/generation review. No generic remote radio scan/write API in AWL; bounded authorized test fixture only. |
| Radio sharing | [ble_coex.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_coex.h#L19-L36), [ble_coex.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ble_coex.c#L97-L146) | Board/ESP-IDF-specific scheduler policy, not a CoreBluetooth equivalent or battery measurement. Reference reversible ownership only. |
| Diagnostics | [diagnostic_log.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/diagnostic_log.c#L119-L252), [bug_report.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/bug_report.c#L332-L425) | Bounded PSRAM ring/drop metrics, one report and generation-fenced result; log capture and base64 are not privacy proof. Prefer AWL sanitized categorical reports and explicit operator consent. |
| Voice | [voice_player.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/voice_player.c#L64-L157), [voice_board.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/voice_board.h#L26-L60) | Fixed queue still permits indefinitely repeated writes and begin waits; worker startup failure can leave playback unready. Treat as static risk, not reproduced failure. #634/#635 require independent finite deadline, terminal error and generation fencing. Conditional hardware echo capability is not evidence of Meta glasses AEC/PCM. |
| OTA and factory | [ota.c](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ota.c#L217-L329), [factory_test.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/factory_test.h#L19-L23) | Firmware feature gate, incomplete download abort, marker before boot switch, signature conditional. No permission or reason to add firmware mutation or factory services to AWL. |
| Crypto optimization | [fast_gcm.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/fast_gcm.h#L19-L77), [ghash32.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/ghash32.h#L19-L52) | Board-specific optimized path and explicit key-cache wipe contract; implementation and side-channel proof pending. No custom crypto port. |
| Media/sensors | [image_fetch.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/image_fetch.h#L52-L72), [voice_board.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/voice_board.h#L38-L60), [sensecap_sensors.h](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/esp32/main/sensecap_sensors.h#L17-L32) | One outstanding media fetch, unknown/stale sensor values distinct; header contracts only where implementations pending. Retain explicit snapshot and freshness gates. |

## Test evidence attribution

Read the actual historical [ESP32 host job log](https://github.com/facebookincubator/muse-gadget-sdk/actions/runs/41107906464/job/124242469247) at exact source SHA, previously recorded as 914 tests, OK (3 skipped). Module names/selected executed tests below are evidence of upstream host tests (mixed source assertions and compiled fake/harness tests), not a new AWL run or physical verification. Counts are named successful log lines, not branch/coverage percentages.

| Test module | Successful log lines in selected modules | Evidence |
| --- | ---: | --- |
| test_ble_client | 1 | scripted NimBLE client harness |
| test_ble_coex | 5 | coexistence policy and build guards |
| test_link_config_store | 1 | config store failure semantics |
| test_link_wifi_known | 2 | saved networks and full reset |
| test_link_pairing_signer_policy / transcript / handshake | 4 | signer classification, shared fixture, state transitions |
| test_link_pairing_state_contract | 11 | staged provision and cleanup assertions |
| test_link_ble_lifecycle_contract | 14 | BLE lifecycle contract assertions |
| test_link_noise_session / tunnel / transport_contract | 20 | session generation, pressure, teardown, transport assertions/harness |
| test_link_vm_auth_token_contract | 2 | target-bound VM selection and lint |
| test_link_diagnostic_log / bug_report | 8 | bounded capture, report and source restrictions |
| test_link_ota | 4 | enabled/disabled, registration, boot marker |
| test_ws_mask | 2 | standard masking and caller |
| test_link_reterminal_sht4x / sensecap_sensors | 4 | sensor parser/feature wiring |

Selected module counts sum to 78 named successful log lines; not exhaustive. The host log also confirms endpoint lifecycle. Do not equate a source assertion with an executed physical action. Previous 599/599 per Linux run plus two skipped each, shared vector fixture and direct Python/ESP32 gap remain as documented in the [Linux audit](muse-linux-handover-audit-2026-11-25.md).

## Open findings and owners

- #643: finish the 4 targeted main modules and 25 inventory-only main files, then remaining components and mobile; reconcile actual call graph/test mapping and severity. Header contracts cannot substitute for implementation.
- #641: verify exact BLE ingress/TX and complete reconnect/credential/Noise control caller graph; direct offline Python/C++ Noise conformance, corruption/TTL/out-of-order/duplicate, resource/fuzz and skip attribution. No hardware result.
- #639: verify exact proposed copied-file/dependency and asset/service terms; no copied code selected, no new dependency. File headers are not full redistribution clearance.
- #637/#633: explicit consent, target-bound grants, no generic shell/filesystem/radio/network actions.
- #634/#635: bounded audio wait and stale-generation/terminal delivery tests; #660 separate radio and session readiness.
