# Meta DAT adapter

This directory is reserved for the first vendor device adapter.

## Dependency rule

The root `AgentWearLinkCore` Swift package intentionally does **not** depend on Meta DAT.

The iOS reference application will own the Meta Swift Package dependency and compile the adapter in an iOS-specific target. This prevents:

- vendor SDK availability from breaking platform-neutral core CI,
- Meta types leaking into core APIs,
- future non-Meta devices inheriting unnecessary dependencies.

## Current DAT 1.0 modules relevant to AWL

Stable/public baseline:
- `MWDATCore`
- `MWDATCamera`
- `MWDATMockDevice`

Experimental capabilities introduced in DAT 1.0:
- `MWDATSpeech`
- voice invocations in `MWDATCore`
- `MWDATInputs`
- `MWDATMotion`

Experimental modules are capability-gated. AWL must not advertise them unless the connected device/session actually supports and authorizes them.

## Next implementation gate

Build the official CameraAccess sample and Meta Mock Device Kit first. Then copy only the validated session/capability mappings into `MetaDATAdapter`.
