# Hands-free alternatives

**Every approach considered for "say the agent's name, get an answer in the glasses" with the phone locked and music playing, ranked against that requirement.**

[Research notes](README.md)

Requirement:
- The wearer says "<agent name>, <request>" naturally, without "Hey Meta" and without "send a message to…".
- The phone may be locked, in a pocket, in a bag or in another room within Bluetooth range.
- Music playing through the glasses must keep working.

## Ranking

| Approach | Locked phone | Phone away from the user | Music | Indicator | Verdict |
|---|---|---|---|---|---|
| **DAT Speech on the glasses** (chosen) | Unverified. Speech-only sessions have no public locked-phone evidence. | Yes: the microphone is on the glasses | Expected unaffected: only text crosses the link. Unverified. | None known (the LED is camera-only) | Best fit; validate on hardware |
| Wake word on the **iPhone** microphone, glasses microphone (HFP) only during a turn | Yes, if started in the foreground. Reported by one project. | **No**: fails in a bag or in another room | Hi-fi while idle; paused during a turn | iOS orange microphone dot | Fallback when the phone is near |
| Glasses microphone over HFP, always on | Yes. Reported by several projects. | Yes | **Call quality the whole time** | iOS orange microphone dot | Only usable with no music playing |
| Camera stream (hvc1) as a session "spine" | Yes. Verified in code with measurements. | Yes | **Music stops** about 2 s after the stream starts, at any fps | **Capture LED on** | Rejected |
| Motion or Inputs as a spine | No evidence; Motion times out after 10 s on Gen 1 | — | — | — | Rejected |
| Apple PushToTalk | Needs a button or Bluetooth peripheral event | — | — | — | No voice trigger |
| Meta AI Connectors (MCP) | Waitlisted preview | — | — | — | No custom invocation name; no Korean |
| Messaging relay ("Hey Meta, send a message to …") | Works | Yes | Yes | — | Rejected as unnatural speech |

A hybrid is possible if DAT Speech fails when locked:
- **No music playing:** use the always-on glasses HFP microphone.
- **Music playing:** use the iPhone-microphone wake word.

The app can tell which case applies from `AVAudioSession.isOtherAudioPlaying`.

## Evidence

| Finding | Label |
| --- | --- |
| Each "Hey Meta" request general enough not to name the app goes to Meta AI and cannot be handed to an app. | Verified: Meta staff, dat-android discussion #209 |
| Opening the glasses microphone from any app moves the link to HFP (mono, narrowband), so music drops to call quality. | Reported (device log): OpenGlasses `docs/plans/GU-wake-word-audio-and-power.md` |
| A camera stream pauses A2DP playback and never resumes it, at 24, 15 or 7 fps, even with no audio codec. Open upstream bug. | Verified: [dat-ios #256](https://github.com/facebook/meta-wearables-dat-ios/issues/256), #312 measurements |
| The capture LED is on whenever the camera runs; there is no microphone-only stream. | Verified: Meta staff, dat-ios #318, #337 |
| Motion times out after 10 s on Ray-Ban Meta Gen 1 firmware 128/129. | Reported: dat-ios #320 |
| PushToTalk `requestBeginTransmitting` works only in the foreground or after a CoreBluetooth peripheral event. | Verified: Apple PushToTalk documentation |
| Meta AI Connectors are an early-access preview; connectors built in the preview are not yet available to the public. | Verified: dev.meta.ai/products/connectors |
| Picovoice Porcupine supports Korean custom wake words on iOS (cheaper than continuous ASR). | Verified: Picovoice documentation |
| The phone's microphone cannot hear the wearer from a bag or another room. Any approach needs the phone within Bluetooth range, since the glasses reach the internet through it. | Inferred |
