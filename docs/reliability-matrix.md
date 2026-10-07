# Reliability validation matrix

This matrix separates deterministic CI coverage from checks that require the iOS host,
Meta Wearables DAT, physical glasses, or a live OpenClaw deployment.

| Failure mode | Automated invariant | Manual / hardware check |
| --- | --- | --- |
| Device disconnect | Runtime cancels active interactions on stop; connect-time events subscribed before connect (#63) | Disconnect/reconnect Ray-Ban during interaction |
| Agent reconnect | Supervisor reconnect tests; no silent request replay | Restart Mac mini OpenClaw Gateway during request |
| Network transition | Representative reconnect transitions are deterministic-tested; non-ready transport cannot send and uncertain work is not replayed | Move iPhone Wi-Fi ↔ cellular/Tailnet and record recovery |
| Duplicate request | Coordinator suppresses active duplicate ID; inactive terminal events do not emit aborts (#65) | Repeat invocation during active response |
| Late terminal data | Deltas after terminal response are ignored | Interrupt TTS while stream is finishing |
| Cross-session response | Mismatched response ID cancels run and fails original interaction | N/A |
| Cancellation race | Generation-scoped coordinator/HTTP state | Rapid invoke/cancel/reinvoke |
| Media bounds | Image attachment enforces configured byte limit | Oversized DAT snapshot handling |
| Camera privacy | Vision requires explicit snapshot call and capability | Verify no capture before explicit interaction |
| Camera stream heap growth (pinned DAT) | One-shot photo capture now stops and releases the owning Camera on every completion/error/cancellation, not merely its Stream (#303); generation fencing prevents late cross-capture reuse | Profile actual retained heap on target iPhone; vendor internal allocation may persist even after Camera.stop() |
| Media retention | Core values are in-memory only; no persistence API | Inspect iOS host caches/logs |
| Credentials | Secret-sentinel regression plus redacted OpenClaw configuration diagnostics | Verify Keychain credential reuse/rotation/revocation in deployment |
| Background state | Meta code-side invalidation/fresh-readiness policy is deterministic-tested | Lock/pocket physical iPhone and exercise invocation/recovery |
| TTS interruption | Apple output replacement/interrupt tests; bounded pending speech (#61) | Interrupt spoken response repeatedly |

## Replay rule

AgentWearLink must never silently replay a request after a transport failure when the
request may have reached the agent. Reconnect restores transport availability only.
A new interaction requires an explicit new device event or user action.

## Hardware evidence

For hardware-only rows, record iOS version, DAT SDK version, glasses model/firmware,
OpenClaw version, Tailnet path, observed latency, and the exact reproduction steps.


## Current validation split

The deterministic rows above are expected to remain green in CI. Meta DAT additionally has a pinned SDK compile gate and an app-hosted MockDeviceKit simulator/XCUITest gate; neither substitutes for the physical column. Deployment-only
validation is tracked separately so code completion is not confused with hardware
evidence:

- #56 — iPhone/Tailnet/OpenClaw mutating text E2E
- #58 — physical DAT snapshot to vision-agent E2E
- #59 — physical reliability/privacy/recovery sweep
- #5 — wearable audio to native Apple TTS/audio E2E
- #6 — hands-free DAT voice invocation

The read-only `awl-openclaw-probe` validates reachability/authentication. The
explicitly mutating `awl-openclaw-chat-probe` validates P0-B text submission and
streaming and must not be automatically retried after uncertain transport failure.

## Pinned Meta DAT camera heap risk (#303)

The source-level mitigation for photo-only operation is to allocate a fresh
camera owner for each explicit capture and retire **both** the Stream and Camera
on success, timeout, error, cancellation, and session teardown. This avoids
keeping long-lived AWL media ownership between still photos but cannot prove
that the pinned vendor SDK releases allocations internally. Do not enable
continuous raw-audio/camera streaming solely based on this mitigation. Memory
profiling on a physical iPhone and upstream #324 status remain required.
