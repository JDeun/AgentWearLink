# Meta DAT integration status

AgentWearLink pins Meta Wearables DAT **1.0.0** in `Adapters/MetaDAT`. Vendor SDK types remain outside `AgentWearLinkCore`.

## Implemented code-side foundation

The concrete integration now includes:

- `Wearables.configure()` bootstrap and Meta registration handling
- deterministic selected-device choice plus link/compatibility loss handling
- `DeviceSession` startup, bounded timeout, state/error monitoring, and teardown
- live capability derivation from current readiness
- camera configuration, ignition/first-frame readiness, bounded shutter/photo-result handling, normalization, cancellation generation, and deterministic mock fixtures
- Speech transcript stream handling with final-only filtering and duplicate suppression
- independent Voice Invocation listener, acknowledgement, and bounded reopen/backoff policy
- foreground/background media invalidation and fresh-readiness rules
- DEBUG-only MockDeviceKit host bootstrap and test-server rendezvous
- pinned SDK compile gates for iOS Simulator

These are code-side claims. They are not substitutes for physical Ray-Ban Meta evidence.

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

The Swift package is a compile boundary for the concrete integration library only. Behavioral simulator work uses the dedicated `TestApp/` iOS application plus its app-hosted XCUITest target; there is no SwiftPM test-host executable.

Root `swift test` passing means Core/runtime contracts pass. It does **not** prove the concrete MWDAT integration or physical glasses.

## Lifecycle invariants

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
