# Deep-research continuation: canonical Port:World discovery (2026-10-31)

**Correction of prior report:** `armapidus/PortWorld` was the wrong path. The canonical verified repository is **https://github.com/portworld/PortWorld**, README SHA `b85a3c2ba1ec4523d73ecc6c767db0aad402a720` fetched via GitHub connector. Do not carry forward 'PortWorld unverified' conclusion.

## Confirmed from upstream README and iOS README
- SwiftUI iOS 17+ companion using Meta DAT, microphone/video and wake/sleep phrase lifecycle.
- FastAPI backend, WebSocket for realtime audio/control, HTTP for vision frames; pluggable OpenAI Realtime and Gemini Live, optional vision providers, memory, MCP tools, external OpenClaw delegation.
- Python CLI `portworld init`, `portworld doctor --target local`, deploy options, provider registry and extensions.
- Cross-cloud OpenClaw gateway bridge skill (a configuration workflow, **not** proof of hardened remote deployment).
- iOS Siri Shortcuts launches and *attempts* to start session; readiness gates can block start.
- iOS source layout: `IOS/PortWorld/Runtime/{Assistant,Transport,Playback,Wake,AudioIO,Glasses}`, explicit state-machine separation.
- iOS README says maintained Xcode test action is not available. README warns AWS/Azure deployments may use publicly accessible database defaults; production hardening needed.
- README claims MIT; inspect actual LICENSE before copying.

## AWL relevance
1. PortWorld is now a **high-priority** iOS architectural comparator alongside OpenVision and TurboMeta, not a deferred unverified project.
2. Inspect iOS wake phrase mechanism for phone-local streaming vs device-native KWS, background constraints and battery; README alone does not prove low-power wake.
3. Compare OpenClaw gateway auth, token rotation, WebSocket reconnect, cloud vs Tailscale setup.
4. Compare modular assistant state machine and wake/sleep phrase transitions to AWL.
5. Compare provider registry and MCP tool permissions; consider reuse only after code/test audit.

## Five-project audit status
- CJ GOD MODE: README/LICENSE examined; actual Vosk/audio/auth/tool approval code not audited.
- Hawky: README examined; actual gateway durable delegation code not audited.
- TurboMeta: README/LICENSE examined; actual App Intents and background DAT paths not audited.
- OpenVision: README/LICENSE examined; actual wake, reconnect, tool registry code not audited.
- PortWorld: canonical repo and iOS docs identified; code audit pending.

Next deliverable: per-project code path evidence, dependency/license map, test inventory, feature gap matrix against AWL, issue/PR mapping. No independent hardware tests or claims of verified runtime behavior.
