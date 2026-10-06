# Contributing to AgentWearLink

AgentWearLink is pre-alpha. Contributions are welcome, but changes should preserve the interoperability boundary rather than optimize only for the first Meta/OpenClaw deployment.

## Before changing code

1. Read `docs/PRD.md` and the relevant ADR.
2. Keep vendor/runtime-specific types outside `AgentWearLinkCore`.
3. Do not add speculative abstractions without a concrete integration need.
4. Preserve bounded buffering, explicit cancellation, and no-silent-replay semantics.
5. Never commit credentials, device private keys, tokens, or private media.

## Development

Run vendor-neutral contracts from the repository root:

```bash
swift test
```

The root package keeps its Swift 5.10+ compatibility contract. Meta DAT integration is intentionally separate: `Adapters/MetaDAT/Package.swift` requires a Swift 6.0+ toolchain to parse the pinned vendor dependency, while AWL's Meta targets currently stay in Swift 5 language mode. Do not raise the root Core minimum—or silently opt the adapter sources into Swift 6 mode—merely to satisfy the reference vendor package.

For Meta DAT integration work, verify `swift --version`, then resolve/build the pinned package under `Adapters/MetaDAT`. App-hosted MockDeviceKit changes must pass the dedicated iOS simulator/XCUITest gate. See `docs/testing.md` for the evidence hierarchy.

New deterministic behavior should include regression coverage. Hardware-only behavior should include reproducible validation steps and the device/OS/SDK/runtime versions used.

## Pull requests

Keep each PR focused. Explain the invariant being changed, failure mode addressed, and what remains hardware- or deployment-dependent.

For mutating OpenClaw validation, use the explicit chat probe only after the read-only probe succeeds. Do not automatically retry an interaction whose delivery status is uncertain.

## Work tracking

AgentWearLink uses two issue levels so implementation context survives handoff between
contributors and development sessions.

- **Umbrella / gate issues** describe a delivery milestone or physical validation gate.
  They own end-to-end acceptance criteria, not individual implementation patches.
- **Child work issues** describe one reviewable engineering unit. Each should record why
  the work exists, scope, relevant verified external constraints, invariants, dependencies,
  and concrete acceptance criteria.

Pull requests should reference the child issue they implement. A child issue may close
when its code/documentation acceptance criteria are met even when the umbrella remains
open for physical validation. Do not close a hardware-gated umbrella based only on CI.

For vendor integrations, explicitly state what CI does and does not prove. In particular,
the root Swift package remains vendor-neutral; Meta DAT has its own pinned vendor-SDK compile gate and app-hosted simulator/XCUITest evidence layer. Neither may be described as physical-device proof.
