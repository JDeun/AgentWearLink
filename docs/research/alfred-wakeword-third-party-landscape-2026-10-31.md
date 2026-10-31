# Custom wake-word ecosystem: OpenVision, Hey James, Voice Bridge (2026-10-31)

## Research question
Can AgentWearLink recognize **'알프레드'** without saying Hey Meta, while preserving battery, media controls, DAT camera and release eligibility? Distinguish third-party phone-side detection from privileged glasses DSP wake engine registration.

## Source comparison
| Project | Primary source | Reported implementation | Critical qualification |
|---|---|---|---|
| OpenVision | https://github.com/rayl15/OpenVision ; https://github.com/rayl15/OpenVision/releases | 'Ok Vision' primed speech recognition and self-restart, doff/redon, barge-in, chime and 'stop' | README/release claims; exact code path and locked/background energy not audited; no Meta DSP custom wake registration proven |
| Hey James | https://crookse.com/journal/2026-03-21-ray-ban-meta-development-day-03 | Porcupine 'Hey James', 16kHz mono Int16 and 512-frame input, initial rearm limitation | Developer account; model licensing and glasses PCM transport need source verification; not DSP registration |
| Meta Glasses Voice Bridge | https://github.com/ethanpaschkes/meta-glasses-voice-bridge | HFP 8kHz mono + iOS AVFoundation; explicit Action Button starts optional hands-free listening; 'hey jarvis' fuzzy phrase matching | README explicitly warns HFP keeps glasses in call mode, drains ~2x and blocks music; claim needs measurement; no always-on hardware wake |

## Specific source details
OpenVision README claims primed recognition with self-restart, wake-word chime, doff/redon resilience, and barge-in. v2.5.0 release says chime plays through glasses and repeated wake words no longer cause Bluetooth reconnect blip; tested by author on iPhone 17 Pro and Ray-Ban Meta. Not independent benchmark.

Voice Bridge README describes glasses audio via ordinary Bluetooth HFP rather than DAT microphone API, at 8kHz mono; AVAudioSession route indicator shows whether actual glasses mic is active. Hands-free mode begins with an iPhone Action Button / Siri / Back Tap; wake phrase is configurable ('hey jarvis') while session is running. It reports call-mode drain and blocked music; therefore it explicitly rejects 24h always-on as default. Voice Bridge source path names include ios/VoiceBridge/{WakeWord,ListeningSession,VoiceCapture,ToggleListeningIntent}.swift; check current commit before using.

Hey James developer journal reports Porcupine keyword model fed 16kHz PCM and first-trigger working, with restart/rearm problem; check whether code is available and how source PCM is captured before adopting.

## Constraints
1. No verified public API for writing custom wake phrase into Meta's low-power detector; upstream https://github.com/meta/meta-wearables-dat-ios/discussions/343 acknowledges proposal without commitment.
2. Distinguish **KWS inference energy** from **Bluetooth HFP radio/call-mode energy**; tiny model alone does not fix glasses battery drain.
3. DAT experimental Camera-associated PCM is not independent always-on microphone and is not publishable in production at present.
4. DAT Speech is experimental and Meta reported ~60s recognition-run end with missing stopped state in 1.0.x: https://github.com/meta/meta-wearables-dat-ios/issues/360 .
5. Third-party repo claims are unverified until source, license and physical device evidence are collected.

## Tracked issues
- #652 OpenVision source/lifecycle audit
- #653 Hey James/Porcupine audit
- #654 Voice Bridge HFP/session audit
- #655 AWL Alfred wake-source design and benchmark
- Existing #648 upstream low-power API, #649 tap/media, #650 doff/redon, #651 Speech timeout, #646 hardware regression

## Decision gates
Do not default to 24h HFP or experimental DAT Speech. Prototype in bounded, explicit user listening windows; compare false wake/hour, miss rate, p95 wake latency, actual microphone provenance, screen locked behavior, music interruption, battery and thermal. Use vendor-neutral wake-source interface and do not copy third-party code until license review.

Status: research and issue registration only; no source-level full audit, physical validation, code integration or PR merge performed.
