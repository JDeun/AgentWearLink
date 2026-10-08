# Meta DAT cross-audit findings

Audit date: 2026-10-06

Reference surfaces compared:
- Meta CameraAccess sample
- Meta DisplayAccess sample
- Meta BirdSpotter sample
- AWL `Adapters/MetaDAT`
- AWL SDK-neutral `AgentWearLinkMetaDAT`

This file preserves the 2026-10-06 cross-audit findings and their resolution status. For current implementation status, use `Adapters/MetaDAT/INTEGRATION.md`; do not treat historical `PR pending/open` wording below as the current backlog.

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
Status: resolved; bounded startup behavior was subsequently merged.

`DeviceSession.start()` is asynchronous with respect to actual readiness. The bridge needs a bounded wait for `.started`.

### F4 — registration loss teardown
Status: resolved in the concrete lifecycle work; registration loss invalidates active capability/session ownership.

Add registration-state observation to the iOS host bridge. When registration becomes non-registered while a session/capability is active:
- stop child capabilities
- stop session
- fail/cancel pending capture/audio work
- mark capability path unavailable
- require a fresh session after registration returns

Do not auto-replay the interrupted interaction.

### F5 — compatibility/device availability
Status: resolved in selected-device/live-readiness handling; physical transition behavior still requires hardware evidence.

Before advertising physical capabilities, track device/link/compatibility state. Incompatible/update-required devices must fail explicitly instead of presenting a nominal camera/speech capability.

### F6 — background ownership policy
Status: code-side lifecycle invalidation/fresh-readiness policy implemented; physical iOS background behavior remains a hardware gate.

The reference iOS host must stop camera/session ownership according to validated DAT/iOS background behavior. A background transition must cancel pending private-media operations and must not retain raw media.

### F7 — live capability advertisement
Status: resolved code-side by live readiness-derived capability semantics; physical permission/device transitions remain validation work.

The SDK-neutral `MetaDATAdapter` maps `session.capabilities` once at initialization. This is acceptable only if the concrete host exposes the conservative intersection of:
- SDK/module support
- device support
- permission/authorization
- currently implemented AWL bridge support

If those facts can change during the adapter lifetime, the capability contract needs an explicit refresh/change mechanism rather than optimistic static advertisement.

### F8 — snapshot one-shot concurrency
Status: code-side bounded capture/cancellation generation handling implemented; physical capture timing remains a hardware gate.

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


## Foreground voice-to-media handoff (2026-10-08; #6/#95)

A Meta `LaunchApp` Voice Invocation is **not a dictation payload**; its
acknowledged normalized event carries no question text. An independent listener
can therefore wake the app/Core without producing an agent request or speech
reply. A follow-on DAT Speech session is required to accept the user's actual
utterance on the reference host.

The opt-in `MetaDATVoiceWakeDeviceAdapter` starts only Voice Invocation when
Core connects. Its vendor adapter forwards a successful acknowledgement event
first and **then**, in a separate task, conditionally starts DeviceSession and
DAT Speech *only if* the iOS host reports foreground phase. The admission gate
rejects overlapping connects, stopped ownership and already-ready media.
Failures are nonterminal capability diagnostics; no speech or camera access is
attempted merely by constructing/connecting the wake adapter.

This is an optional production composition layer, not proof of OS-delivered
cold launches, background entitlements, secure credential persistence, or
wearable speaker output. The test-only app-hosted MockDeviceKit scenario now
includes a launch → foreground DAT Speech → final transcript → Core → isolated
MockAgentAdapter output assertion; it must pass the pinned iOS CI before being
counted as evidence. The production reference-host UI still needs an explicit
opt-in mode wired to this new adapter. Physical locked/pocketed-device
acceptance remains #6.
