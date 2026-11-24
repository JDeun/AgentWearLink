# Ray-Ban Meta GOD MODE / CJ evaluation — 2026-10-31

Source: https://github.com/GhanshyamPaunikar/rayban-meta-god-mode ; README blob `a52ed63ebb53f56aa05359566e19183ce2675bf7`, LICENSE blob `73e05fcbf5aa2e85fe6368a912eac1377fb0aca0`. Reddit author-supplied text supplied by AWL user. **This is a README-level architecture review, not an implementation audit or independent benchmark.**

## Architecture claimed by README
Meta DAT Android -> glasses audio via Bluetooth -> phone-local **Vosk** wake 'CJ' -> WebSocket `/ws/live` to Mac FastAPI server -> Gemini Live / Claude / GPT and allowlisted tools -> audio returned to glasses. QR token pairing, mDNS discovery, macOS Accessibility/Screen Recording, TV ADB, unofficial Alexa integration, Android Accessibility-based phone agent. User claims ~1 second response, barge-in, multilingual translation, notes, camera and confirmations. These are **author claims, not independently measured**.

## Wake comparison with Visor
CJ is phone-side KWS; README explicitly says mic audio streams to phone. This does not demonstrate low-power on-glasses custom wake. Continuous Bluetooth microphone streaming may have substantial glasses radio power and audio coexistence costs; **battery benchmark not published in examined README**. In contrast Visor implements proprietary glasses-side custom wake enrollment via 390/394/386/368/391 (see AWL #665). Do not conflate the two.

## Potential AWL reuse (MIT, subject to reviewing each file and dependencies)
- Mac FastAPI WebSocket protocol, mDNS + QR pairing, token handling, reconnect.
- Streaming conversation and barge-in; tool invocation and asynchronous job completion.
- Allowlisted macOS actions with explicit high-risk confirmation; screen-derived text must be untrusted data.
- Gemini Live session adapter; model-provider separation and mock/offline tests.
- TV ADB, Alexa, macOS Shortcuts as **optional plugins** rather than mandatory core dependencies.
- Android phone-agent Accessibility not directly portable to iOS; Apple platform restrictions differ.

## Differences / risks
- README requires Android 10+, Mac same Wi-Fi; AWL uses iPhone and Mac mini over Tailscale, so transport and iOS platform design differ.
- Gemini/Azure 'free tier' is quota-dependent, not guaranteed zero ongoing cost.
- Android Accessibility app automation is fragile and sensitive; authorization/confirmation must be checked at tool execution, not only prompts.
- Meta DAT developer mode, firmware constraints, and concurrent camera/audio remain to test.
- README describes MIT license; verify dependency license compatibility before port.
- No primary source code or physical benchmark audit completed beyond README/LICENSE in this pass.

## Suggested follow-up
Inspect actual `android-app` Vosk pipeline and DAT session lifecycle; `brain/app/live.py`, `brain/app/mac.py`, `brain/app/main.py` for auth, cancellation, approval bypass, and audio latency; inspect tests and measure hardware radio duty cycle. Compare against existing AWL agent contract before adopting. Prioritize Visor on-glasses wake for low-power Alfred, CJ for agent orchestration patterns.
