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

Use the detailed reference in `meta-mock-device-kit.md`.

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

## Phase 0 — local iOS provisioning (no values committed)

The repository's iOS reference host can build in public CI without a real
Meta developer account. Those CI defaults are intentionally non-functional:
Meta App ID `0`, empty Client Token and Apple Team ID, and a test URL scheme.
For physical device testing, generate `Adapters/MetaDAT/TestApp` with XcodeGen
then supply a **local, ignored** `local.meta.xcconfig`:

```xcconfig
// Local only: this file is ignored by .gitignore's local.* rule.
AWL_META_APP_ID = REPLACE_WITH_YOUR_META_APP_ID
AWL_META_CLIENT_TOKEN = REPLACE_WITH_YOUR_META_CLIENT_TOKEN
AWL_META_TEAM_ID = REPLACE_WITH_YOUR_APPLE_TEAM_ID
AWL_META_CALLBACK_SCHEME = REPLACE_WITH_YOUR_REGISTERED_URL_SCHEME
PRODUCT_BUNDLE_IDENTIFIER = REPLACE_WITH_YOUR_REGISTERED_IOS_BUNDLE_ID
DEVELOPMENT_TEAM = REPLACE_WITH_YOUR_APPLE_TEAM_ID
CODE_SIGN_STYLE = Automatic
```

Example local generation and device build from the repository root:

```sh
cd Adapters/MetaDAT/TestApp
xcodegen generate
xcodebuild -project AgentWearLinkMetaDATTestHost.xcodeproj \
  -scheme AgentWearLinkMetaDATIOSHost \
  -configuration Debug \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' \
  -xcconfig local.meta.xcconfig build
```

Use a development-team-authorized provisioning profile. Register the *same*
callback URL scheme, Meta application ID and iOS bundle identifier in the
Meta developer configuration, and verify Developer Mode/permissions in the
official Meta AI app before AWL testing. Never commit the xcconfig or paste
its contents in CI, issues or logs. Xcode packages Meta client configuration
inside the installed app; do not mistake the client token for a server-side
secret. Never put an OpenClaw Gateway bearer token into an xcconfig or plist.

The reference app now displays `meta-local-provisioning-required` instead of
attempting SDK registration with the placeholder values. This is a **local
setup gate**, not a claim that physical registration has been validated.
Run the official Meta sample baseline and the gateway health/text probe before
claiming physical E2E acceptance. The available app UI remains a development
reference host, not an App Store-distributable production client.
