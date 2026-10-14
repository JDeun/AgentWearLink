# Hey Meta and the Meta AI boundary

**Which spoken requests reach a third-party DAT app, and which stay with Meta AI.**

[Research notes](README.md)

## Summary

- "Hey Meta …" is owned by Meta AI. **A third-party app cannot receive a general "Hey Meta" request.** The only route into an app is launching it by name.
- The launch event carries **no transcript**, so "Hey Meta, start X and tell me the time" cannot reach the app as one request.
- To talk to your own agent hands-free, keep a device session running and listen with the app's own Speech capability (see [Hands-free speech](hands-free-speech.md)).

## Findings

| Finding | Label |
| --- | --- |
| "There is no way to send a bare 'Hey Meta' or general questions to a registered app." Once the app is running, Speech "is the supported way to hold a Korean conversation on the glasses." (Meta staff, alexsinkmeta) | Verified: [dat-android discussion #209](https://github.com/facebook/meta-wearables-dat-android/discussions/209) |
| The wake word cannot be customised. | Verified: [dat-android discussion #85](https://github.com/facebook/meta-wearables-dat-android/discussions/85) |
| Voice Invocations launch or foreground an app when the wearer says "Hey Meta, start {app name}". It is a Wearables-level stream and does not need a running device session. | Verified: `plugins/mwdat-ios/skills/voice-invocations/SKILL.md` |
| `LaunchApp` has only `responseHandle` and `deviceIdentifier`. There is no dictated text. | Verified: `MWDATCore.swiftinterface` (1.0.0) |
| Every invocation must be acknowledged exactly once with `sendSuccess` or `sendFailure`. | Verified: voice-invocations skill |
| In Developer Mode, the spoken name is matched word for word against the app name **as shown on the iPhone home screen**. In production it is the name configured in Wearables Developer Center. Avoid "AI" in the name. | Verified: [dat-ios #316](https://github.com/facebook/meta-wearables-dat-ios/issues/316), [#311](https://github.com/facebook/meta-wearables-dat-ios/issues/311), developer docs best practices |
| Launch by voice is the only way to start an app from the glasses. Touch gestures cannot start an app or a session. | Verified: dat-ios #316 (Meta staff) |
| Only English (US) launch phrases are validated. A Korean "Hey Meta, open X" launch failed. | Verified: dat-android discussion #209 |
| "Hey Meta, open X" worked where "start X" did not, in Spanish testing. | Reported: [dat-ios discussion #326](https://github.com/facebook/meta-wearables-dat-ios/discussions/326), #323 |
| Each "Hey Meta" attempt drops the app's device link for about 3–4 s. | Reported: dat-ios #311, discussion #326 |
| Saying "Hey Meta, tell Alfred …" is handled by Meta AI (it may try to message a contact). It never reaches the app. | Unverified (follows from the rows above) |

## Consequences for AgentWearLink

- Reference host builds need a **speakable** `CFBundleDisplayName`. The product name `AgentWearLinkMetaDATIOSHost` cannot be spoken.
- Use the voice launch only as a cold-start path (after a reboot or when the app was killed). Daily use relies on a session that is already running.
- Don't promise a one-breath "Hey Meta, ask my agent …" flow in UI copy.
