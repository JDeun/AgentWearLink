# Meta DAT 1.0.1 follow-up: upstream field reports and AWL validation matrix (2026-10-31)

## Scope and epistemic status
This follow-up supplements `meta-dat-ios-upstream-refresh-2026-10-31.md`. Public upstream GitHub issues are **unverified user reports**, not confirmed SDK defects or universal reproduction. SDK changelog 1.0.1 says "No developer-facing changes", but this does **not** mean runtime regression-free.

Primary evidence:
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md
- https://github.com/facebook/meta-wearables-dat-ios/blob/main/README.md
- https://github.com/meta/meta-wearables-dat-ios/issues

## Risk-focused upstream issue inventory
| Upstream | Reported symptom | AWL relevance | Validation / mitigation |
|---|---|---|---|
| [#324](https://github.com/meta/meta-wearables-dat-ios/issues/324) | Camera stream internal heap grows without release in 1.0.0 | **P0** camera/vision long-running use; AWL #303 already tracks | Measure RSS/heap over repeated 1/5/15-minute stream lifetimes on pinned vs 1.0.1; bounded stream tenure; verify release after stop |
| [#356](https://github.com/meta/meta-wearables-dat-ios/issues/356), [#354](https://github.com/meta/meta-wearables-dat-ios/issues/354) | 1.0.1 streaming state reaches ready but no video frames / glasses Wi-Fi join failure | **P0** snapshot from camera stream can stall | Assert first-frame deadline, transport/link diagnostics, explicit timeout and no stale frame reuse |
| [#332](https://github.com/meta/meta-wearables-dat-ios/issues/332), [#342](https://github.com/meta/meta-wearables-dat-ios/issues/342) | Session ends during streaming / HFP mic connection | **P0** simultaneous speech/audio/camera may contend | Matrix: camera only, HFP only, camera+HFP in both orders; cancel owned operations on session loss |
| [#344](https://github.com/meta/meta-wearables-dat-ios/issues/344), [#355](https://github.com/meta/meta-wearables-dat-ios/issues/355), [#345](https://github.com/meta/meta-wearables-dat-ios/issues/345) | Voice launch not delivered; device type/link compatibility/release channel dependent | **P0** hands-free invocation | Cold launch, registered vs not, different Meta account locales, device models, app distribution channel; observe SDK channel state and ACK only on delivery |
| [#336](https://github.com/meta/meta-wearables-dat-ios/issues/336), [#360](https://github.com/meta/meta-wearables-dat-ios/issues/360) | Speech attachment returns nil / repeated sessions stop yielding transcriptions | **P1** Speech-first path | 100+ repeat starts, partial/final lineage, permission and session teardown; fail closed, no phantom mic capability |
| [#347](https://github.com/meta/meta-wearables-dat-ios/issues/347) | Audio PTS about 200ms offset from video | **P1** audio/video synchronization if implemented | Record source timestamp and monotonic clock; do not assume zero offset |
| [#318](https://github.com/meta/meta-wearables-dat-ios/issues/318) | Camera capture LED illuminated during audio streaming; no independent mic stream | **P1** user-facing privacy and battery | Explicit indicator/consent; audio tied to Camera Stream; never advertise independent audio capture |
| [#363](https://github.com/meta/meta-wearables-dat-ios/issues/363) | Standalone photo over slow link, 165s in reported case | **P2** future high-resolution stills | Capture transfer timeout, progress, optional size caps; do not replace existing stream snapshot baseline |
| [#329](https://github.com/meta/meta-wearables-dat-ios/issues/329) | Motion samples unavailable on one device | **P2** optional IMU | Gate by hardware model and actual sample delivery, not SDK type availability |
| [#327](https://github.com/meta/meta-wearables-dat-ios/issues/327) | Crash when device storage full in SDK logger | **P1** stability | Full-storage host stress, log handling, diagnostics retention and failure isolation |

## Audio capture architecture decision
Two routes are distinct:
1. **DAT camera-associated PCM** (experimental): `StreamConfiguration.audioCodec` + `audioFramePublisher`, 16/44.1/48 kHz, Camera and microphone grants, streaming camera lifecycle, no deterministic MockDeviceKit audio-frame injection. A real hardware proof is required.
2. **iOS Bluetooth HFP audio route**: OS-level `AVAudioSession` route, not the DAT camera PCM transport. Upstream issue [#159](https://github.com/facebook/meta-wearables-dat-ios/issues/159) describes this distinction. Explicitly verify that the selected input port is the glasses rather than iPhone microphone; refuse or label fallback rather than silently misattribute audio.

Potential route selection: `AudioSource = .datCameraPCM | .bluetoothHFP | .phoneMicrophone` with explicit provenance, no simultaneous assumptions, bounded buffer, interruption handling, and device generation ownership. No public DAT guarantee of a microphone-only stream or production publication for experimental PCM.

## Test matrix to execute
- SDK pin `1f38beec...` vs 1.0.1 tag on the same Xcode/iOS/Meta AI/firmware/device combinations.
- Ray-Ban Meta supported device and Ray-Ban Display, plus unsupported devices must fail with typed reason; no blanket support claims.
- Registration: never, delayed, revoked, recovered; link: roster-before-connect, disconnect, re-pair; Voice: exactly-one ACK and recovery from error without roster change.
- Camera: stream started but zero frames, first-frame timeout, photo rejected, stream stopped, background/foreground, device thermal, memory pressure and 15-minute heap observation.
- Audio: Camera PCM first frame within 5 seconds vs absent, HFP route absent vs active, permission revoked, simultaneous camera/HFP in both orders, audio/video timestamps.
- Speech: partial/final confidence -1, repeat sessions, nil addSpeech, locale change, interrupted session.
- Telemetry: explicit MWDAT.Analytics.OptOut and CrashReporting.OptOut policy; inspect built Info.plist and document expected behavior.
- For each case capture device model, SDK SHA/tag, iOS, Meta AI, firmware, Developer Mode/release channel, steps, timestamp, result, logs redacted; do not publish identifiers or tokens.

## AWL issue routing
- Existing umbrella #644: pin/telemetry/voice.
- Existing #303: camera heap growth.
- Existing #249: no rawAudioInput without concrete bounded owned transport.
- Existing #5: wearable audio-to-agent-to-TTS E2E.
- Existing #1/#98: physical baseline.
- Existing #95/#115/#145/#146: voice lifecycle/ACK/reopen.
- New scoped follow-up: physical compatibility and regression matrix across 1.0.1 camera, HFP, voice and Speech; do not duplicate existing implementation issues.

## Evidence limitation
Desk audit only; no local iOS Xcode build or physical hardware. Public issues are reports, not reproduced facts. Check issue status and upstream fixes before attributing to a specific SDK version.
