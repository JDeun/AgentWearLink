# Comparative research: CJ GOD MODE, PortWorld, Hawky, TurboMeta, OpenVision (2026-10-31)

## Evidence scope
Primary GitHub README and LICENSE inspected through GitHub connector for CJ, Hawky, TurboMeta, OpenVision. No execution or physical hardware benchmarks. **PortWorld path `armapidus/PortWorld` returned not found and GitHub repository search `PortWorld rayban meta` returned no results; prior recommendation unverified. Do not represent it as a verified repository.** Source claims are not independent measurements.

## Comparison
| Project | Platform | Architecture | License | AWL reuse |
|---|---|---|---|---|
| CJ GOD MODE https://github.com/GhanshyamPaunikar/rayban-meta-god-mode | Android 10+ and Mac | DAT audio -> phone Vosk KWS -> Mac FastAPI WS -> Gemini Live and device tools | MIT verified | streaming, pairing, Mac tool permissions; **not on-glasses wake** |
| PortWorld (claimed armapidus/PortWorld) | unverified | unknown | unverified | HOLD until canonical URL/source verified |
| Hawky https://github.com/hao-ai-lab/hawky | iOS SwiftUI + Bun gateway + web | Realtime conversational frontend, durable background agent, memory, Ray-Ban iOS camera/audio | Apache-2.0 README claim | async tasks, session continuation, gateway; verify implementation |
| TurboMeta https://github.com/Turbo1123/turbometa-rayban-ai | iOS Swift + Android Kotlin | DAT iOS, OpenClaw, Qwen Omni, Siri Shortcuts/App Intents fallback, RTMP | MIT verified | iOS lifecycle and Shortcuts, OpenClaw adapter, multilingual ASR |
| OpenVision https://github.com/rayl15/OpenVision | iOS Swift | Meta DAT, OpenClaw/Hermes/Gemini/OpenAI/Apple/MLX, native tools, wake and barge-in | MIT verified | adapter design, reconnect, session FSM, native tools |

## Specific observations
- CJ README blob `a52ed63ebb53f56aa05359566e19183ce2675bf7`, LICENSE `73e05fcbf5aa2e85fe6368a912eac1377fb0aca0`: 'CJ' is detected by Vosk **on phone**, requiring mic transport from glasses. Do not assume low battery or 1s independently proven. Mac same WiFi currently required, incompatible with AWL remote Tailscale usage without change.
- Hawky README blob `17ed047c91f5c17a5fa9b1b1b988de524e9d8eaa`: frontend realtime model and backend long-running agent; iPhone native glasses; memory survives conversation. Potential architectural inspiration for AWL/OpenClaw async progress updates. Confirm actual durable queue and task cancellation in code.
- TurboMeta README_EN: official DAT camera cannot be accessed directly in iOS background; uses Siri Shortcuts/App Intent workaround; supports OpenClaw and bilingual app, Qwen Omni-Realtime. This is **not** custom glasses-side wake. MIT license `e51901b73b43a58738775f14b06f71d0d1f12200`.
- OpenVision README blob `b9021da53f3084ba651a6d348293f53fc2f6a8ee`, LICENSE `d36f2cd92ffa42f1101bef3705dc49eb8666490a`: multiple providers including OpenClaw and Hermes, offline MLX, wake 'Ok Vision', barge-in, reconnection, native tool registry. Verify wake runs phone-side and measure radio duty cycle before power claims.

## Architectural recommendation
Retain AWL vendor-neutral wearable and agent contracts. Separate:
1. Wake source: native device wake (Visor candidate), phone-local KWS, Siri/App Intents, manual.
2. Audio/vision session: DAT state machine and bounded camera/mic leases.
3. Realtime dialogue: pluggable provider and interruption/cancellation.
4. Durable work: OpenClaw/Hermes/backend agent job id, progress, reconnect, notification.
5. Tool authorization: allowlist, explicit confirmation at execution, audit trail; treat vision/transcripts as untrusted.
6. Network: Tailscale reachability, TLS/auth, mDNS only optional local discovery.

## Code-audit follow-ups
- CJ: android Vosk service lifecycle, audio stream idle battery, Mac WebSocket auth, tool approval checks.
- Hawky: gateway durable tasks, interruption semantics, state recovery.
- TurboMeta: App Intent invocation from locked phone, DAT camera start conditions, OpenClaw auth.
- OpenVision: wake recognizer idle behavior, Bluetooth audio lease, provider registry, reconnect and Hermes/OpenClaw transport.
- PortWorld: canonical repo verification before further claims.
- Across all: benchmark on RW4006 + iPhone for idle, music, camera, Korean, doff/redon, network loss.
