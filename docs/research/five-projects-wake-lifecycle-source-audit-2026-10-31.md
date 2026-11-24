# Five-project code-level wake and lifecycle audit (2026-10-31)

Primary code files fetched via GitHub connector (source-level verification, **not** device benchmarks):

1. **PortWorld** `IOS/PortWorld/Runtime/Wake/SFSpeechWakeWordEngine.swift`, blob `ebc93c591a228dc3e4365d591e91559ba2fc6193`: uses `SFSpeechRecognizer` and `SFSpeechAudioBufferRecognitionRequest`, appends `AVAudioPCMBuffer` from runtime, configurable locale, `requiresOnDeviceRecognition`, cooldown >=250ms, fallback manual on auth/unavailability, task generation counters, no-recognition-update recovery. Phone-side speech recognition of streamed PCM; **not** proof of glasses DSP wake.
2. **OpenVision** `OpenVision/Services/Voice/VoiceCommandService.swift`, blob `e16857c60d7e946a1189ac0d62eb9ac4699eb0d6`: `SFSpeechRecognizer(en-US)`, `AVAudioEngine` input tap and Apple Speech recognition, `SpeechActivityDetector` VAD, stale recognition callback generation guard, restart throttling 0.6s. Code comments explicitly describe glasses Bluetooth HFP mic at 8kHz and recognizer restart spin; direct relevant failure modes for AWL audio loop. Uses contextualStrings to bias 'Ok Vision'; not device DSP custom wake.
3. **TurboMeta Android** `android/app/src/main/java/com/smartview/glassai/services/PorcupineWakeWordService.kt`, blob `b6a8b64659caa706b1ebb9c7c6b9d139af5137b3`: Android foreground microphone service, Picovoice Porcupine built-in JARVIS, sensitivity 0.7, 10s debounce, isProcessing reset by QuickVision completion/error, explicit microphone permission, key stored in SharedPreferences. Note code comment recommends encrypted prefs but implementation uses ordinary SharedPreferences; investigate key storage and product licensing. **This is phone-local KWS, not native glasses wake.** iOS implementation is separate Siri App Intents.
4. **Hawky iOS** `ios/Shared/LiveControlIntent.swift`, blob `09a0840d3d5d82edfa5b99477e48550b0e2b706e`: LiveActivityIntent supports open/mute/pause/resume/stop, enqueues action into LiveControlCommandStore; separate OpenLiveIntent sets openAppWhenRun=true. It is OS-mediated session control, **not** proof of hands-free custom on-glasses wake.
5. **CJ GOD MODE** README Vosk phone-local KWS. Actual Android Vosk service path not yet identified in this pass; do not label code-audited.

## Key AWL implications
- Separate wake detection from recognition stream. iOS Speech-based wake requires audio buffers, may keep glasses HFP active; do not claim idle DSP-equivalent battery.
- Audio state machine should have task-generation stale callback guard, bounded restart backoff, on-device recognition capability check, failure/manual fallback, microphone route validity guard.
- Background invocation via Siri/App Intents is fallback, not replacement for 'Alfred' glasses native wake.
- Android Porcupine example demonstrates debounce and active-operation guard, but needs secure key handling and battery tests.
- Visor proprietary on-glasses enrollment remains distinct, with iOS transport unproven.

## Remaining audits
- PortWorld actual audio source / DAT HFP lifetime and test fixtures.
- OpenVision SFSpeech restart loop and source routing across music playback.
- Hawky gateway durable task store, reconnection, authorization and cancellation.
- TurboMeta iOS OpenClaw node device identity, replay/auth and App Intent constraints.
- CJ Vosk lifecycle, WebSocket pairing and approval execution enforcement.
- Cross-project dependency licenses, security audit, RW4006 physical battery and multilingual tests.
