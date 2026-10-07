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

## Host ownership

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

Current mapping rule:

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

The concrete integration now contains bounded one-shot camera capture machinery: camera configuration/ignition, first-frame readiness, shutter/photo-result handling, photo normalization, capture generations, cancellation/late-result rejection, and deterministic mock fixtures.

The invariant remains:

- explicit request only;
- bounded capture lifetime;
- permission/readiness before capture;
- JPEG/PNG copied into bounded `ImageAttachment`;
- no continuous raw-frame retention by AWL;
- obsolete/late capture results are rejected;
- disconnect/background invalidation fails pending work rather than replaying it.

Physical sensor wake, shutter timing, transfer reliability, and memory behavior remain hardware validation gates.

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

## Foreground/background ownership on the concrete adapter

Hosts may inject `MetaDATApplicationLifecycle` into
`MetaDATDeviceAdapter(applicationLifecycle:)` and forward UIKit/SwiftUI
foreground/background phase transitions. The vendor-linked adapter subscribes
before session registration/start; the latest phase is replayed to close the
preflight/subscription race. Background immediately retires the owning
DeviceSession generation, invalidates pending camera/Speech operations,
clears live capability bits and emits a terminal device failure so Core also
retires active interactions. Foreground does **not** implicitly reconnect or
replay an uncertain agent/photo request: the host must explicitly start a
fresh runtime generation. Injection is optional to preserve test/reference
compatibility, but a production UI must supply it to claim lifecycle coverage.

Mock and CI tests cannot prove physical lock-screen or iOS suspension timing;
those remain on #96/#116 and #1/#59.
