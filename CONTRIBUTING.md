# Contributing to AgentWearLink

AgentWearLink is pre-alpha. Contributions are welcome, but changes should preserve the interoperability boundary rather than optimize only for the first Meta/OpenClaw deployment.

## Before changing code

1. Read `docs/PRD.md` and the relevant ADR.
2. Keep vendor/runtime-specific types outside `AgentWearLinkCore`.
3. Do not add speculative abstractions without a concrete integration need.
4. Preserve bounded buffering, explicit cancellation, and no-silent-replay semantics.
5. Never commit credentials, device private keys, tokens, or private media.

## Development

```bash
swift test
```

New deterministic behavior should include regression coverage. Hardware-only behavior should include reproducible validation steps and the device/OS/SDK/runtime versions used.

## Pull requests

Keep each PR focused. Explain the invariant being changed, failure mode addressed, and what remains hardware- or deployment-dependent.

For mutating OpenClaw validation, use the explicit chat probe only after the read-only probe succeeds. Do not automatically retry an interaction whose delivery status is uncertain.
