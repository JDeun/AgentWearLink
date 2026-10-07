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

## Meta DAT lifecycle and media correlation

The vendor-linked `MetaDATDeviceAdapter` accepts the same optional
`AWLDiagnosticRecorder`. Its bounded, typed events cover session startup,
readiness, retired generations, background invalidation, explicit snapshot
request/success/failure and accepted final Speech transcripts. All events contain
only a local interaction identifier (where applicable), a generation and the
closed event kind. No transcript, capture bytes, error text, device identity or
credential is passed to diagnostics.

This provides code-side correlation only. A production host must explicitly
inject one recorder into its runtime and device/agent adapters and opt in to a
sanitized export before claiming deployment observability. Hardware-verified
privacy and log/cache inspection remain required for #330/#59.
