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

## Capability freshness

The SDK-neutral `MetaDATCapabilities` value is currently static for the lifetime of a `MetaDATAdapter`.

Until Core has dynamic capability-change events, the concrete iOS host must advertise conservatively. A capability that depends on a transient grant or experimental module must not be advertised optimistically.

If a previously advertised capability becomes unusable, pending work must fail explicitly and the session should be rebuilt rather than silently pretending the capability remains healthy.
