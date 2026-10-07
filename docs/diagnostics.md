# Privacy-preserving diagnostics

The optional `AWLDiagnosticRecorder` is an in-memory, capacity-bounded lifecycle
recorder. Core runtime/coordinator and OpenClaw Gateway supervisor accept the
same recorder; omitting it leaves instrumentation disabled.

- Only `AWLDiagnosticKind`, local `InteractionID`, transport/runtime generation,
  and numeric retry attempt are representable.
- No caller-controlled strings, prompts, transcripts, URLs, session keys,
  secrets, remote run IDs, private media or error descriptions are stored.
- `record` runs synchronously under a short lock and never calls an external sink
  or performs I/O. Oldest events are evicted after the configured capacity;
  `droppedCount` exposes pressure without retaining old data.
- Hosts may explicitly call `snapshot()` or `drain()` to collect sanitized
  evidence. Keep export off by default. A recorder should not be persisted without
  an explicit product privacy decision.
- The Meta vendor adapter, iOS foreground/background, and on-device UI evidence
  still require additional wiring and physical validation before #330 can close.

Sample integration:

```swift
let diagnostics = AWLDiagnosticRecorder(capacity: 256)
// Pass diagnostics to AgentWearLinkRuntime and OpenClawGatewaySupervisor.
// Explicitly inspect diagnostics.drain() from a development-only host UI.
```
