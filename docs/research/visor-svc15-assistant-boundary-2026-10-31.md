# Visor code-level assistant boundary follow-up (2026-10-31)

## Verified primary-source code
- https://github.com/macedonga/visor/blob/main/CLAUDE.md — GitHub blob SHA `61e647c49cc80b01b8e22db71218e9c9b1fb91fd`. Documents **svc15 (ev57 inbound, VARM outbound)** for the assistant, **svc28** device state, **svc36** trust, **svc100** canary; LE L2CAP, RFCOMM and TCP pipes. These service/event labels are from project source notes; not yet confirmed on AgentWearLink hardware.
- https://github.com/macedonga/visor/blob/main/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/Brain.kt — blob SHA `9edb2b6438bb511bf5dab81bd383923b41e8eba4`. Brain.answer takes **question: String**, locale, history, optional JPEG and provider, returns Reply(text, remembered, actions, ends). This file is the *model inference/backend*, not the inbound wake-event decoder. A custom DSP keyword is not implemented here.
- https://github.com/macedonga/visor — README: Hey Meta routed to user model, one owner session, AGPL-3.0, Meta account ownership. User builds need Meta app client tokens not distributed by repository.

## New actionable distinction
The most promising code audit is the **svc15 ev57 event decoder → question String → Brain.answer → VARM reply** call graph. Verify whether the glasses generate a post-Hey-Meta transcript without persistent HFP, what the idle radio mode is, and whether the firmware supports configurable wake phrases. Do not assume event ev57 itself is a wake-word or raw microphone stream.

## Research caveats
- Existing user-requested requirement is standalone Korean '알프레드' wake without 'Hey Meta', locked iPhone, music playback and low glasses power. Visor's Hey Meta handoff only partially addresses this.
- Visor AGPL-3.0 and Meta app authentication/client-token dependencies create legal and product compatibility risks; clean-room documentation rather than code copying recommended.
- Meta official discussion https://github.com/facebook/meta-wearables-dat-ios/discussions/343 still provides no supported low-power custom wake phrase API.
- Reverse-engineering presentation https://nullcon.net/talk/beeps-and-patches-arbitrary-code-execution-on-meta-ray-ban/ describes unprivileged code execution, not proven DSP reprogramming.

## Concrete next steps under #663
1. Trace inbound svc15 event parser, VARM serializer and microphone source, with pinned code and exact test observations.
2. Compare connection idle/battery and A2DP/HFP route before and after 'Hey Meta'; no inference from transport alone.
3. Inspect device settings/mobileconfig/language-pack metadata for documented *configuration* of wake phrase (not signing bypass); distinguish language locale from keyword model.
4. Assess iOS accessibility to required L2CAP/RFCOMM services and owner-app session conflict.
5. Escalate custom DSP research only if source evidence supports access, otherwise mark no-go for maintainable iOS release.

No physical experiment or full decoder trace completed.
