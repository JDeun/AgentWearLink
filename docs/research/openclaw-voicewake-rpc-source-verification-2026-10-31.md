# Verified OpenClaw Voice Wake RPC surface (2026-10-31)

## Source-level verification
- `src/gateway/server-methods/voicewake-routing.ts` blob `9a18e4df3cc697fc6d993ef81d2d87c0c483746d`: exports only `voicewake.routing.get`, returns `{config: await loadVoiceWakeRoutingConfig()}`. No routing setter.
- `src/gateway/server-methods/voicewake.ts` blob `72ca0e91e59716972db5d74208967dff273d0a92`: `voicewake.get` and `voicewake.set`; set validates `triggers: string[]`, normalizes, persists before broadcasting `voicewake.changed`.
- `src/gateway/methods/core-descriptors.ts` blob `852432d87eecbd5d68bb73b5435f23daa8862377`: `voicewake.get` requires `operator.read`, `voicewake.set` requires `operator.write`, `voicewake.routing.get` requires `operator.read`; `voicewake.routing.set` absent. Descriptor vintage `<=2026.7` is metadata, not proof of runtime installed version.
- `packages/gateway-protocol/CHANGELOG.md` blob `d8a0ef772be7c07d9dec5491c64ef591e9518338`: `voicewake.routing.set` removed in August 2026.
- Official docs `docs/nodes/voicewake.md` still mention routing setter; treat as stale relative to source.

## Integration contract
Supported in inspected main-branch source: read trigger list; write trigger list (operator.write); read routing config. **Do not call routing.set**. Treat trigger changes as Gateway-global and propagate changes to all clients; avoid surprising changes from a local AWL settings page.

## Remaining proof obligations
Confirm pinned OpenClaw CI version in AWL workflows, live gateway handshake and permissions, events and behavior on legacy versions, routing replacement path (if any). No actual gateway invocation performed.
