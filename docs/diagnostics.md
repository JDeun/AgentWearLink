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
- The concrete Meta adapter and iOS reference host now share this recorder.
  The host exports an allowlisted, bounded JSON report only after an explicit
  **Copy sanitized diagnostics** action. This is a code-side capability, not
  evidence that physical iPhone/glasses logs or caches have been audited.

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

The reference iOS host explicitly injects the same recorder into its
runtime, Meta device, and OpenClaw supervisor and exposes a manual export.
`AWLDiagnosticEvidence.export` strips correlation UUIDs into local ordinals,
limits event count, and reports dropped history. Production consumers must
make an independent privacy decision before persisting any evidence.

**Evidence boundary:** deterministic Core/Meta tests cover bounded diagnostic
fields and lifecycle correlation. Hardware log/cache inspection, credential
redaction, background transitions and reconnection evidence remain under
#59/#119. No device behavior is inferred from a green simulator build.
