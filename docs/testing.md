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

## 2. Pinned integration compile and deterministic test gates

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

# CI selects and boots an available iPhone Simulator, then runs:
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:AgentWearLinkMetaDATIntegrationTests \
  test
```

The second command executes the deterministic package-hosted Meta integration/helper XCTest target, including lifecycle, readiness, camera-ignition, listener-generation, and mock-host contract regressions. The MockDeviceKit test that requires a linked-app Keychain context is intentionally skipped here and remains part of the app-hosted XCUITest layer below.

This catches SDK/API drift and proves the deterministic helper assertions actually execute. It still does not prove physical wearable behavior.

## 3. Simulator/vendor behavioral integration

The generated Meta iOS test host uses **XcodeGen 2.46.0**. Install the repository-pinned, checksum-verified official release archive before generating the project:

```bash
bash scripts/install-xcodegen.sh
export PATH="$PWD/.build/tools:$PATH"
xcodegen --version
```

CI uses the same script and pinned archive SHA-256. The installer preserves the complete XcodeGen release distribution, including `share/xcodegen/SettingPresets`; copying only the executable drops default Xcode build settings required by generated app targets. Upgrade XcodeGen only in a dedicated dependency/CI change that updates the version/checksum, generated-project validation, and this documentation together. The generated `.xcodeproj` remains ephemeral.

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

The root job protects vendor-neutral contracts. The Meta integration job uses its own vendor-compatible Apple toolchain, compiles the pinned SDK integration, executes the deterministic `AgentWearLinkMetaDATIntegrationTests` target on iOS Simulator, and separately runs the app-hosted MockDeviceKit/XCUITest contract when its path gate is active. A Meta toolchain requirement must not silently raise the root Core minimum. CI output and documentation must state the evidence boundary rather than calling simulator results physical validation.

## Test-data policy

Use synthetic text, credentials, and media fixtures. Do not put real tokens, private keys, personal conversations, or private wearable media into fixtures, logs, CI artifacts, or public issues.
