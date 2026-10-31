# OpenClaw Voice Wake protocol drift: documentation versus protocol changelog (2026-10-31)

## Critical finding
Current official docs https://docs.openclaw.ai/nodes/voicewake describe `voicewake.routing.set`, but official source `packages/gateway-protocol/CHANGELOG.md` (blob `d8a0ef772be7c07d9dec5491c64ef591e9518338`) under **2026-08 Removed** explicitly states **`voicewake.routing.set` was removed (#121387)**.

Therefore the prior research claim that AWL can simply call the documented setter is **not verified and likely incompatible with newer Gateway versions**. `voicewake.get`, `voicewake.set`, `voicewake.routing.get`, events and any replacement mutation path must each be verified against the pinned running Gateway and current source/schema before integration. Do not assume an advertised RPC works based on documentation alone.

## Evidence boundaries
- Docs: https://docs.openclaw.ai/nodes/voicewake (retrieved 2026-10-31): global trigger list, get/set, routing get/set, changed events.
- Source: https://github.com/openclaw/openclaw/blob/main/packages/gateway-protocol/CHANGELOG.md: removal in 2026-08.
- AWL `README.md` and `docs/architecture.md`: pre-alpha, existing OpenClaw Gateway contract tests, no physical Meta deployment accepted.

## Required next steps
1. Inspect OpenClaw current `gateway-protocol` method/schema registration and Gateway method handlers; identify replacement for routing mutations if any.
2. Record OpenClaw exact pinned version/commit used in AWL CI and check version skew.
3. Add a disposable-Gateway capability probe: supported methods/permission scopes, unknown-method behavior, event initial snapshot and re-sync.
4. Avoid adding a wake-routing setter until verified. Prefer read-only observation and local wake-source mapping where gateway feature unavailable.
5. Update earlier research note `openclaw-first-party-voicewake-routing-audit-2026-10-31.md` with this superseding caveat.

No code changes or runtime tests performed.
