# Glasses battery with always-on Speech

**What drains the glasses when a DAT session keeps Speech listening for the agent's name, what the SDK offers against it, and what we changed.**

[Research notes](README.md)

## Field measurement

| When | Setup | Result | Label |
| --- | --- | --- | --- |
| 2026-10-14, 18 min | Ray-Ban Meta, DAT session + Speech + Inputs, iPhone silent keep-alive (`.playback`, mix with others), Speech restarted about every 20 s in a quiet room | 94% → 79% (about 43–57%/h; the level is an integer) | Observed here, single run |

For comparison, Gen 2 is rated for up to 8 h mixed use and Gen 1 for up to 4 h (Verified: [Meta disclosures](https://www.meta.com/legal/ray-ban-meta/disclosures/)). Continuous audio is quoted at about 5 h on Gen 2 (about 20%/h) and about 3 h on Gen 1 (Reported: [TechRadar](https://www.techradar.com/computing/virtual-reality-augmented-reality/meta-ray-ban-gen-2-smart-glasses-are-official-here-are-5-key-upgrades-you-need-to-know-about), retailer pages). The measured drain is roughly 2.5× Gen 2 continuous audio.

## What Meta says

- Speech runs ASR on the glasses. "Run Speech only while your feature needs transcriptions to limit battery use." Speech can also stop on inactivity, timeout or another performance constraint. (Verified: [developer docs, llms.txt](https://wearables.developer.meta.com/llms.txt?full=true), "Transcribe speech on the glasses")
- The SDK has no power knobs: `Speech` has only `start()`, `stop()`, state, transcripts, errors and locale; no VAD, keyword spotting or low-power mode. Apps cannot pause a `DeviceSession`; `.paused` is decided by the device. (Verified: MWDATSpeech and MWDATCore 1.0.0 interfaces)
- Device state (battery, wear, hinge, eight thermal levels) exists to "defer battery-intensive work, pause a feature when the wearer takes the glasses off"; MODERATE means "reduce optional work". (Verified: developer docs)
- Meta has not published per-feature power costs; a request for a ranking is unanswered. (Reported: [dat-ios discussion #75](https://github.com/facebook/meta-wearables-dat-ios/discussions/75))
- Continuous microphone use carries "battery and privacy trade-offs" (Verified: Meta staff, [dat-android #153](https://github.com/facebook/meta-wearables-dat-android/issues/153)). Developers report always-on listening drains noticeably (Reported: [dat-ios discussion #71](https://github.com/facebook/meta-wearables-dat-ios/discussions/71), [#213](https://github.com/facebook/meta-wearables-dat-ios/discussions/213), [dat-android discussion #96](https://github.com/facebook/meta-wearables-dat-android/discussions/96)).
- While a session runs, single tap and tap-and-hold are reserved by the device; a double tap reaches the app as `.select(.captouch)`. (Verified: Meta staff, [dat-ios #312](https://github.com/facebook/meta-wearables-dat-ios/issues/312))

No public project has measured DAT Speech battery use. OpenGlasses does not link MWDATSpeech and calls restart churn of its own phone-side recognizer its top battery drain (Reported: [OpenGlasses plan](https://github.com/straff2002/OpenGlasses/blob/main/docs/plans/BE-wake-word-hardening.md)).

## Suspected causes in this app

| Cause | Status |
| --- | --- |
| Speech ASR running on the glasses all the time | Cost acknowledged by Meta; size unverified |
| The silent keep-alive keeps an A2DP stream open to the glasses (silent music, in effect) | Unverified; measure with and without |
| Speech stop/start every 20 s in a quiet room (silence yields only empty transcripts), about 180 an hour | Unverified cost; changed (below) |
| Restarting Speech each time it stops by itself, even for a device performance constraint | Code behaviour verified; whether it happens is unverified |

## What changed

- **Restart backoff.** Each empty-only restart in a row doubles the limit (20, 40, 80, 160, then 300 s); a non-empty transcript resets it. For 60 s after a fresh start (connect, re-wear, unfold, session resume) the limit stays 20 s, because Speech was observed going deaf right after the glasses were put back on, and 20 s recovered it while 180 s did not. (Observed here)
- **Speech self-stop backoff.** When Speech stops by itself, it is restarted after 750 ms up to three times. From the 4th self-stop within 10 minutes the wait is 60 s, and from the 6th it is 300 s, so the app does not fight a device that sheds Speech for power or heat.
- **Keep-alive stops without glasses.** The silent keep-alive now stops 5 minutes after the glasses were last seen, and iOS suspends the app.
- **Bluetooth wake instead of silent audio.** While the glasses are away, a pending Bluetooth connection replaces the keep-alive as the way back: iOS wakes or relaunches the app when they return ([waking the app](waking-the-app.md)).
- **Power log.** The companion app writes one CSV line a minute (glasses battery, charging, listening, Speech pause state, keep-alive, audio outputs, app active, phone locked, cumulative restarts and turns) to `Application Support/power-log.csv`. No text is recorded.

## Open: A/B plan

Thirty minutes each, same glasses, starting near 90%, model and firmware written down:

1. Session + Inputs, Speech off, keep-alive off (app in the foreground)
2. 1 + keep-alive
3. Speech on, no stall restarts, keep-alive off
4. 3 + restarts
5. Everything as shipped
6. Control: music through the glasses (A2DP baseline)

The full option ranking and a proposed three-mode design are in [wake word and power](wake-word-power.md).

If Speech dominates, the strongest option is Meta's own advice: pause Speech after some idle minutes while the phone is locked, keep the session and Inputs, and resume on double tap, re-wear, unfold or unlock. That changes "just say the name" into "double tap, then speak" after idle, so it needs the wearer's decision.
