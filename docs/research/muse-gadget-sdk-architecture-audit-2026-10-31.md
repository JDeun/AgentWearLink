# Muse Gadget SDK architecture and source audit (2026-10-31)

Status: research only; no code changes, runtime benchmarks, physical device acceptance, or claim of exhaustive line-by-line review.

## Scope and primary sources
- Upstream: https://github.com/facebookincubator/muse-gadget-sdk
- AWL: https://github.com/JDeun/AgentWearLink
- Upstream SDK token terms: https://gadgets.muse.ai/sdk-terms
- AWL ADR: [0001](../adr/0001-core-boundaries.md), [0002](../adr/0002-agent-runtime-owns-intelligence.md)
- Files inspected: Muse `linux/src/musegadget/{link_client,streaming,voice_call,voice_gate,muse_turn,executor,commands,pairing}.py`, `linux/src/musegadget/noise/transport.py`, `esp32/components/muse/{muse_voice_call_core.c,muse_voice_call.h}`, `protocols/VIDEO.md`, README/AGENTS and SDK terms; AWL `Sources/AgentWearLinkCore/{Adapters,Capability,Interaction,InteractionCoordinator,AgentWearLinkRuntime,BoundedAsyncChannel,Vision,InteractionOutputSink,AgentTransport}.swift`, `Sources/AgentWearLinkOpenClaw/OpenClawGatewaySupervisor.swift`, `Adapters/MetaDAT/Sources/{MetaDATVoiceWakeDeviceAdapter,MetaDATCameraSnapshotController}.swift`.
- Repository trees inspected: AWL 263 blobs, Muse 1096 blobs at time of research. This is a selective source audit, NOT all-file audit.

## Architectural distinction
Muse: Linux/ESP32 gadget pairs to Muse phone app, maintains encrypted session with Muse VM, advertises device commands and handles `link.invoke`/`link.result`. AWL: wearable events through iPhone Meta DAT to independently hosted OpenClaw via transport, host-owned output. Media direction and trust domains differ; copying Muse architecture wholesale is inappropriate.

## Evidence and comparison
| Area | Muse evidence | AWL evidence | Disposition |
|---|---|---|---|
| Device action | `executor.py`, `commands.py`: schema-registered shell/file/drop-in commands; separate run-as account, child processes, 120s default/600s max timeout, 96KiB output limit | `Adapters.swift`: `DeviceAdapter` exposes connect/disconnect/events only | Candidate *opt-in* typed action contract, least-privilege authorization; no unrestricted shell default |
| Streaming | `streaming.py`: dual byte/chunk limits (2MiB/256 default), 64KiB sends, explicit reset/cancel | `BoundedAsyncChannel.swift`: O(1) ring, drop-oldest; `AgentAdapter.responses` contract requires overload error rather than silent response loss | Audit each usage for delivery semantics; preserve lossless control and explicit failure |
| Runtime concurrency | `link_client.py`: 4 concurrent invokes, 60s request timeout, 20s handshake timeout | `InteractionCoordinator.swift`: 8 in-flight interactions, generation ownership and serialized output | Do not replace existing coordinator; benchmark workload before tuning |
| Voice | `voice_call.py`: 24kHz PCM16LE frames, 45s idle, 300s overall, bounded turn tracking; `voice_gate.py`: provider-ID lineage gate, stale audio suppression | `MetaDATVoiceWakeDeviceAdapter.swift`: voice invocation + final transcript, not duplex PCM call | Separate realtime voice experiment, do not claim existing Meta DAT supports it |
| Voice ESP32 | `muse_voice_call_core.c`: OPENING/CONNECTING/LIVE/ENDING/IDLE, playback gate, session identity readiness | AWL event/interaction generations and Meta DAT activation fences | Test stale audio, interruption, shutdown and reconnect before any port |
| Camera | `protocols/VIDEO.md`: phone-to-gadget video with credit/backpressure and frame drop | `MetaDATCameraSnapshotController.swift`: bounded intentional one-shot, default 5s, generation fencing, cancellation; `Vision.swift`: 5MiB image cap | Keep snapshot path; streaming video is separate out-of-scope product decision |
| Capabilities | Muse command specs and audio format metadata | `Capability.swift`: UInt16 OptionSet, currently seven capabilities; device speaker/text bits reserved until callable | Explore optional versioned descriptor only when second adapter needs it |
| Trust | `pairing.py`: community P-256 ECDH/HKDF/AES-GCM, explicitly lacks authenticated peer/active-MITM protection; Noise XX transport | AWL OpenClaw device identity, challenge-bound proof, WSS, reconnect supervisor | Separate authentication, authorization and pairing; avoid duplicate Noise layer without threat-model justification |
| Recovery | `muse_turn.py`: ack-before-event holding, replay scope, bounded lineage; `voice_call.py`: cleanup deadlines | AWL interaction IDs, cancellation outcome uncertainty and OpenClaw accepted-run recovery | Add adversarial contract tests; never silently replay accepted mutations |
| Distribution | SDK Apache-2.0 with separately licensed dependencies; SDK token terms personal/non-commercial and service can be withdrawn | AWL independent of Muse service | Reuse patterns or appropriately licensed files only; no Muse token/backend dependency |

## Important qualifications
- Muse Linux `executor.py` explicitly drops execution to a separately configured unprivileged run-as account, not the credential-owning service account; actual privilege depends on account/sudo configuration.
- Muse `voice_gate.py` documents ambiguity for lineage-free audio after a confirmed turn. Do not assert perfect response attribution.
- AWL `BoundedAsyncChannel` drops oldest by design; that alone is not proof of silent loss in response transports. Inspect concrete producers/consumers.
- The Meta DAT snapshot wrapper intentionally does not advertise camera snapshot capability in voice-wake mode.
- Upstream video is generally phone→gadget, unlike AWL's wearable→agent snapshot path.
- Upstream ESP32 development signing key and disabled secure boot are development defaults, not production security guarantees.
- Apache-2.0 SDK source does not grant rights to Muse cloud, tokens, or third-party assets; SDK token terms prohibit commercial token-based deployments without separate permission.

## Decisions
1. Retain Swift actor Core and existing device/agent boundaries.
2. Do not introduce speculative generic planes into Core without a second working adapter.
3. Investigate typed `DeviceAction` with explicit user/device consent, capability check, timeout, idempotency classification, result bounds, and deny-by-default authorization.
4. Prototype independent `RealtimeVoiceSession` with call/turn/response lineage, duplex and echo policy, interruption and bounded cleanup; do not couple to existing one-shot snapshot.
5. Prototype optional `CapabilityDescriptor` / negotiation only alongside two distinct adapters.
6. Preserve transport-independent semantics while avoiding duplicate security stacks.

## Validation backlog / stop conditions
- Action contract: fake device + second adapter PoC; schema validation, permission revocation, duplicate command, cancellation uncertainty, disconnect.
- Voice: synthetic provider event replay, late/stale audio, missing lineage, barge-in, bounded queues, timeout, remote shutdown, audio privacy.
- Transport: loss/reordering/reconnect/accepted-mutation non-replay, bytes+chunks budgets, memory ceilings and task cleanup.
- Hardware: Ray-Ban Meta+iPhone locked/foreground and tailnet acceptance; separate ESP32/Linux device trial where legally feasible.
- Security: threat model for BLE pairing, device commands, token storage, transport, local privilege and user confirmation.
- Performance: latency P50/P95/P99, memory, CPU, power on named hardware, reproducible workloads; no fabricated target metrics.
- Licensing: per-file SPDX/dependency review before any copying.
- Stop *literature review* once every above question has a source or explicit evidence gap; remaining work is implementation and empirical verification. No claim that every upstream file was examined.

## References
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/AGENTS.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/streaming.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/voice_call.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/voice_gate.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/executor.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_voice_call_core.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/protocols/VIDEO.md
- https://gadgets.muse.ai/sdk-terms
