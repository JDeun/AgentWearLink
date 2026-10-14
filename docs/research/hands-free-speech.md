# Hands-free speech

**How to let the wearer talk to their own agent without saying "Hey Meta" each time.**

[Research notes](README.md)

## Recommended shape (DAT 1.0.x)

1. Keep one `DeviceSession` running with Speech attached. Don't attach a camera.
2. Match an app-owned wake word (for example the agent's name) on **final** transcripts. Use a double tap as a toggle-to-talk backup.
3. Mute recognition while the reply is spoken and for a short tail afterwards (echo gate).
4. Restart Speech when it stops by itself. Create a new session when the session stops.
5. Use "Hey Meta, open {app}" only to cold-start the app.

Meta's own sample, **BirdSpotter**, follows this pattern: "A run with the glasses is listening for the whole of its length… no button frames it, no wake word opens it" (`samples/BirdSpotter/.../RealtimeViewModel.swift`).

## Speech

| Finding | Label |
| --- | --- |
| Speech is on-device recognition on the glasses. Add it after the session reaches `.started`, and register listeners before `start()`. It needs `Permission.microphone`. | Verified: `plugins/mwdat-ios/skills/speech/SKILL.md` |
| Transcripts arrive as partial and final `TranscriptionResult` values. `confidence` is `-1` when unavailable, and such results should not be discarded. | Verified: speech skill |
| Speech "can stop after inactivity, a timeout, or another performance constraint". No maximum duration is documented. | Verified: [Speech docs](https://wearables.developer.meta.com/docs/develop/dat/speech/) |
| `stop()` keeps Speech attached and allows another `start()`. `removeSpeech()` is terminal. | Verified: speech skill |
| BirdSpotter revives Speech after an unrequested `.stopped`, with 3 attempts 750 ms apart. Taking a photo stops Speech. | Verified: `DatGlassesSessionRepository.swift` (BirdSpotter) |
| Speech hears the app's own spoken reply. BirdSpotter mutes recognition for 4 s after a reply and drops transcripts that overlap recent replies. | Verified: `RealtimeViewModel.swift` (BirdSpotter) |
| `locale` is read-only, with no setter. | Verified: `MWDATSpeech.swiftinterface` |
| Korean transcripts work on real glasses (Android, Korean account, Developer Mode). | Verified: dat-android discussion #209 (developer report, confirmed in Meta staff reply) |
| German transcripts work on iOS. | Reported: dat-ios #311 |
| Korean Speech on iOS, and whether the locale follows the Meta AI app language. | Unverified |
| How an agent name such as "Alfred" or "알프레드" is transcribed. Matching may need variants. | Unverified |
| Developer Mode enables Speech and Inputs without Developer Center approval. A block shows up as `SpeechError.unavailable` on `start()`. | Reported: dat-ios #311, #312, #336 (Meta staff on #336) |
| Speech, Inputs and Voice Invocations are experimental. They work in development and beta channels and cannot ship to production channels yet. | Verified: CHANGELOG 1.0.0, skills |

## Inputs (touch and buttons)

| Finding | Label |
| --- | --- |
| `MWDATInputs` delivers `nav`, `select`, `back`, `button`, `capture` and `drag` events to a started session. | Verified: `plugins/mwdat-ios/skills/inputs/SKILL.md` |
| On Ray-Ban Meta the **single tap** (pause/resume) and **tap-and-hold** (stop) belong to the system. Apps never receive them. | Verified: Inputs docs "Interactions reserved by the device", [dat-ios #312](https://github.com/facebook/meta-wearables-dat-ios/issues/312) |
| A **double tap** reaches the app as `.select(source: .captouch)`. A swipe arrives as `.nav`. | Verified: same sources |
| There are no touch-down or touch-up events, so true hold-to-talk is impossible. It has been requested. | Verified: dat-android #204 |
| Without `consumeBack`, a back swipe ends the running experience and takes the session down. BirdSpotter consumes Back and subscribes to `.captouch`, `.captureButton` and `.actionButton`, because narrower subscriptions once went silent. | Verified: BirdSpotter `DatGlassesSessionRepository.swift` |
| A short press of the capture button paused the session during a camera stream. | Reported: dat-ios #312 |

## Coexistence with Meta AI

| Finding | Label |
| --- | --- |
| "Hey Meta" is a system-owned transaction. A system gesture that opens another experience changes the app's session state. | Verified: session-lifecycle skill |
| Only one DAT app can use the glasses at a time. | Verified: BirdSpotter README |
| Whether Speech also transcribes "Hey Meta …", and whether the session pauses or stops, is not documented. | Unverified (test on hardware) |
