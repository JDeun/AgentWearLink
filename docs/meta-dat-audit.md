# Meta DAT cross-audit findings

Audit date: 2026-10-06

Reference surfaces compared:
- Meta CameraAccess sample
- Meta DisplayAccess sample
- Meta BirdSpotter sample
- AWL `Adapters/MetaDAT`
- AWL SDK-neutral `AgentWearLinkMetaDAT`

This file is a living implementation audit. Items are evidence-backed observations, not assumptions about undocumented SDK behavior.

## Confirmed patterns

### Subscribe before start/connect

Meta CameraAccess obtains/installs state and error observation before `DeviceSession.start()`. AWL must do the same at both boundaries:

1. concrete MWDATCore host session
2. SDK-neutral `MetaDATSession` adapter

Reason: initial lifecycle/error transitions can occur while start/connect is in flight.

### Registration is live state

Meta samples continuously observe `registrationStateStream()`; they do not treat successful registration as permanent configuration.

DisplayAccess resets its active display/session path when registration becomes `.available` or `.unavailable`.

AWL implication: an active concrete DAT bridge must tear down its capabilities/session if registration is lost. Registration loss must not leave capabilities advertised as usable.

### Device availability and compatibility are live

CameraAccess watches `devicesStream()` and per-device compatibility. BirdSpotter also watches link/compatibility/device state.

AWL implication: `AutoDeviceSelector` alone is not sufficient evidence that the selected glasses remain usable. Physical bridge work must define behavior for:
- device disappears
- link disconnects
- device update required
- SDK update required
- glasses DAT app update required

### Background camera lifecycle is explicit

CameraAccess stops an active camera session when iOS enters background and bounds suppression of teardown errors.

AWL implication: camera ownership cannot assume a stream survives app backgrounding. Pending snapshot capture must fail/cancel promptly; foreground recovery creates a fresh capability/session rather than replaying capture.

### Permission redirects are asynchronous

Camera permission is checked first; requesting permission can switch to Meta AI and later return through the DAT URL callback/state.

AWL implication: permission acquisition belongs to the iOS host/UI boundary. Core should see capability unavailable/authorized state, not Meta redirect mechanics.

## Findings / work items

### F1 — SDK-neutral connect-time event race
Status: fix prepared in PR #75.

`MetaDATAdapter` previously called `session.connect()` before consuming `session.events()`. A host could emit a lifecycle/failure event during connect and lose it.

### F2 — concrete session observation ordering
Status: fixed and merged in PR #72.

Concrete MWDATCore scaffold now obtains state/error streams before `session.start()` and avoids switching to a second state stream after startup.

### F3 — unbounded concrete startup
Status: PR #73 pending.

`DeviceSession.start()` is asynchronous with respect to actual readiness. The bridge needs a bounded wait for `.started`.

### F4 — registration loss does not currently tear down concrete AWL session
Status: open.

Add registration-state observation to the iOS host bridge. When registration becomes non-registered while a session/capability is active:
- stop child capabilities
- stop session
- fail/cancel pending capture/audio work
- mark capability path unavailable
- require a fresh session after registration returns

Do not auto-replay the interrupted interaction.

### F5 — compatibility/device availability not yet wired
Status: open.

Before advertising physical capabilities, track device/link/compatibility state. Incompatible/update-required devices must fail explicitly instead of presenting a nominal camera/speech capability.

### F6 — background ownership policy not yet wired
Status: open.

The reference iOS host must stop camera/session ownership according to validated DAT/iOS background behavior. A background transition must cancel pending private-media operations and must not retain raw media.

### F7 — capability advertisement is currently construction-time static
Status: open design constraint.

The SDK-neutral `MetaDATAdapter` maps `session.capabilities` once at initialization. This is acceptable only if the concrete host exposes the conservative intersection of:
- SDK/module support
- device support
- permission/authorization
- currently implemented AWL bridge support

If those facts can change during the adapter lifetime, the capability contract needs an explicit refresh/change mechanism rather than optimistic static advertisement.

### F8 — snapshot one-shot concurrency still needs concrete-host enforcement
Status: SDK-neutral boundary in PR #74; concrete host pending.

The MWDATCamera host must allow at most one pending capture per owned camera stream unless the pinned SDK explicitly proves safe concurrency. It must pair one capture request with one result, and fail on timeout/disconnect/background.

## Physical-only validation

MockDeviceKit cannot close:
- Bluetooth/link transition behavior
- real microphone/speaker routing
- lock-screen/background wearable invocation
- firmware/device compatibility behavior
- Wi-Fi/cellular/Tailnet transitions
- real camera latency and capture reliability

Keep #1, #5, #6, #58 and #59 open until physical evidence exists.
