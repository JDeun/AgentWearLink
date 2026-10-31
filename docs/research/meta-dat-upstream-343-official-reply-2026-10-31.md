# Meta DAT Discussion #343: official response and wake/Speech/media control limits (2026-10-31)

## Source and status
- User-authored upstream discussion: https://github.com/facebook/meta-wearables-dat-ios/discussions/343
- Meta reply: https://github.com/meta/meta-wearables-dat-ios/discussions/343#discussioncomment-19279234
- GitHub notification email received **2026-10-29 21:49:03 UTC** (2026-10-30 06:49:03 KST). Notification was verified from connected Gmail.
- Follow-up tracking: https://github.com/JDeun/AgentWearLink/issues/647
- **Acknowledged, not committed**: Meta explicitly cannot share roadmap items or dates.

## Meta's actual reply (paraphrase)
Meta acknowledged three wake mechanisms: an app-registered phrase, a low-power voice activity event, or routing spoken requests to an app. They also noted three tap possibilities: forwarding single tap to media controls, allowing an opt-out for Speech/Inputs-only sessions, or delivering resume/tap to the app. They asked for **glasses firmware version and approximate incidence** of Speech continuing to emit empty transcripts after re-donning. None of these requested APIs were promised.

## Field evidence provided in original discussion
Ray-Ban Meta RW4006, DAT iOS 1.0.0, DeviceSession + continuous Speech + Inputs: glasses battery 94% to 79% in 18 minutes (15 percentage points, ~50pp/hour linear extrapolation; single run and integer battery percentage, NOT a robust power benchmark); approximately 3 empty transcription events per second in a quiet room. After doff/redon, Speech sometimes only returns empty transcripts until stop/start. DAT-reserved single tap can interrupt music/media controls; no documented app-level resume() method. These are reports from the original discussion, not new measurements in this research.

## Engineering implications
1. **Low-power wake:** no public custom wake word or VAD event API confirmed. Do not claim 'Alfred' always-on low-power wake can ship. Supported VoiceInvocation launch is a fallback but requires 'Hey Meta' and eligibility.
2. **Speech lifecycle:** test repeated doff/redon, empty-transcript vs true silence, recovery by bounded stop/start, cancellation/generation fencing, permission and link loss. Only reply to Meta after collecting firmware and denominator-based failure frequency.
3. **Tap ownership:** continuous DAT sessions may reserve tap, interfering with music. No public guaranteed passthrough or resume semantics. Product should expose tradeoff, avoid hidden media hijacking.
4. **Power:** quantify with controls, >=3 trials per configuration, actual device/firmware, environmental factors and integer percentage limitations.
5. **HFP and DAT concurrency:** Meta upstream #342 official comment says glasses firmware can end active DAT session when HFP connects; 1.0.1 does not fix it; camera PCM experimental workaround is not publishable. Upstream #260 describes still-photo callback stalls during HFP. Treat as test gates, not blanket device incompatibility.
6. **Privacy and telemetry:** keep opt-out/consent decisions from #644; do not publish personally identifying logs or app tokens.

## Proposed next upstream response
After physical testing, send: firmware build, Meta AI version, iOS version, exact DAT revision, device model, number of doff/redon cycles, number producing empty-only Speech despite audible test phrase, time-to-recovery and steps/log timestamps (redacted). If measurements are unavailable, do **not** fabricate a reply.

## Relationship to current work
- #647 is the source-of-truth issue for upstream #343 feedback and new experiments.
- #644 covers SDK pin, telemetry and voice.
- #646 covers version/hardware regressions.
- #94/#114 cover Speech adapter correctness; #5 end-to-end audio.
- Research PR #645 includes the upstream refresh and regression matrix. This document extends that PR; no hardware test or outbound reply performed.
