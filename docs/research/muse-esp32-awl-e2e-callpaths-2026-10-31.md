# Muse ESP32 and AWL E2E call-path audit (2026-10-31)

**Evidence class:** static source read. Not a hardware execution, line-coverage result, or complete security proof.

## ESP32 provisioning -> network -> Noise -> command result

1. **BLE ingress and confirmation**: `esp32/main/ble_server.c` `dispatch_command_ex` parses and validates JSON, routes client hello to `link_pairing_handle_client_hello`, decrypts protected commands via `link_pairing_decrypt_command`, routes client finished to `link_pairing_handle_client_finished`, and blocks sensitive setup actions unless confirmed. Asynchronous provisioning job is stamped with `link_pairing_mark_provisioning_active()` generation.
2. **Pairing state**: `esp32/main/link_pairing.c` states IDLE / WAIT_CLIENT_FINISHED / CONFIRM_REQUIRED / READY / PROVISIONING. Session generation and crypto generation distinguish stale BLE work. Pairing, provisioning and client-finished deadlines are independently bounded.
3. **Wi-Fi**: `esp32/main/wifi_mgr.c` explicit initial connect; `WIFI_EVENT_STA_DISCONNECTED` triggers post-association timer reconnect with exponential 1s–60s backoff; reset on success. This does not imply a seamless handover of application-level transactions.
4. **Noise control**: `esp32/main/noise_control.cpp` implements WebSocket upgrade, `noise_handshake`, `identity_request`, command registration and `handle_invoke_request`. Session generation advances on new session; command results use the owning generation.
5. **Tunnel**: `esp32/main/noise_tunnel.cpp` opens stream on session-up, has `noise_tunnel_maybe_reopen`, session-down, packet ingress, TX pumping and keepalive. DMA headroom and contiguous allocation checks prevent unbounded send allocation.
6. **BLE device commands**: `esp32/main/ble_commands.c` `ble_commands_handle` enqueues command jobs stamped with Noise session generation; worker executes `ble_commands_run` and returns via `noise_ctrl_send_command_result(session_generation,request_id,result)`. Session-end enqueues BLE cleanup. This is a useful **stale result fencing** pattern, but not evidence of command authorization by itself.

## AWL end-to-end paths

- **Text/speech**: `Adapters/MetaDAT/Sources/MetaDATDeviceAdapter.swift` emits device events through `Sources/AgentWearLinkCore/AgentWearLinkRuntime.swift` generation-fenced forwarding into `InteractionCoordinator.swift`; coordinator consumes `AgentAdapter.responses(for:)`, sends normalized output to host callback/`InteractionOutputSink`. `OpenClawNativeAgentAdapter.swift` distinguishes logical interaction ID from submission UUID/idempotency key and calls Gateway supervisor recovery.
- **Voice invocation**: `MetaDATVoiceWakeDeviceAdapter.swift` starts an independent invocation listener and delegates event handling to the Meta DAT device adapter. Not a continuous duplex PCM contract.
- **Snapshot**: `VisionCoordinator.swift` checks camera capability and vision agent support, then awaits `SnapshotCapturingDevice.captureSnapshot(interactionID:)` before `VisionAgentAdapter.responses(for: VisionRequest)`. `MetaDATCameraSnapshotController.swift` bounds and fences actual capture.
- **Disconnect/reconnect**: `OpenClawGatewaySupervisor.swift` owns transport generation, watchdog and reconnect coalescing. `AgentWearLinkRuntime.swift` retires lifecycle generations and deactivates coordinator. No proof here that every physical Meta DAT callback or host UI path is wired and fault-tested.

## Security boundary decision
Muse BLE pairing uses generation, confirmation and encrypted provisioning, with signer classification in `pairing_signer_policy.c`. These are distinct from AWL's OpenClaw device identity and Gateway WSS authentication. Do **not** equate BLE pairing confirmation with authenticated manufacturer identity or claim MITM resistance without an attested trust root. The BLE command worker receives Noise-session-stamped commands, but individual action authorization and consent still require separate review.

## Research decisions
- **KEEP**: AWL actor runtime/coordinator and OpenClaw recovery, one-shot Meta DAT vision.
- **REFERENCE**: ESP32 pairing/session generation fencing, bounded Wi-Fi backoff, stale BLE command result prevention, Noise stream allocation caps.
- **EXPERIMENT**: typed device commands and independent realtime voice with fake transport and second concrete adapter.
- **EXCLUDE**: Muse VM/token coupling, wholesale Noise/ESP32 architecture migration, speculative Swift Core rewrite.

## Evidence still required to mark full E2E complete
- Execute AWL tests and trace actual host composition for voice and vision, not merely module-level method presence (#638).
- Confirm exact ESP32 caller chain at runtime with logging and cross-language protocol vectors (#641).
- Inject reconnect during command execution and verify no stale result is admitted (#641/#637).
- Test accepted OpenClaw run after transport retirement and UI output generation fences (#635/#638).
- Obtain real device traces and quantitative metrics (#638).

These are **empirical** gaps with named tests and issues, not grounds to claim the static code paths above are absent.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ble_server.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/link_pairing.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/wifi_mgr.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/noise_control.cpp
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/noise_tunnel.cpp
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ble_commands.c
- https://github.com/JDeun/AgentWearLink/blob/main/Sources/AgentWearLinkCore/AgentWearLinkRuntime.swift
- https://github.com/JDeun/AgentWearLink/blob/main/Sources/AgentWearLinkCore/InteractionCoordinator.swift
- https://github.com/JDeun/AgentWearLink/blob/main/Sources/AgentWearLinkCore/VisionCoordinator.swift
- https://github.com/JDeun/AgentWearLink/blob/main/Sources/AgentWearLinkOpenClaw/OpenClawNativeAgentAdapter.swift
