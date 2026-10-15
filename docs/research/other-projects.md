# Other projects

**Open-source projects that connect Meta glasses to their own agents, and what their hardware experience teaches.**

[Research notes](README.md)

> [!NOTE]
> These are ideas and field reports only. Respect each project's license. For example, OpenGlasses is BSL 1.1 (no commercial use until 2030), HackGT-Violet has no license (all rights reserved), and Meta's samples and their forks fall under the Meta Wearables Developer Terms, so none of their code is copied here.

| Project | Mechanism | Lessons |
| --- | --- | --- |
| [straff2002/OpenGlasses](https://github.com/straff2002/OpenGlasses) (TestFlight "Avenkin") | Custom wake word on iPhone `SFSpeechRecognizer`; includes an OpenClaw gateway client; links only MWDATCore, MWDATCamera and MWDATDisplay | Does not use Speech, Inputs or Voice Invocations as a matter of policy ("experimental … unpublishable"), so it has no data on DAT Speech. Its idle wake word moved from the glasses microphone to the iPhone microphone because HFP ruined music. AVAudioEngine stops on input sample-rate changes, so it observes `AVAudioEngineConfigurationChange`. A Korean recognizer writes the Latin name "avenkin" as "아벤킨", so it fixed exact matching with jamo-level edit distance. It removed a fake CallKit keep-alive before review. Its maintainer filed dat-ios #292. |
| [shahdadk/glance-qm](https://github.com/shahdadk/glance-qm) | MWDATSpeech + Display, tested on real glasses | Speech gave partial and final transcripts on hardware. It restarts Speech after 400 ms and gives up after 3 quick stops. It logs `localePublisher`. Its docs say locked-phone Speech is "not guaranteed", and it turns off auto-lock during capture. |
| [locafra/hey-casa](https://github.com/locafra/hey-casa) (Android) | Speech per utterance | "Transcription on the glasses follows the language of the glasses." |
| [TheFreal/ytm-meta](https://github.com/TheFreal/ytm-meta) (Android) | Music app + voice invocation | Acknowledges invocations immediately "so Meta AI releases the mic before we listen". |
| [ColinHu07/SituationalAwareness](https://github.com/ColinHu07/SituationalAwareness) | Camera + spoken cues | A2DP speech reported `didStart` and `didFinish`, but nothing was audible while camera capture ran (dat-ios #256). |
| [Allendior/rayban-meta-glasses-hermes](https://github.com/Allendior/rayban-meta-glasses-hermes) | Tap-to-talk Speech → Tailscale → agent | Not continuous listening. |
| [grahamonica/HackGT-Violet](https://github.com/grahamonica/HackGT-Violet) | Continuous MWDATSpeech listening for the name "Violet", plus the capture button and "Hey Meta, start Violet", all into one trigger | The closest analogue to AgentWearLink. Its code describes the same two Speech behaviours seen here: about 3 empty events a second in silence, and a deaf state that a restart cures. Its watchdog keeps two clocks (any event, non-empty text) and restarts with stop, 600 ms, start. Its "deaf" rule also fires every 20 s in a quiet room, the churn our backoff removes. It accepts a hardware-learned alias ("vista" for "Violet"). It ends a question on a 0.8 s pause and needs at least two real words. It stops collecting before speaking, so its own reply is never transcribed. It plays a wake chime and cached fillers after 3 s. It plays replies over A2DP and never opens the glasses' HFP mic. |
| Meta BirdSpotter sample ([dat-ios](https://github.com/facebook/meta-wearables-dat-ios)) | Continuous Speech next to camera, Inputs, Motion and Display | `addSpeech` leaves Speech stopped until `start()`. It revives only a recogniser that had started, with bounded retries. A photo stops Speech, so it is revived afterwards. On Android, results arrive on a `StateFlow`, which drops a result equal to the previous one. |
| [Intent-Lab/VisionClaw](https://github.com/Intent-Lab/VisionClaw) and [VisionClaw-handsfree](https://github.com/Chip1210/VisionClaw-handsfree) | HFP audio to a realtime model; no Speech | Synthesised earcons (connected, lost, reconnected) need no assets. The hands-free fork uses a double press, "two rising beeps", and keeps a standby HFP mic open because iOS will not start recording in the background; it warns that HFP sounds like a phone call. |
| [handzlikchris/Glasscast](https://github.com/handzlikchris/Glasscast) | Evaluated Speech, chose HFP recording | Dictation needs no DAT: record the HFP mic and transcribe on the phone or PC. |
| [jsala1/dashhound](https://github.com/facebook/meta-wearables-dat-ios/discussions/322) | Locked-phone camera streaming | Measured 7 min 14 s of locked streaming with a silent-audio loop, and video back within 8 s of unfolding while the app was alive. |
| [loopandlearn/LoopFollow](https://github.com/loopandlearn/LoopFollow) (not glasses) | Pending Bluetooth connect to another vendor's device | The precedent for waking on reconnect instead of keeping a silent-audio keep-alive (see [waking the app](waking-the-app.md)). |

## Speech lessons for AgentWearLink

- Back off quiet-room restarts instead of restarting every 20 s (done: see [glasses battery](glasses-battery.md)).
- Restart Speech when the glasses are put back on or a session resumes, because the deaf state follows re-wear.
- Restart a Speech that stopped by itself only a bounded number of times, then slow down (done).
- Keep a list of name variants seen on the hardware, and normalise spacing before matching.
- Gate the echo of the agent's own reply on playback state plus a short tail, not on a fixed timer.
- Never open the glasses' HFP mic while relying on Speech ([dat-ios #342](https://github.com/facebook/meta-wearables-dat-ios/issues/342)).
- Call `addSpeech` only from the current session's `.started` event (Verified: Meta staff, [dat-ios #336](https://github.com/facebook/meta-wearables-dat-ios/issues/336)).

No public project reports DAT Speech battery or start latency figures.

## OpenClaw clients compared (OpenGlasses vs AgentWearLink)

**Shared:**
- protocol v4
- Ed25519 proof at the challenge `ts`
- `gateway-client` id
- idempotency keys

**OpenGlasses only:**
- streams the reply sentence by sentence from deltas
- keeps a late result after a timeout and speaks it later
- strips a JSON TTS control line from replies
- a second node-role socket for remote invoke

**AgentWearLink only:**
- a tick watchdog from `hello.policy`
- device-token handoff
- pairing retry hints
- run recovery across reconnect
- the `agent.wait` grace period
