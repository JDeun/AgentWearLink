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
