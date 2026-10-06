# Concrete Meta DAT bridge implementation notes

This document translates the current official Meta iOS sample patterns into the boundary required by `AgentWearLinkMetaDAT.MetaDATSession`. It is an implementation note, not a substitute for compiling against the pinned DAT package.

## Validated public API pattern

The current CameraAccess sample uses:

1. `AutoDeviceSelector(wearables: wearables)`
2. `wearables.createSession(deviceSelector: deviceSelector)`
3. subscribe to `session.statePublisher` and `session.errorPublisher`
4. call `session.start()`
5. after the session reaches `.started`, check/request camera permission
6. construct `StreamConfiguration`
7. `session.addCamera(config: config)`
8. subscribe to stream state/error/photo publishers
9. start the camera stream
10. `stream.capturePhoto(format: .jpeg)` for explicit capture
11. stop camera/session explicitly and discard terminal handles

The official sample explicitly subscribes **before** `start()` so initial transitions are not missed. AWL must preserve that ordering.

## Proposed host ownership

The iOS reference host—not Core—should own:

- `WearablesInterface`
- `AutoDeviceSelector`
- `DeviceSession`
- listener tokens
- `MWDATCamera.Camera` / stream handles
- permission requests
- Meta registration callback handling

The bridge exposes only the existing SDK-neutral `MetaDATSession` surface to `MetaDATAdapter`.

## Lifecycle mapping

Suggested mapping after compile validation:

| DAT observation | AWL bridge action |
| --- | --- |
| session starts | emit `MetaDATEvent.sessionStarted` for the active AWL interaction/session context |
| transcript | emit `.transcript` |
| voice invocation | emit `.invocation` |
| interruption | emit `.interrupted` |
| session terminal stop | emit `.sessionEnded` once |
| session/capability error | emit typed bridge `.failed` message |
| disconnect | terminate capability handles; do not replay prior interaction |

Do not invent an interaction ID from a device identifier. The host must define the interaction boundary explicitly when wiring invocation/transcript flows.

## Camera snapshot boundary

The current `MetaDATAdapter` is a DeviceAdapter but does not yet implement `SnapshotCapturingDevice`. The concrete camera work should therefore either:

- extend the Meta adapter with a validated snapshot capability, or
- introduce a small camera session collaborator inside `AgentWearLinkMetaDAT` while keeping MWDAT types in the host-specific implementation.

The final path must satisfy:

- explicit request only
- one capture per request
- camera permission checked before capture
- JPEG/PNG copied into bounded `ImageAttachment`
- no continuous frame retention
- no capture when the selected agent/model does not support vision
- pending capture fails promptly on disconnect

## MockDeviceKit test seam

MockDeviceKit should feed the same normal DAT session/camera APIs. Do not create a second AWL bridge just for mocks.

Expected test path:

```text
MWDATMockDevice fixture
  → Wearables/DeviceSession/Camera
  → concrete MetaDATSession host bridge
  → MetaDATAdapter
  → Core tests/assertions
```

## Compile gate

Before merging concrete MWDAT imports into the reference host:

- pin exact Meta DAT package version
- compile the official sample with that version
- compile the bridge against the same version
- run MockDeviceKit lifecycle/camera fixture
- record API differences from this note
- update this document when symbols/signatures differ

This keeps the repository from freezing guessed or stale SDK signatures into the public adapter.
