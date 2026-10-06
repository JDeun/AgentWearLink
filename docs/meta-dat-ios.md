# Meta Wearables DAT — iOS reference adapter

This document records the SDK assumptions for the first AgentWearLink device adapter.

## Current baseline

As of 2026-10-06, Meta's Wearables FAQ states that **Device Access Toolkit 1.0 is a stable, supported release**, rolling out from 2026-09-30. Some public iOS repository text still retains older **developer preview** wording. AWL therefore records and pins the exact package version used for validation instead of inferring capability/release-channel status from a single marketing label.

The current public sample uses:

- `MWDATCore`
- `MWDATCamera`
- `MWDATMockDevice` for development/testing
- `Wearables.configure()` during app initialization
- `Wearables.shared.startRegistration()` for Meta AI registration
- `Wearables.shared.handleUrl(...)` for the registration callback
- `AutoDeviceSelector` + a device session
- `addCamera(config:)` for camera streaming

## Reference app prerequisites

Follow the current official CameraAccess sample requirements rather than hard-coding old preview assumptions. At the time this document was written, the public CameraAccess sample states:

- iOS 17.2+
- Xcode 26.4+
- Swift 6.3+
- Meta AI companion app
- Developer Mode enabled for physical-device development

## Required app configuration

The iOS reference application needs the SDK's current URL callback, Bluetooth, external-accessory and local-network declarations. Microphone/audio background permissions should only be added when the app actually records glasses microphone audio.

Do not copy stale Info.plist values from old DAT preview examples without comparing them to the current official sample.

## Implementation rule

The AWL adapter must wrap DAT types. `MWDATCore`, `MWDATCamera`, and future DAT modules must not become dependencies of `AgentWearLinkCore`.

## Validation sequence

1. Build Meta's official CameraAccess sample unchanged.
2. Run its MockDeviceKit path before introducing AWL bridge code (see `meta-mock-device-kit.md`).
3. Register through Meta AI Developer Mode.
4. Validate session start/end.
5. Validate camera preview/capture.
6. Validate available speech/audio behavior.
7. Validate disconnect/reconnect.
8. Record exact SDK version and device/OS/firmware.
9. Only then pin the DAT dependency in the AWL iOS reference app.

This avoids encoding guessed SDK APIs into the production adapter.
