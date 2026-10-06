# Meta DAT adapter

This directory contains AgentWearLink's concrete reference integration for Meta Wearables DAT **1.0.0**.

## Boundary rule

The root `AgentWearLinkCore` package remains vendor-neutral. Meta SDK imports live in this integration package and its iOS host surfaces so:

- vendor SDK availability cannot break platform-neutral Core contracts,
- Meta types do not leak into public Core APIs,
- future wearable adapters do not inherit Meta dependencies.

## Implemented integration

The pinned integration includes registration/device lifecycle handling, live capability derivation, bounded camera snapshot plumbing, Speech final-transcript handling, Voice Invocation lifecycle, foreground/background readiness policies, and DEBUG-only MockDeviceKit bootstrap support.

See [INTEGRATION.md](INTEGRATION.md) for the detailed implementation status.

## Build gate

```bash
cd Adapters/MetaDAT
swift package resolve
xcodebuild \
  -scheme AgentWearLinkMetaDATIntegration \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation \
  build
```

This is a compile gate against the pinned vendor SDK, not physical-device proof.

## Behavioral simulator host

MockDeviceKit requires linked-app runtime context. A bare package xctest is therefore not the behavioral harness. The reference iOS app/XCUITest host lives under `TestApp/` and is tracked by #122.

See [MockHarness.md](MockHarness.md) and [../../docs/meta-mock-device-kit.md](../../docs/meta-mock-device-kit.md).

## Physical gates

Real Bluetooth, camera sensor wake/shutter/photo transfer, wearable audio routing, locked/pocketed invocation, firmware-specific behavior, and iPhone network transitions require a physical Ray-Ban Meta + iPhone validation run.
