# Audio output

**Getting the agent's spoken reply to the glasses.**

[Research notes](README.md)

## Summary

There is no DAT speaker API. The reply plays through iOS audio over Bluetooth. Prefer **A2DP** (a standard playback route), keep Speech for input (no HFP needed), and avoid the camera stream while speaking.

## Findings

| Finding | Label |
| --- | --- |
| Output to the glasses uses standard iOS audio over Bluetooth. A2DP gives high-quality output. HFP gives a microphone path at 8 kHz mono. The two are mutually exclusive. | Verified: Wearables docs, microphones and speakers |
| Speech needs no HFP: only text crosses the link. BirdSpotter plays with `.playback` / `.spokenAudio`, only when a Bluetooth output exists, and never sets `.allowBluetoothHFP` for output. | Verified: BirdSpotter `SystemSpokenOutput.swift`, `MicrophoneCapture.swift` |
| A running camera stream stops A2DP playback on the glasses, even without audio streaming. | Verified (open upstream bug): [dat-ios #256](https://github.com/facebook/meta-wearables-dat-ios/issues/256), #312 |
| Camera audio streaming (`StreamConfiguration.audioCodec`, PCM at 16/44.1/48 kHz) can provide raw glasses-microphone audio, but it needs a camera stream and camera permission, and the capture LED is on. | Verified: `plugins/mwdat-ios/skills/audio-streaming/SKILL.md`; dat-ios #318 |
| HFP and CallKit-based approaches conflict with firmware that ends DAT sessions during calls. | Verified: dat-ios #332 |
| A Korean `AVSpeechSynthesizer` reply was heard on the glasses during this project's run. The same reply was also heard from the gateway host's speaker once, cause unknown. | Observed here ([validation log](validation-log-2026-10.md)) |

## Ducking music during the reply (2026-10-14)

| Finding | Label |
| --- | --- |
| Ducking starts when the app's audio session **activates** and ends when it **deactivates**, not when the option flag changes. | Verified: Apple `duckOthers` documentation |
| With `AVSpeechSynthesizer.usesApplicationAudioSession = false`, the system creates a separate session that manages "mixing and ducking the speech with other audio sources". Whether other apps' music is ducked is not documented. | Verified (docs) / Unverified (behaviour) |
| Navigation apps (OsmAnd, Organic Maps) duck by calling `setActive(true)` before each prompt and `setActive(false, .notifyOthersOnDeactivation)` after it. Under DAT this is the riskiest pattern (see the `setActive` rule in background notes). | Verified: their source code |
| iOS has no API to change another app's volume. `MPVolumeView` changes system volume; `systemMusicPlayer` controls Apple Music only. | Verified (by absence) |
| AgentWearLink default: the session is configured once and replies mix over music. Two ducking variants are opt-in experiments to be measured on hardware. | Design decision |

Route guard: only speak when the output is Bluetooth A2DP, Bluetooth LE or headphones, so a dropped glasses link never makes the reply play aloud on the phone (BirdSpotter does the same check). Never set `.allowBluetoothHFP` or `.defaultToSpeaker`.

## Reply voice (2026-10-15)

Decision: the reply voice comes from a **local model only**. Reply text does not go to a cloud TTS service.

| Finding | Label |
| --- | --- |
| Apple's on-device Korean voices include no natural male voice suited to a persona, and Siri voices are not available to third-party apps. | Reported: Apple Developer Forums; Unverified on the phone (list voices on the device) |
| Personal Voice does not support Korean, and third-party use needs the app in the foreground. | Verified: [iOS feature availability](https://www.apple.com/ios/feature-availability/) / Reported (foreground) |
| Local candidates with Korean: Qwen3-TTS (Apache-2.0, voice design from a text description or a short clone), CosyVoice (Apache-2.0), MeloTTS-Korean (single stock voice). Latency and memory on a small gateway host are unmeasured. | Verified: model cards ([Qwen3-TTS](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base), [MeloTTS-Korean](https://huggingface.co/myshell-ai/MeloTTS-Korean)) / Unverified (performance) |
| The OpenClaw gateway can synthesise a reply with `tts.speak` (scope `operator.write`) and return the whole clip as base64; it can point its OpenAI-compatible provider at a local server. Nothing streams. | Verified: OpenClaw TTS docs |
| The app can schedule returned PCM on a player node in its existing audio engine, so no audio-session change is needed. Keep the on-device voice as the fallback. | Unverified (design) |

For context only: cloud services (ElevenLabs, Azure, Google, OpenAI and others) offer Korean male voices and style control with low first-byte latency, but they would send every reply to a third party, so they are out of scope.
