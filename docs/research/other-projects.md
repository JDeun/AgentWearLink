# Other projects

**Open-source projects that connect Meta glasses to their own agents, and what their hardware experience teaches.**

[Research notes](README.md)

> [!NOTE]
> These are ideas and field reports only. Respect each project's license. For example, OpenGlasses is BSL 1.1 (no commercial use until 2030), so none of its code is copied here.

| Project | Mechanism | Lessons |
| --- | --- | --- |
| [straff2002/OpenGlasses](https://github.com/straff2002/OpenGlasses) (TestFlight "Avenkin") | Custom wake word on iPhone `SFSpeechRecognizer`; includes an OpenClaw gateway client; links only MWDATCore, MWDATCamera and MWDATDisplay | Does not use Speech, Inputs or Voice Invocations as a matter of policy ("experimental … unpublishable"), so it has no data on DAT Speech. Its idle wake word moved from the glasses microphone to the iPhone microphone because HFP ruined music. AVAudioEngine stops on input sample-rate changes, so it observes `AVAudioEngineConfigurationChange`. A Korean recognizer writes the Latin name "avenkin" as "아벤킨", so it fixed exact matching with jamo-level edit distance. It removed a fake CallKit keep-alive before review. Its maintainer filed dat-ios #292. |
| [shahdadk/glance-qm](https://github.com/shahdadk/glance-qm) | MWDATSpeech + Display, tested on real glasses | Speech gave partial and final transcripts on hardware. It restarts Speech after 400 ms and gives up after 3 quick stops. It logs `localePublisher`. Its docs say locked-phone Speech is "not guaranteed", and it turns off auto-lock during capture. |
| [locafra/hey-casa](https://github.com/locafra/hey-casa) (Android) | Speech per utterance | "Transcription on the glasses follows the language of the glasses." |
| [TheFreal/ytm-meta](https://github.com/TheFreal/ytm-meta) (Android) | Music app + voice invocation | Acknowledges invocations immediately "so Meta AI releases the mic before we listen". |
| [ColinHu07/SituationalAwareness](https://github.com/ColinHu07/SituationalAwareness) | Camera + spoken cues | A2DP speech reported `didStart` and `didFinish`, but nothing was audible while camera capture ran (dat-ios #256). |
| [Allendior/rayban-meta-glasses-hermes](https://github.com/Allendior/rayban-meta-glasses-hermes) | Tap-to-talk Speech → Tailscale → agent | Not continuous listening. |

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
