# Meta DAT official responses: actionable follow-up (2026-10-31)

## Upstream authoritative responses
1. [Our Discussion #343](https://github.com/meta/meta-wearables-dat-ios/discussions/343#discussioncomment-19279234): Meta acknowledged three proposed wake options (app-registered phrase, low-power voice activity, spoken-request routing) and three tap options (media passthrough, tap reservation opt-out, public resume/tap event). **No implementation commitment or dates.** Meta asks for exact firmware and approximate incidence of post-redon empty-only Speech.
2. [Speech #360 maintainer answer](https://github.com/meta/meta-wearables-dat-ios/issues/360): recognition run on glasses currently completes at about 60 seconds; **not** a 199-callback cap. DAT iOS 1.0.x has a missing public stopped transition/error when run ends, leaving Speech apparently started. Maintainer confirms same-instance stop() then start(), waiting for states, while retaining DeviceSession and listeners. A gap in recognition is expected.
3. [DAT 1.0.1 changelog](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md): no developer-facing changes. Experimental capabilities may not be published.

## Issue breakdown (distinct acceptance boundaries)
- [#648](https://github.com/JDeun/AgentWearLink/issues/648): low-power custom wake/VAD/spoken-request APIs, feasibility and release monitoring. No SDK API exists to promise.
- [#649](https://github.com/JDeun/AgentWearLink/issues/649): tap/media ownership conflict and three alternative upstream API requests.
- [#650](https://github.com/JDeun/AgentWearLink/issues/650): firmware and denominator-based doff/redon Speech deaf-state measurement, upstream reply once evidenced.
- [#651](https://github.com/JDeun/AgentWearLink/issues/651): ~60-second Speech run completion, missing public stopped state, safe same-instance bounded recovery.
- Umbrella [#647](https://github.com/JDeun/AgentWearLink/issues/647), release validation [#644](https://github.com/JDeun/AgentWearLink/issues/644), hardware regression [#646](https://github.com/JDeun/AgentWearLink/issues/646).

## Crucial distinction: two failure mechanisms
- **Time-limited recognition run**: documented by Meta, approximately one minute; public state bug in DAT 1.0.x. Restart Speech instance, do not replace DeviceSession.
- **Doff/redon deaf state**: reported by our field observation and acknowledged by Meta, but incidence/firmware/root cause not yet established. It may overlap the timeout symptom; design experiments to separate them. Do not label every empty transcript as a dead state.

## Experimental protocol for #650
1. Capture exact firmware, app/SDK/iOS versions and device ID class (not unique device identifiers).
2. Start Speech, timestamp start and every callback without storing spoken content; schedule doff/redon both before and after 60s elapsed; use spoken known phrase and silence control.
3. For each trial classify audible known phrase recognized, empty-only while speaking, stopped after time limit, session transport error, or indeterminate. Report numerator/denominator and recovery time.
4. Compare same-instance stop/start, new Speech instance, and session recreation only if required; rate-limit retries and respect consent and battery.
5. Publish sanitized data and respond to Meta only when real measurements exist.

## Practical decision
Keep always-on Speech custom-wake out of the default architecture due to power and lifecycle cost. Use supported invocation fallback when eligible, and keep any custom wake prototype experimental. For #651, a bounded Speech run renewal may be required **only during a user-authorized listening window**. Avoid making the ~60s duration a permanent hardcoded public API guarantee.

No device testing, SDK change, or outbound Meta reply was performed for this document.
