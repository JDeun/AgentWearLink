# Research notes

**Findings collected while bringing AgentWearLink up on real hardware, kept with their sources so later decisions can be checked.**

[Docs home](../README.md) · [Meta DAT known issues](../meta-dat-known-issues.md) · [Meta DAT validation](../meta-dat-validation.md)

> [!IMPORTANT]
> These notes describe **what upstream sources and field reports say**, not what this repository has proven. Every claim carries one label:
>
> - **Verified (source)**: stated in Meta's SDK, docs, sample code or a Meta staff reply, with a link.
> - **Reported**: a first-hand report by another developer, not confirmed by Meta.
> - **Observed here**: seen on this project's own hardware run (see the validation log).
> - **Unverified**: inference or open question, still to be tested.
>
> Personal deployment details (tailnet names, chat IDs, session keys) are intentionally left out.

## Notes

| Topic | Note |
| --- | --- |
| Where "Hey Meta" goes, and what a third-party app can receive | [Hey Meta and the Meta AI boundary](hey-meta-and-meta-ai-boundary.md) |
| Talking to your own agent without saying "Hey Meta" | [Hands-free speech](hands-free-speech.md) |
| Keeping a session alive with the phone locked | [Background and locked phone](background-and-locked-phone.md) |
| Getting the reply back to the glasses | [Audio output](audio-output.md) |
| Every hands-free approach ranked (phone locked, music, phone away) | [Hands-free alternatives](hands-free-alternatives.md) |
| Other open-source glasses-to-agent projects and their field lessons | [Other projects](other-projects.md) |
| What a companion app can and cannot know or do on iOS | [Companion app constraints](companion-app-constraints.md) |
| OpenClaw Gateway behaviour learned on a real deployment | [OpenClaw integration findings](openclaw-integration-findings.md) |
| What drains the glasses with always-on Speech, and the A/B plan | [Glasses battery](glasses-battery.md) |
| Why always-on wake words are cheap elsewhere and costly with DAT 1.0, ranked options | [Wake word and power](wake-word-power.md) |
| How the app comes back after iOS suspends or evicts it | [Waking the app](waking-the-app.md) |
| Physical bring-up log (October 2026) | [Validation log](validation-log-2026-10.md) |

## Sources

Most upstream evidence comes from Meta's public repositories. The SwiftPM checkout of the SDK holds only binaries and the changelog. The samples, the per-capability developer guides and the issue history exist only on GitHub, so read the repository itself:

- [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios): `samples/` (BirdSpotter, CameraAccess, DisplayAccess), `plugins/mwdat-ios/skills/*/SKILL.md`, issues and discussions.
- [facebook/meta-wearables-dat-android](https://github.com/facebook/meta-wearables-dat-android): many cross-platform answers from Meta staff are posted there only.
- [Wearables developer docs](https://wearables.developer.meta.com/docs/develop/dat/).

SDK version at the time of writing: iOS 1.0.0 (1.0.1 on 2026-10-09 has no developer-facing changes).
