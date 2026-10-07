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

### Implemented and deterministically tested, but not yet fully production-wired

The following slices exist as code and have deterministic helper/integration coverage, but they are not yet all composed into the concrete vendor session/adapter path. Production composition is tracked by #230:

- live capability derivation from current readiness
- camera configuration, ignition/first-frame readiness, bounded shutter/photo-result handling, normalization, and cancellation generations
- Speech transcript handling with final-only filtering and duplicate suppression
- independent Voice Invocation listener, acknowledgement, and bounded reopen/backoff policy
- foreground/background media invalidation and fresh-readiness rules

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
