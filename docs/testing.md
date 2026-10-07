# Testing strategy

AgentWearLink separates evidence by what a test can actually prove. A green lower layer never upgrades a hardware- or deployment-dependent claim.

## 1. Deterministic Core/runtime tests

No physical wearable and no live deployment are required.

Examples:

- session lifecycle and duplicate suppression
- cancellation and late-result rejection
- bounded stream/media behavior
- event/request mapping
- OpenClaw protocol framing, RPC correlation, and reconnect state machines
- credential/configuration diagnostic redaction
- Meta helper policies such as final-transcript filtering, capture generations, readiness, and bounded backoff

Run from the repository root:

```bash
swift test
```

The root package's toolchain contract is independent from concrete vendor adapters.

## 2. Pinned integration compile gates

Concrete vendor code is compiled against the exact dependency it claims to support.

For Meta DAT, use a Swift 6.0+ toolchain for `Adapters/MetaDAT`; this is intentionally stricter than the vendor-neutral root package. CI fails fast before dependency resolution when the active Swift toolchain is older than 6.0, so a floating runner image cannot silently fall below this contract. The package manifest explicitly keeps AWL's Meta targets in Swift 5 language mode until source migration is handled separately:

```bash
cd Adapters/MetaDAT
swift package resolve
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  build
```

This catches SDK/API drift. It does not prove runtime behavior.

## 3. Simulator/vendor behavioral integration

Meta's MockDeviceKit runs in an iOS host process and is driven through `MWDATMockDeviceTestClient`. The behavioral contract covers server rendezvous, mock pairing/state transitions, and normal DAT wiring.

This layer can prove that the pinned vendor SDK and AWL integration cooperate in supported simulator conditions. It cannot prove Bluetooth, real sensor timing, firmware behavior, physical audio routing, lock-screen/background execution, or mobile Tailnet behavior.

See [meta-mock-device-kit.md](meta-mock-device-kit.md).

## 4. Deployment E2E

A real agent deployment is exercised without treating the wearable hardware as proven.

The reference P0-B topology is:

```text
iPhone / AWL → Tailscale → Mac mini → OpenClaw Gateway
```

Required evidence includes authentication/pairing, persistent credential reuse, one real agent turn, incremental output, existing-session semantics, and no silent replay after uncertain delivery.

See [p0b-openclaw-validation.md](p0b-openclaw-validation.md).

## 5. Physical E2E

Ray-Ban Meta + physical iPhone + target runtime.

Required for claims involving:

- Bluetooth/device lifecycle
- real camera sensor wake, shutter timing, and photo transfer
- microphone/speaker routing
- Hey Meta / Voice Invocation behavior
- locked/pocketed/background execution
- Wi-Fi/cellular/Tailnet transitions on the phone
- end-user latency and interruption UX

A hardware-dependent feature remains unvalidated until this layer passes, even when all earlier layers are green.

## CI interpretation

The root job protects vendor-neutral contracts. The Meta integration job uses its own vendor-compatible Apple toolchain and protects pinned SDK compilation plus the app-hosted simulator contract as it becomes available. A Meta toolchain requirement must not silently raise the root Core minimum. CI output and documentation must state the evidence boundary rather than calling simulator results physical validation.

## Test-data policy

Use synthetic text, credentials, and media fixtures. Do not put real tokens, private keys, personal conversations, or private wearable media into fixtures, logs, CI artifacts, or public issues.
