# Meta DAT integration status

## Implemented scaffold

- SDK bootstrap via `Wearables.configure()`
- Meta AI registration façade
- callback filtering on `metaWearablesAction`
- `AutoDeviceSelector`
- `DeviceSession` creation/start/stop
- wait for `.started` before declaring connect success
- error stream forwarding into typed AWL device errors
- cleanup on explicit disconnect

## Not implemented yet

- camera capability
- speech capability
- voice invocation
- raw PCM audio
- device input/motion
- iOS UI/Xcode project integration

These are intentionally separate slices because DAT 1.0 marks several of them experimental and because camera lifecycle currently has upstream reliability reports.

## Build requirement

These files are not part of the root `AgentWearLinkCore` Swift package. Compile them in an iOS target that links:

- `AgentWearLinkCore`
- Meta `MWDATCore`

Later feature files add `MWDATCamera`, `MWDATSpeech`, or other DAT modules only when required.

## Lifecycle rule

Always stop capabilities before the parent `DeviceSession`, and stop the session on user-driven exit/background paths. Do not retain a stopped session for reuse; create a new session after device availability returns.
