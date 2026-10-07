# Testing strategy

AgentWearLink separates evidence by what a test can actually prove. A green lower layer never upgrades a hardware- or deployment-dependent claim.

## Evidence vocabulary

Use these terms literally in issues, PRs, and documentation:

- **helper implemented** — the code slice exists, but may not be reachable through the production adapter/session
- **production wired** — the shipping adapter/session composes and exposes the slice
- **deterministically tested** — automated tests exercise the relevant path without live deployment or hardware
- **simulator validated** — an iOS simulator/vendor-hosted path executes successfully
- **deployment validated** — the real network/runtime deployment executes successfully
- **physical validated** — the target wearable + physical iPhone path executes successfully

A feature may occupy several of these states at once. For example, current Meta camera/Speech/Voice helper slices are implemented and deterministically tested, but full production composition remains tracked by #230.

## 1. Deterministic Core/runtime tests

No physical wearable and no live deployment are required.

Examples:

- session lifecycle and duplicate suppression
- cancellation and late-result rejection
- bounded stream/media behavior
- event/request mapping
- OpenClaw protocol framing, RPC correlation, and reconnect state machines
- pure reconnect/backoff policy tests are unit evidence only; the real supervisor transition matrix and no-replay evidence remain tracked by #233
- existing-session wire fixtures are schema evidence only; `OpenClawExistingSessionAdapterTests` additionally exercises the production GatewayConnection → dispatcher → run client → native adapter path against a deterministic synthetic socket
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

# For a Meta behavioral change CI reuses one test build:
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration-Package \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  build-for-testing

# After booting that simulator:
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration-Package \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:AgentWearLinkMetaDATIntegrationTests \
  test-without-building
```

CI separates the compatibility compile gate from the simulator behavioral gate. Any Core/package change that can affect the Meta adapter still resolves the pinned SDK, verifies its immutable revision, lists schemes, and compiles the concrete integration. Simulator boot and the deterministic package-hosted Meta integration/helper XCTest target run only when Meta adapter/test paths or the workflow itself change.

The behavioral XCTest target covers lifecycle, readiness, camera-ignition, listener-generation, and mock-host contract regressions. Where a Meta feature is still a helper slice rather than a production-composed session feature, this proves the helper contract only; #230 owns production-path composition. The MockDeviceKit test that requires a linked-app Keychain context is intentionally skipped here and remains part of the app-hosted XCUITest layer below.

This preserves SDK/API compatibility coverage for Core-only changes without paying the simulator behavioral-test cost on every Core PR. Meta implementation changes still receive the full deterministic behavioral gate, while `build-for-testing` / `test-without-building` avoids compiling that test bundle twice. Neither path proves physical wearable behavior.

## 3. Simulator/vendor behavioral integration

The generated iOS reference host links the complete shipping stack used by the phone-side reference path: AgentWearLinkCore, AgentWearLinkMetaDATIntegration, AgentWearLinkOpenClaw, and AgentWearLinkAppleOutput. CI compiles this host for a generic iOS Simulator whenever any of those product paths, the Meta integration, the root package manifest, or the workflow changes. This is a compile/availability gate only; it does not claim live Gateway or physical wearable behavior.

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

The root `core-test` job protects vendor-neutral contracts. The Meta integration job also serves as the iPhone reference-stack compile gate and uses its own vendor-compatible Apple toolchain with path-sensitive depth: Core/package changes that can affect Meta receive the pinned-SDK compatibility compile gate; Meta adapter/test or workflow changes additionally boot an iOS Simulator and execute `AgentWearLinkMetaDATIntegrationTests`; app-host/UI paths additionally run their generated-host and MockDeviceKit/XCUITest gates. A Meta toolchain requirement must not silently raise the root Core minimum. CI output and documentation must state the evidence boundary rather than calling simulator results physical validation.

The repository ruleset requires the final GitHub Actions status context `test`. That context is an aggregate merge gate, not another test execution: it passes only when `core-test` succeeds and, for paths that require Meta/iPhone-reference validation, `meta-dat-integration` also succeeds. This prevents a green Core job from admitting a PR whose applicable Meta gate failed. Physical-device and deployment E2E evidence remains outside the required deterministic merge gate.

## Test-data policy

Use synthetic text, credentials, and media fixtures. Do not put real tokens, private keys, personal conversations, or private wearable media into fixtures, logs, CI artifacts, or public issues.
