# Muse × AgentWearLink research closure matrix — 2026-10-31

Status: **static architecture research closure**, not empirical validation closure. Every row has source evidence, a decision, and a reproducible follow-up when necessary. This document does **not** claim every upstream file or every AWL E2E branch was line-by-line inspected.

## Evidence-linked functional paths

| Path | Source entrypoints and flow | Decision | Unverified acceptance evidence |
|---|---|---|---|
| AWL interaction | `AgentWearLinkRuntime.swift`: subscribe device events before connection; device-first or agent-first connect; generation-fenced forwarding -> `InteractionCoordinator.swift` -> `AgentAdapter.responses` -> host `InteractionOutputSink.swift` | **Keep**; one device stream to one coordinator | #635: lossless event vs lossy media classification; cancellation/restart races |
| Meta DAT wake | `MetaDATVoiceWakeDeviceAdapter.swift`: enable foreground media activation, independent voice invocation listener; `MetaDATDeviceAdapter.swift`: generation fence, registration and session handling | **Keep** existing foreground workflow | #638: iPhone background/locked-phone physical acceptance |
| Meta DAT snapshot | `MetaDATCameraSnapshotController.swift`: one-shot 5s timeout, cancellation and generation checks; `Vision.swift`: image <=5MiB | **Keep** | #638: actual photo availability and teardown race |
| OpenClaw | `OpenClawNativeAgentAdapter.swift`: separate submission UUID/idempotency key, recovery path; `OpenClawGatewaySupervisor.swift`: transport generation, watchdog and coalesced reconnect | **Keep** | #635/#638: accepted-run recovery and no mutation replay under faults |
| Muse BLE provisioning | `esp32/main/link_pairing.c`: PAIRING_IDLE -> WAIT_CLIENT_FINISHED -> CONFIRM_REQUIRED -> READY -> PROVISIONING, generation and crypto generation fencing; `linux/src/musegadget/ble_framing.py`: bounded in-order framing | **Reference** state and bound patterns, do not port protocol | #641: BLE packet/timeout/fault vectors and full call graph |
| Muse Wi-Fi | `esp32/main/wifi_mgr.c`: Wi-Fi event handler, post-association reconnect backoff 1s–60s, reset on success | **Reference** | #641: hardware roaming and recovery |
| Muse Noise tunnel | `esp32/main/noise_tunnel.cpp`: session up/down, open/reopen, keepalive, TX DMA headroom; `linux/src/musegadget/noise/framing.py`: assembly bounds | **Do not import** unless second adapter requires it | #641: Python↔ESP32 vectors and fuzz |
| Muse Linux service | `linux/src/musegadget/service.py`: leased VM, token rotation, 2s–60s reconnect | **Do not couple** to Muse cloud | #637/#639: auth, service independence and license |
| Muse voice | `linux/src/musegadget/voice_call.py`, `voice_gate.py`, `esp32/components/muse/muse_voice_call_core.c`: bounded audio, provider lineage gate, call lifecycle | **Experiment** separate realtime contract | #634: synthetic stale/late/lineage-free PCM, interrupt, cleanup |
| Muse commands | `linux/src/musegadget/commands.py`, `executor.py`: typed command specs, isolated child process, execution caps | **Experiment** typed deny-by-default action API, no unrestricted shell | #633/#637: authorization, cancellation, idempotency and output limits |
| Capability model | AWL `Capability.swift` OptionSet; `Adapters.swift` minimal device/agent protocols | **Keep** until demonstrated need for richer negotiation | #636: two concrete adapters |
| Licensing | Muse upstream README explicitly lists Apache-2.0 and exceptions including CC0, MIT, BSD, OFL, video decoder and GPL implications for sample test apps | **Reuse ideas first**; review copied files/deps individually | #639: SPDX and dependency bill of materials |

## Three closure gates

1. **Major functional/security source paths identified:** PASS for *architecture-level selected entrypoints*; NOT PASS for all-file/full E2E branch coverage. E2E fault path audits tracked in #635/#638/#641.
2. **Decision for each observed difference:** PASS for the rows above: KEEP, REFERENCE, EXPERIMENT, or DO NOT IMPORT.
3. **Empirical gaps tracked as executable criteria:** PASS as issue specifications #633–#639 and #641. Actual experiments are NOT yet complete.

## Explicitly unverified, not to be inferred
- End-to-end hardware functioning, 24/7 reliability, performance targets, and compatibility across iOS versions.
- All-source-file audit or measured test coverage of either project.
- End-to-end ESP32 pairing→Wi-Fi→Noise exact caller graph and cross-language conformance.
- Commercial licensing approval for Muse service tokens.
- Complete security review or guarantee against active MITM.
- Multi-device/multi-agent production support (current AWL runtime explicitly connects one device event stream to one coordinator).

## Evidence provenance
Research branch docs:
- [Architecture audit](muse-gadget-sdk-architecture-audit-2026-10-31.md)
- [Framing and test audit](muse-protocol-firmware-test-audit-2026-10-31.md)

Follow-up issues: #633 #634 #635 #636 #637 #638 #639 #641.

## Research stop rule
No further *speculative architecture comparison* is needed to select the next implementation PoC. Further static inspection is justified only to close a concrete call graph, vulnerability, or test-coverage gap. Empirical validation remains required; these issue tickets are not evidence that experiments passed.
