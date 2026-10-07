# MockDeviceKit behavioral harness

Issue: #101

The compile seam in the integration Swift package proves that AWL and
`MWDATMockDevice` resolve together. Behavioral simulation needs an **iOS app
process** because Meta's test server is hosted by `MockDeviceKit.shared` in the
application, while an XCUITest process drives it through
`MWDATMockDeviceTestClient`.

Package-hosted `xcodebuild test` is intentionally not a behavioral gate: with the pinned SDK it can abort before test execution because `MWDATCore` expects linked-app runtime context. The package integration library remains a compile gate, but there is no SwiftPM behavioral host; behavioral CI belongs exclusively to the `TestApp/` app-hosted XCUITest target tracked by #122.

## Host contract

The reference test host must:

1. call `Wearables.configure()` before using the SDK;
2. only enable the mock kit for an explicit test launch argument;
3. use `MockDeviceKitConfig(initiallyRegistered: false)` so registration is
   exercised instead of silently bypassed;
4. read a unique port-file path from `MWDAT_TEST_SERVER_PORT_FILE`;
5. start `MockDeviceKit.shared.startTestServer(portFilePath:)`;
6. never enable the mock server in a release build.

The XCUITest process must launch the host first, then construct
`MockDeviceTestClient(portFilePath:)` and wait for the server. It must unpair
the device and remove the temporary port file during teardown.

## Minimum fixture sequence

```text
launch host --ui-testing
  -> waitForServer
  -> registration flow
  -> pairDevice()
  -> setCameraFeed(...)
  -> setCapturedImage(...)
  -> start AWL Meta DAT session
  -> exercise normalized event/snapshot path
  -> unpairDevice(...)
  -> terminate host
```

The initial camera fixture should use repository-owned small deterministic
assets rather than depending on Meta sample assets.

## Simulator selection

CI intentionally selects any available iPhone Simulator at runtime. The handset profile is only an iOS app host for `MockDeviceKit`; its simulated camera hardware is never used by these tests. Pinning `iPhone 16 Pro`, `iPhone 16`, or another model would add runner-image fragility without increasing Meta camera coverage.

## Proof boundary

This harness can prove SDK wiring, registration/device/session transitions,
camera/photo result plumbing, and simulated voice launch where the pinned SDK
supports it. It does **not** prove Bluetooth behavior, glasses firmware,
lock-screen/background execution, microphone routing, or real Tailnet/OpenClaw
behavior. Those remain physical validation gates. In particular, cold-sensor wake behavior, real video ignition, shutter timing, and photo transfer over an actual Ray-Ban Meta link must be re-run on a physical iPhone + glasses before #1/#98 can close.
