# OpenClaw first-party iOS Voice Wake and AWL integration boundary (2026-10-31)

## Primary references
- https://github.com/openclaw/openclaw/blob/main/docs/nodes/voicewake.md
- https://docs.openclaw.ai/nodes/voicewake
- https://github.com/openclaw/openclaw/blob/main/docs/platforms/ios.md
- AWL README.md blob `9042deb7e9ed0ff2b6a044287ac7f95a27efe23a`, docs/architecture.md blob `6a2269fd9ed181ca8d1ffa17d73c7f967b830ab5`.

## New finding
OpenClaw already owns a global wake trigger list and trigger-to-agent/session routing. Current docs specify Gateway methods `voicewake.get`, `voicewake.set`, `voicewake.routing.get`, `voicewake.routing.set`, and events `voicewake.changed`, `voicewake.routing.changed`; state stored in Gateway SQLite under `config_machine_state` keys `voicewake.triggers` and `voicewake.routing`. iOS supports local voice wake and Siri Shortcut for starting live voice, subject to foreground/unlock/background audio restrictions. This is **iPhone-based detection**, not evidence of native Meta glasses DSP wake. Native iOS app requirements in current upstream docs differ from AWL's iOS 17+ library minimum; do not conflate product requirements.

## Architectural recommendation
AWL should not independently replicate OpenClaw's wake word persistence or routing semantics. Provide optional, version-negotiated OpenClaw wake-config adapter where useful; maintain vendor-neutral `voiceInvocation` event and `WakeSource` classification (glasses-native, phone-local, Siri/manual) and a distinct idle audio/battery lease policy. Gate calls by supported Gateway protocol version and read/write scopes; do not infer compatibility from docs alone.

AWL already implements Gateway pairing, grant reuse/revocation, stream and abort contract tests per README; compare code before proposing duplicate features. Existing architecture prohibits uncertain mutation replay, secret logging, and continuous camera by default. Physical Meta + iPhone + Mac Tailnet acceptance remains outstanding.

## Additional audit risk
OpenClaw global wake routing changes affect all clients. Editing wake phrases in AWL UI could unexpectedly change other nodes. Require clear UI scope/confirmation and handle event-driven consistency, permission failures, normalization and route conflicts.

## Follow-up validation
1. Fetch OpenClaw protocol schemas and exact RPC permissions for wake methods and events.
2. Inspect AWL existing Gateway client to establish whether wake methods already supported.
3. Test a disposable Gateway with multiple nodes for changed/routing events and rejected scopes.
4. Check actual iOS foreground/background recognition path and battery on RW4006.
5. Verify no regression in current AWL gateway auth tests.

No implementation, runtime or hardware validation performed in this research pass.
