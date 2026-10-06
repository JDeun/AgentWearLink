# Meta MockDeviceKit reference

This document records the AgentWearLink development baseline for Meta's iOS MockDeviceKit.

## Purpose

MockDeviceKit lets the DAT integration be exercised without physical glasses. It is useful for API wiring, lifecycle state transitions, permission behavior, camera fixtures, and deterministic adapter tests.

It does **not** prove real Bluetooth behavior, microphone/speaker routing, firmware compatibility, background/lock-screen behavior, radio/network transitions, or wearable UX. Those remain physical validation gates.

## Package and entry point

Add `MWDATMockDevice` from Meta's iOS Swift package to the iOS host/test target.

Typical setup:

```swift
import MWDATMockDevice

let kit = MockDeviceKit.shared
kit.enable()

// Illustrative only. Exact pair/state-control signatures are version-specific.
// Use the API exposed by the pinned DAT package and Meta's matching sample.
let kit = MockDeviceKit.shared
kit.enable()
```

A mock device becomes discoverable through the normal Wearables device flow after the required simulated state transitions. Treat concrete pairing/state-control calls as version-specific; verify them against the pinned SDK and matching sample before copying code. Tear tests down with `MockDeviceKit.shared.disable()`.

## What can be simulated

Meta's current public documentation describes support for:

- pairing simulated glasses models
- power on/off and folded/unfolded/worn state
- registration and permission state
- deterministic camera video feeds
- JPEG/PNG photo fixtures
- camera capture/stream behavior
- touch/input services where supported
- speech testing where supported by the current SDK
- device unpair/teardown

The exact surface can change between DAT releases. Pin the package version and compile against that version rather than copying symbols from this document blindly.

## CameraAccess sample

Meta's CameraAccess sample includes Debug-only MockDeviceKit integration. A useful AWL baseline is:

1. build CameraAccess on an iOS Simulator
2. open its Debug mock-device UI
3. pair Ray-Ban Meta
4. Power On → Unfold → Don
5. configure a sample camera feed
6. start a DAT session
7. start/stop preview
8. capture a fixture image
9. end the session
10. disable MockDeviceKit

This proves that the SDK generation and host configuration are coherent before AWL's concrete bridge is introduced.

## AWL integration plan

The concrete iOS host bridge should adapt the normal DAT session API to `MetaDATSession`; MockDeviceKit should enter **below** that bridge through DAT's own device/session discovery. Do not create a MockDevice-specific path in AgentWearLinkCore.

That gives the desired test shape:

```text
MockDeviceKit
    ↓
Meta DAT normal session/device APIs
    ↓
concrete iOS MetaDATSession bridge
    ↓
AgentWearLinkMetaDAT.MetaDATAdapter
    ↓
AgentWearLinkCore
```

The same bridge can then be used with physical Ray-Ban Meta without changing Core.

## Recommended deterministic cases

Once the concrete bridge exists, automate at least:

- device becomes available after mock state transition
- session start/end maps once
- capability set reflects the current mock/session
- transcript/invocation mapping when supported
- explicit snapshot returns one bounded attachment
- permission denial becomes a typed device/capability failure
- disconnect/teardown terminates event forwarding
- reconnect creates a fresh valid session without replaying prior interaction state

## Limitations

Do not close these gates from MockDeviceKit evidence alone:

- #1 physical DAT baseline
- #5 wearable audio/output E2E
- #6 hands-free physical invocation
- #58 physical vision E2E
- #59 physical reliability/privacy/recovery

## Release-status note

Meta's FAQ states that Wearables Device Access Toolkit 1.0 became a stable, supported release beginning 2026-09-30. Some public repository text still contains older “developer preview” wording. For AWL, record and pin the exact DAT version used and treat capability availability/release-channel restrictions as version-specific facts.
