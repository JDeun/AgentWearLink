# P0-A Meta DAT validation runbook

Use this runbook before implementing the concrete Meta DAT bridge in issue #3.

## Environment record

Record before testing:

- AgentWearLink commit
- Meta DAT package version/commit
- Xcode and Swift versions
- iOS version and iPhone model
- glasses model and firmware
- Meta AI app version
- Developer Mode state

Do not record Meta credentials, tokens, private media, or device identifiers that are not needed for reproduction.

## Phase 1 — official sample baseline

1. Clone Meta's official iOS DAT repository.
2. Build the official CameraAccess sample without AWL modifications.
3. Configure your own Apple development team and bundle identifier.
4. Enable Developer Mode in the Meta AI app.
5. Complete registration.
6. Start and end a device session.
7. Start and stop camera preview.
8. Capture a photo.
9. Background and foreground the app and record observed session teardown/recovery.
10. Disconnect/reconnect the glasses.

If the official sample fails, stop here. Do not encode a workaround in AWL until the SDK/sample failure is understood.

## Phase 2 — MockDeviceKit baseline

Before physical bridge work, verify the same SDK generation with MockDeviceKit where supported:

- simulated Ray-Ban Meta pairing
- power/unfold/don lifecycle
- session creation
- deterministic camera feed
- teardown

MockDeviceKit proves API wiring, not Bluetooth/audio/background behavior.

## Phase 3 — capability inventory

For the exact validated SDK/device combination, record each capability as:

| Capability | Available | Stable/experimental | Permission required | Physical evidence |
| --- | --- | --- | --- | --- |
| session lifecycle | | | | |
| camera preview | | | | |
| standalone snapshot | | | | |
| speech recognition | | | | |
| raw audio | | | | |
| voice invocation | | | | |
| speaker/output routing | | | | |

Only advertise capabilities that the concrete session can actually support and authorize.

## Exit criteria for #1

- official sample builds and runs on the physical iPhone
- registration and session lifecycle succeed
- camera path succeeds
- disconnect/reconnect behavior is recorded
- speech/audio/invocation availability is explicitly recorded, including unsupported cases
- exact environment versions are attached to #1
- no private media or credentials are attached

After these criteria pass, implement the concrete host bridge under #3.
