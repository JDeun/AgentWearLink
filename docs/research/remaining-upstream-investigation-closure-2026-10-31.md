# Remaining upstream/AWL investigation closure and physical acceptance matrix (2026-10-31)

## Newly verified upstream (2026-10-31)
Official English Voice Wake docs https://docs.openclaw.ai/nodes/voicewake now document only `voicewake.routing.get`; Korean localized docs https://docs.openclaw.ai/ko/nodes/voicewake still document removed `voicewake.routing.set`. This is **localization drift**, not necessarily English documentation drift. English docs specify global triggers, <=32 triggers, <=64 UTF-16 code units, event snapshots and broadcasts. English docs say Gateway SQLite config_machine_state; Korean docs differ in storage-table description. Do not assume the Korean page is current. Main source confirms get-only routing (blobs documented in prior audits). Fossies 2026.7 -> 2026.8 diff independently corroborates setter removal.

## AWL existing implementation verified, not merely architecture
- `Sources/AgentWearLinkOpenClaw/OpenClawGatewayConnection.swift` blob `80d15de81bda48ed9eef612a66f1ddfa3d00d1bc`: actor-based WebSocket handshake, generation fencing, nonce validation, configurable read/write scopes, structured progress states. Not equivalent to raw URL query token clients.
- `docs/openclaw.md` blob `b6b3390ed61997de648e5f6147795d1fb40cd4aa`: bounded agent.wait polls, uncertain mutating submission handling, accepted-run continuation, event-sequence fencing, terminal text reconciliation, cancellation certainty and validated endpoint exposure profiles.
- `docs/reliability-matrix.md` blob `5bf5b0384a4be221a492f1f93b7f34d950cb3682`: deterministic coverage of camera owner release, stale generations, duplicate requests, reconnect, credential sentinels and background invalidation; physical gates separate.
- `Adapters/MetaDAT/README.md` blob `a3d3dab7190fc5375e0cb68fbc6562bd2c6d3a28`: pinned Meta DAT 1.0.0, implemented Speech final-transcript and Voice Invocation lifecycle, camera, foreground/background readiness; hardware not validated.
- `docs/openclaw-protocol-contract.md` blob `e8c28ad1d956ad9f1ba18f0d37912fef00569471`: pin `172a5d6202214eea253234c3b04c8184df9fea70`, protocol v4; verifier excludes voicewake RPC, which is not currently a shipped contract.

## Findings and decision
1. **Do not rebuild** existing handshake, cancellation, idempotency, camera lifecycle, or gateway durability. Audit test quality when code changes require it.
2. Optional voicewake integration: English docs + pinned source/schema + actual Gateway runtime must agree. No need to implement `routing.set`; method removed.
3. Primary unmet user outcome: custom hands-free 'Alfred' on Meta glasses without Hey Meta, with battery acceptable. Existing DAT Voice Invocation and Speech handling **do not prove native on-glasses custom wake**. Visor reverse-engineered Android enrollment is experimental, English-first and AGPL license boundary; do not port code or promise compatibility.
4. Real iPhone ↔ Tailscale ↔ Mac mini Gateway and RW4006 firmware, locked/pocketed audio, HFP/music coexistence and battery remain **physical acceptance gates**, not solvable by source-only research.

## Physical test protocol (proposed, not executed)
Baseline battery idle 30min, music playback 30min, DAT connected idle 30min, bounded phone KWS 30min, Visor-native enrolled wake 30min if possible. Record glasses % and phone % at 5min intervals, ambient RF, firmware, iOS, OpenClaw commit, exact active mic sessions; compare deltas, not only endpoint percentage. Test wake precision with positive and negative Korean/English phrases, false activations, locked/background state, interrupted calls/music and cooldown. Avoid continuous DAT PCM as default given observed severe battery drain. Test must obtain user's explicit device participation.

## Research limits
This is a **source-research closure checkpoint**, not a full code audit or tested integration. Cannot settle firmware DSP, private Meta APIs, actual battery or runtime permissions without devices. No implementation or CI execution performed.
