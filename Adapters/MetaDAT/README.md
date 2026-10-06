# Meta DAT adapter

This directory is reserved for the first vendor device adapter.

## Dependency rule

The root `AgentWearLinkCore` Swift package intentionally does **not** depend on Meta DAT.

The iOS reference application will own the Meta Swift Package dependency and compile the adapter in an iOS-specific target. This prevents:

- vendor SDK availability from breaking platform-neutral core CI,
- Meta types leaking into core APIs,
- future non-Meta devices inheriting unnecessary dependencies.

## Current DAT modules relevant to AWL

Stable/public baseline:
- `MWDATCore`
- `MWDATCamera`
- `MWDATMockDevice`

Capabilities that require explicit SDK/version/release-channel validation before AWL advertises them:
- `MWDATSpeech`
- voice invocations in `MWDATCore`
- `MWDATInputs`
- `MWDATMotion`

Experimental modules are capability-gated. AWL must not advertise them unless the connected device/session actually supports and authorizes them.

## MockDeviceKit

Use Meta's `MWDATMockDevice` package to exercise the **normal DAT session path** without physical glasses. Keep MockDeviceKit below the concrete iOS `MetaDATSession` bridge; do not add mock-specific types or branches to AgentWearLinkCore. See `docs/meta-mock-device-kit.md`.

## Next implementation gate

Build the official CameraAccess sample and its MockDeviceKit path first. Then copy only validated session/capability mappings into the concrete iOS bridge behind `MetaDATAdapter`.


## Pinned integration compile gate

The reference integration package in this directory pins Meta Wearables DAT to
**1.0.0**, matching Meta's current CameraAccess sample project.

Resolve/build the integration package separately from the root package so vendor SDK
changes cannot destabilize deterministic Core CI:

```bash
cd Adapters/MetaDAT
swift package resolve
swift build
```

For a release-quality iOS check, build this package/target with the repository's
documented Xcode toolchain and an iOS destination. The root `swift test` remains
vendor-independent and must not be interpreted as proof that concrete MWDAT sources
compile.
