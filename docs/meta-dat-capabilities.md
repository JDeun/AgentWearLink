# Meta DAT capability contract

Audit date: 2026-10-06

This document narrows AWL capability advertisement to behavior verified in the current public Meta Wearables DAT iOS SDK and samples.

## Speech input

Meta DAT Speech is session-scoped on-device recognition. The phone receives transcription results, not microphone samples.

AWL mapping:
- DAT Speech partial/final transcription -> `speechInput`
- preserve finality/confidence inside the concrete bridge when the Core contract gains those fields
- speech availability must follow the active session/device capability
- do not advertise `rawAudioInput` merely because Speech is available

## Raw audio input

Raw/PCM microphone audio is a separate path from Speech.

Current public examples expose audio associated with the camera stream / active media session, and this surface may have release-channel restrictions. It is not evidence of an always-on, independent wearable microphone transport.

AWL rule:
- advertise `rawAudioInput` only when the pinned SDK/version, target release channel, permission state, selected device, and concrete bridge all support the exact PCM path
- otherwise prefer DAT Speech for wearable transcription
- no phone-microphone fallback may be silently represented as wearable raw audio
- bound buffering and terminate audio immediately on session loss/background/cancellation

## Voice invocation

Voice invocation is not a child of the ordinary `DeviceSession`. It is a separate channel that can be the event which causes the application to establish a session.

Meta AI waits for an invocation response/acknowledgement. The bridge must acknowledge the invocation promptly before starting potentially slow agent work.

AWL rule:
- voice invocation listener waits for registration
- listener follows eligible device/link changes
- invocation acknowledgement is separate from the agent's eventual answer
- channel errors must not permanently disable listening; bounded reopen/backoff is required
- unsupported spoken actions must be explicitly rejected/acknowledged according to the pinned SDK contract, not ignored indefinitely
- invocation must never depend on an already-running camera/session

## Camera snapshot

For streaming camera capture:
- subscribe to photo result/error before triggering capture
- `capturePhoto` can decline to start; a declined capture must fail immediately rather than await an event that will never arrive
- allow one pending AWL snapshot per owned camera stream
- pair the next photo result/error only with that pending request
- timeout, link loss, background, stream stop, or session stop terminates the pending request
- no automatic replay of a capture after uncertain delivery

Meta also documents a standalone high-quality capture surface as experimental. Do not use it in the baseline bridge until the pinned SDK/release channel is validated for the intended distribution.

## Registration, permission, and device selection

Registration and permission are distinct.

A usable physical capability is the conservative intersection of:
1. application registration
2. relevant Meta permission
3. selected device present and link-connected
4. compatible SDK/firmware/DAT-on-glasses version
5. capability supported by that device
6. capability implemented by the AWL concrete bridge
7. lifecycle state currently safe for the operation

Multiple paired glasses must not be resolved by list order. Selection ranks connected+donned above connected above merely compatible devices; equal-rank candidates use the stable `DeviceIdentifier` string as a deterministic lexical fallback until the host provides an explicit remembered/user preference. Once a session is created with `SpecificDeviceSelector`, AWL keeps that device pinned for the session and does not silently switch active work to another pair. Eligibility is re-evaluated only at defined lifecycle boundaries.

Concrete session setup is generation-owned from the moment registration monitoring starts. Registration loss during startup invalidates that generation even before a `DeviceSession` exists; no-device, incompatibility, session-creation/start/wait failures, explicit disconnect, selected-device loss, and unexpected stop all retire the same owned monitor/task set. Late callbacks from a retired generation are ignored and cannot tear down a newer reconnect attempt.

## Capability freshness and interpretation

Core `DeviceAdapter.capabilities` is a synchronous **current-availability snapshot** for production device adapters, not a guarantee that a subsequent operation will succeed. Every operation must still re-check permissions, generation, session and actual bridge readiness at use time; a change between snapshot and use must fail closed. Core has no push-based capability-change event.

Two distinct layers currently coexist:

- **Production `MetaDATDeviceAdapter` (vendor-linked):** the thread-safe `MetaDATLiveCapabilitySource` reports Speech and snapshot only during their owning ready `DeviceSession`. Camera permission must be granted; query errors fail closed. Session teardown clears those bits. Independent Voice Invocation is not advertised until a concrete listener marks it ready. Raw PCM, phone text/TTS, and experimental standalone Camera.photo are not claimed.
- **SDK-neutral `MetaDATAdapter(session:)` test/reference wrapper:** the `MetaDATCapabilities` snapshot taken in its initializer describes the session implementation's *declared support*, **not live readiness**. It exists to exercise deterministic normalization, capture and lifecycle contracts without vendor SDK linkage. Do not use this wrapper's static capability value as a live iOS UI readiness indicator.

During permission revocation, disconnect, background transition, or SDK readiness loss, the vendor adapter must clear affected capabilities at the applicable lifecycle boundary and reject stale in-flight operations. A new foreground/session generation may re-establish availability but never silently replay an uncertain request.

Known follow-ups: independent Voice Invocation listener/availability (#95/#115/#230), physical permission/link races (#1/#98), and production media lifecycle testing (#96/#116). The live availability model should not be mistaken for completion of those features.
