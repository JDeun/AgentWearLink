# Five-project source audit continuation: durability, OpenClaw command surface, reconnect (2026-10-31)

## Verified primary-source findings
**Hawky** `src/gateway/delegation-store.ts`, blob `86ebdf65b708757bce0df128f0074078fa0b784a`: `DelegationStore` persists per-owner SHA256-partitioned task snapshots as JSON (temporary file -> rename, mode 0600) and append-only JSONL events (mode 0600), evidence files and audio/image manifests. Path validates task IDs `[a-zA-Z0-9_-]{1,128}`. This **is durable metadata**, unlike PortWorld's examined in-memory runtime. Source docs `docs/realtime-delegation.md` explicitly say restart marks unfinished jobs interrupted and requires explicit retry; no automatic side-effect replay. Distinguish persisted task state from durable execution.

**TurboMeta** `CameraAccess/Services/OpenClaw/OpenClawCommandRouter.swift`, blob `9aa48ce681ecf1db9c6d6f6f73d741f9148fb5e6`: only camera.snap, camera.list, device.status, device.info. `camera.snap` attempts stream start if idle, polls up to 5 sec every 200ms, returns JPEG base64, optional maxWidth resize, bounded quality 0.1–1.0. This is command routing, **not** confirmation that node gateway auth or iOS background camera operation succeeds. No explicit per-command permission check is visible in this router; examine node service and gateway scopes before making security claims. `device.info` uses hard-coded appVersion 1.5.0 and sdkVersion 0.5.0, potentially stale metadata; compare with Info.plist/SDK package.

**OpenVision** `OpenVision/Services/OpenClaw/OpenClawService.swift`, blob `71fefbb7bc5d818d3bd64b1234d0de476985bb55`: network monitor, reconnect backoff claim 12 attempts 1–30s, heartbeat 20s, lifecycle suspension, pending request continuations failed on disconnect/suspend/failed, state transition callbacks. Source inspection of first 9k chars confirms state transitions and handshake invocation; protocol compatibility and reconnect timing need full-file follow-up. Do not confuse restored WebSocket connection with resuming in-flight agent jobs.

**CJ** actual code approval enforcement still outstanding; README assertions not enough.

## Recommendation for AWL
- Adopt a **job lifecycle** contract distinct from a live audio session: queued/running/completed/failed/cancelled/interrupted/superseded, persistent task ID, delivery receipt distinct from completion, explicit retry on uncertain side effects.
- Persist minimal metadata with atomic write + journal and secure filesystem permissions; avoid storing raw audio/images by default.
- Camera tool should use bounded acquisition lease, capability check, authorization, timeout, explicit teardown. Do not keep DAT camera running after snap by accident.
- OpenClaw device identity and command scopes must be validated at gateway boundary; routing switch alone does not authorize actions.
- Reconnect must invalidate stale request continuations, guard generation and re-establish auth before sending media.

## Audit gaps
Full Hawky DelegationService and recovery tests, TurboMeta node authentication/permission and camera teardown, OpenVision handshake and reconnect exact behavior, CJ code-enforced approvals, upstream dependency/license inventory, AWL side-by-side source inspection, hardware battery/locale tests. **Not a completed exhaustive audit.**
