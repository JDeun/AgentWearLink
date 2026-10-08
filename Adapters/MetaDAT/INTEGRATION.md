# Meta DAT integration status

AgentWearLink pins Meta Wearables DAT **1.0.0** in `Adapters/MetaDAT`. Vendor SDK types remain outside `AgentWearLinkCore`.

## Implementation status by evidence level

### Production-wired today

The vendor-linked production adapter currently includes:

- `Wearables.configure()` bootstrap and Meta registration handling
- deterministic selected-device choice plus link/compatibility loss handling
- `DeviceSession` startup, bounded timeout, state/error monitoring, and teardown
- MockDeviceKit isolation from the production dependency graph
- pinned SDK and full iPhone reference-stack compile gates for iOS Simulator

### Production composition now reachable through the vendor adapter

The current `MetaDATDeviceAdapter` exposes dynamic capabilities and composes
bounded one-shot camera snapshots, final Speech transcripts, independent Voice
Invocation, and foreground/background invalidation through public Core adapter
entrypoints. MockDeviceKit app-hosted UI tests check representative runtime
flows. Exact real-device/media evidence remains separated under #1/#58/#59.
Issue #230 tracks remaining end-to-end evidence rather than a missing parallel
`MetaDATSession` abstraction.

### Experimental Camera.photo (explicitly not the default)

**Meta DAT 1.0.0 marks standalone `Camera.photo` experimental and currently
non-publishable.** Production and reference hosts continue using short-lived
`camera.stream.capturePhoto(format: .jpeg)` unless a DEBUG operator explicitly
selects `MetaDATSnapshotMode.experimentalStandalonePhoto`. The reference iOS
host displays a DEBUG-only warning toggle, disabled until vision is enabled.

Experimental mode arms Photo state/data/error listeners **before** `Photo.start()`,
waits for `.started` before triggering `Photo.capturePhoto`, caps the whole
capture with a deadline, discards callbacks after cancellation, accepts only
bounded JPEG bytes, and stops Photo before Camera. It does **not** start video.
If the SDK returns another encoding, the experimental path fails closed
rather than silently labeling it JPEG. The default path is unaffected.

The app-hosted MockDeviceKit UI test exercises default and experimental
paths independently with the same JPEG fixture. A successful simulator gate
is not physical camera or Apple App Review authorization. Future vendor
updates may change the experimental release restriction; reassess before
considering standalone Photo a publishable default (#323).

MockDeviceKit host bootstrap and deterministic mock fixtures live in the separate `AgentWearLinkMetaDATTestSupport` target; the production integration target does not link MockDeviceKit.

These are code-side evidence claims, not physical-device claims. Helper-level coverage also does not prove that a feature is reachable through the shipping production adapter until #230 is complete.

## Deliberately not claimed as physically validated

The following remain hardware/deployment gates:

- real Bluetooth pairing/link recovery
- real camera sensor wake, shutter timing, and photo transfer
- microphone/speaker routing on glasses
- locked/pocketed hands-free invocation
- background/foreground behavior on a physical iPhone
- iPhone → Tailnet → OpenClaw deployment behavior

Raw PCM audio is not inferred from DAT Speech. AWL advertises a capability only when the pinned SDK, selected device, permission state, and active lifecycle actually support it.

## Build and simulator integration

Resolve and compile the pinned integration independently from the vendor-neutral root package:

```bash
cd Adapters/MetaDAT
swift package resolve
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  build
```

The Swift package keeps production integration and MockDeviceKit test support in separate targets. `AgentWearLinkMetaDATIntegration` contains no `MWDATMockDevice` dependency; behavioral simulator work links `AgentWearLinkMetaDATTestSupport` only from the dedicated `TestApp/` host plus its app-hosted XCUITest target. There is no SwiftPM test-host executable.

Root `swift test` passing means Core/runtime contracts pass. It does **not** prove the concrete MWDAT integration or physical glasses.

## Lifecycle invariants

These are required production invariants. Deterministic helper coverage exists for the relevant slices, while end-to-end enforcement through the concrete camera/Speech/Voice session path remains part of #230.

- Subscribe to session state/error streams before `start()` so startup transitions are not missed.
- A stopped or invalidated session is not resurrected.
- Foreground entry requires fresh device/media readiness.
- Selected-device link or compatibility loss invalidates the active path.
- Camera work is bounded and cancellation-safe; late results from an obsolete capture generation are ignored.
- Voice Invocation is independent from ordinary camera/device-session ownership.
- Unsupported capabilities are never advertised merely because an SDK symbol exists.

## Validation map

- [MockDeviceKit reference](../../docs/meta-mock-device-kit.md)
- [DAT capability contract](../../docs/meta-dat-capabilities.md)
- [DAT bridge notes](../../docs/meta-dat-bridge.md)
- [Physical validation runbook](../../docs/meta-dat-validation.md)
- [Known issues](../../docs/meta-dat-known-issues.md)
