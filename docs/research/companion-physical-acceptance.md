# Companion physical acceptance handoff

This is a **user-operated checklist**, not evidence of a test run. First pass code/Release/simulator/MockDeviceKit CI for #632 and #677; record whether app and adapter use the same exact DAT pin. Keep the old reference host until app acceptance; do not remove its mock gates. Use only owned devices and authorized private Gateway; use a dedicated test session and harmless prompts. Do not submit tokens, media, transcript text, account data, private endpoints or private keys in logs.

## Test inventory and stages

Record AWL commit, DAT SDK SHA, Xcode/iOS versions, glasses model/firmware, Meta AI version, release channel, OpenClaw commit/version, phone state, audio route and network class. Report PASS / FAIL / BLOCKED / NOT RUN for each row; simulator and hardware never interchangeable.

| Gate | Test | Issue |
| --- | --- | --- |
| Physical baseline | Official CameraAccess unchanged; registration/permissions, camera preview/photo, foreground/background, fold/unfold, doff/redon and link loss | #1 #98 #3 |
| Tailnet | Health; first pairing and manual approval; stored Keychain reconnect; reread scopes; dedicated text turn and incremental output/terminal; >30 s reply; Wi-Fi/cellular; uncertain request not replayed | #56 #97 #117 #118 |
| Speech | Confirm actual glasses input and output routes; Korean spoken turn; no phone fallback mislabeled; partial/final dedupe; missing stopped event (~60s), sustained silence and doff/redon; bounded recovery | #5 #651 #650 #646 |
| Invocation | Native supported launch from screen unlocked, locked, pocketed, idle/music/call; record eligibility, ack, first audio and recovery; compare manual fallback; separate custom wake from Hey Meta routing | #6 #649 #655 |
| Vision | Explicit default still capture; opt-in standalone only if permitted; permission, overlap, cancel, link loss, timeout, stale bytes, memory and no retention | #58 #303 #646 |
| Reliability | Gateway restart and Mac sleep; network loss; rapid invoke/cancel/reinvoke; no mutation replay; no secrets/media in diagnostics | #59 |
| Power | Idle, short listening, Speech, HFP/KWS, music, camera combinations; >=3 trials/config with same firmware, record battery/hour, thermal, p50/p95 and false accepts/misses | #658 #657 |

## Companion-specific software and release gates

- Release build and unit/UI fixture tests pass; debug preview switches and mock dependencies do not leak into shipping app.
- Keep-alive and background modes must have user-visible, bounded behavior and documented distribution eligibility. Silent audio is a review risk, not production proof. No default all-day microphone/camera; stop on cancel, link loss, authorization revocation, and explicit stop.
- UI must distinguish transport connected vs actual device/session/agent readiness, and surface typed failures rather than showing false ready.
- Maintain same SDK pin across integration and app project; inspect actual built Info.plist for unified Analytics.OptOut on 1.1.0; no secrets in git or diagnostics.
- Existing October smoke is reusable history, not a current revision pass. Record sanitized metrics only; mark deferred capabilities with rationale rather than treating missing hardware as success.

Related: [October field log](validation-log-2026-10.md), [November refresh](meta-dat-visor-companion-followup-2026-11-24.md), [Meta validation](../meta-dat-validation.md), [deployment runbook](../p0b-openclaw-validation.md), [reliability matrix](../reliability-matrix.md).
