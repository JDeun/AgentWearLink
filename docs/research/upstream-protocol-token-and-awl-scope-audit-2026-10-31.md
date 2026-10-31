# Upstream protocol/security audit and AWL scope reconciliation (2026-10-31)

## Direct code evidence
- TurboMeta `CameraAccess/Services/OpenClaw/OpenClawNodeService.swift` blob `a6b3f285c0663de680badfd10f89c4b1aa711113`: `startConnection()` concatenates `?token=${token}` into WebSocket URL (lines 191-196); connect.challenge nonce received, v3 Ed25519 device signing with `operator.read`/`operator.write` scopes (lines 272-368); max five reconnect attempts with delays 2/4/8/16/30 sec. URL token interpolation is not percent-encoded and query string is a credential-exposure concern; investigate actual gateway logging. Device signing does not replace secure transport and server-side authorization.
- OpenVision `OpenVision/Services/OpenClaw/OpenClawService.swift` blob `71fefbb7bc5d818d3bd64b1234d0de476985bb55`: `buildWebSocketURL` adds `URLQueryItem(name: "token", value: authToken)` around line 332; state machine invalidates pending requests on disconnect/suspend/failed, handshake after WebSocket running. Query token exposure concern remains despite proper URL encoding.
- Hawky `src/gateway/delegation-methods.ts` blob `51e4de286b0d6506f0ec7eec02821acf724860d3`: submit checks previous task ID for owner/session/request identity and rejects conflicting duplicates; persistent task state; owner token and session checks on lookups. Requires tests for concurrent duplicate submissions and task cancellation races.
- AWL `README.md` blob `9042deb7e9ed0ff2b6a044287ac7f95a27efe23a`, `Package.swift` blob `37edbd57940e16d0cece15054825479def35aa94`, `docs/architecture.md` blob `6a2269fd9ed181ca8d1ffa17d73c7f967b830ab5`: project is explicitly **pre-alpha**, modular vendor-neutral Swift I/O adapter, OpenClaw Gateway remains owner of models/tools/memory/task orchestration; WSS over Tailscale Serve reference. It already states uncertain mutations must not be automatically replayed and physical Ray-Ban+iPhone+Mac/Tailnet deployment is unvalidated. Do not expand AWL into an entire backend or duplicate OpenClaw's durable task executor without a demonstrated need.

## Prioritized recommendations
P0: Hardware wake feasibility and battery on RW4006, Korean vs en-US wake enrollment, iOS DAT event routing; no upstream iOS phone-based KWS proves low-power native wake.
P0: Check AWL actual OpenClaw transport token handling, credential logs, gateway challenge/device scopes and request ownership in code/tests. README architecture alone is not implementation verification.
P1: Bound mic/camera acquisition and cleanup, stale callbacks, task generation guards, reconnection, response deduplication and interrupted task reconciliation.
P1: Validate that OpenClaw owns long-lived jobs. AWL should present progress/notifications via adapter rather than replicate Hawky's gateway unless runtime lacks an API.
P2: Evaluate Siri/App Intents as manual fallback, not equivalent to glasses native wake.

## Findings not established
No actual credential leak demonstrated, no test execution or hardware test; no full repository source inventory, license dependency audit, or complete AWL side-by-side code audit. Future audits must reference exact files/commits and avoid equating README features with validated behavior.
