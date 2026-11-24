# AWL pinned OpenClaw contract and Voice Wake verification gap (2026-10-31)

## Existing AWL coverage, directly verified
- `docs/openclaw-protocol-contract.md` blob `e8c28ad1d956ad9f1ba18f0d37912fef00569471`: pinned OpenClaw commit `172a5d6202214eea253234c3b04c8184df9fea70`, protocol v4. Records source-subset checks on 2026.9.6, 2026.9.9, 2026.10.1, 2026.10.2 and 2026.10.5-beta.3.
- `scripts/verify-openclaw-protocol-contract.py` blob `73d02d765c6c3d5b4ca18aea719b95ada57623a2`: source files pinned for frames, client-info, agent, chat.abort, device-auth, run-wait, connection. **No Voice Wake handler/descriptor/schema paths**.
- `.github/workflows/swift.yml` blob `f29a13380f034db6b7e9baf2751b67d23dacbc7f`: conditional contract verifier, protocol XCTest shards and other OpenClaw tests; existing broad contract coverage, do not claim all integration is absent.
- `docs/testing.md` blob `9f4e56e8adcfc25acb7e5d969699a494b9d146db`: synthetic Gateway/transport coverage and physical acceptance boundary.

## Upstream Voice Wake current main-branch
- `src/gateway/server-methods/voicewake.ts` blob `72ca0e91e59716972db5d74208967dff273d0a92`: get/set triggers, normalize/persist/broadcast.
- `src/gateway/server-methods/voicewake-routing.ts` blob `9a18e4df3cc697fc6d993ef81d2d87c0c483746d`: routing.get only.
- `src/gateway/methods/core-descriptors.ts` blob `852432d87eecbd5d68bb73b5435f23daa8862377`: get/read, set/write, routing.get/read; routing.set absent.
- Changelog documents removal of routing.set in 2026-08.

## Concrete gap and recommendation
The existing pinned verifier **cannot detect Voice Wake method removal or scope drift**, because it intentionally checks only AWL's shipped protocol subset. This is correct until AWL actually ships Voice Wake RPC. If implemented, extend the same pin/verifier/tests with:
1. Positive method registration and scopes for get/set/routing.get, negative assertion routing.set absent at supported commit.
2. Trigger normalization, persisted-then-broadcast event behavior, read/write scope rejection.
3. Gateway-global setting semantics, multi-client sync, conflict/race and reconnect resync.
4. Versioned capability probe and safe fallback on older/newer Gateway.

Avoid adding speculative Voice Wake support without user-visible workflow and runtime proof. No code modifications or CI runs in this pass.
