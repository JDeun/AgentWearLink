# MockDeviceKit behavioral harness

Issue: #101

The compile seam in the integration Swift package proves that AWL and
`MWDATMockDevice` resolve together. Behavioral simulation needs an **iOS app
process** because Meta's test server is hosted by `MockDeviceKit.shared` in the
application, while an XCUITest process drives it through
`MWDATMockDeviceTestClient`.

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

## Proof boundary

This harness can prove SDK wiring, registration/device/session transitions,
camera/photo result plumbing, and simulated voice launch where the pinned SDK
supports it. It does **not** prove Bluetooth behavior, glasses firmware,
lock-screen/background execution, microphone routing, or real Tailnet/OpenClaw
behavior. Those remain physical validation gates.


## App-hosted behavioral boundary

Behavioral MockDeviceKit pairing must run from an iOS application host. The host launches with `--awl-meta-ui-testing`, starts the DEBUG-only mock server through `MetaDATMockHostBootstrap`, and publishes its port through `MWDAT_TEST_SERVER_PORT_FILE`. The UI-test client is created only after the application launches, waits for the server, and owns bounded pair/unpair cleanup.

The source stubs live in `TestHost/` and `UITests/`. They intentionally require an Xcode application/UI-test target because a bare Swift-package xctest process does not have Meta's linked-app Keychain context. This simulator proof does not replace physical Bluetooth, background, audio, or camera validation.
