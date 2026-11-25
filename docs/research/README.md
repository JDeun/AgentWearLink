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

## Current research register

Start with the [current research register](research-register.md) for decisions, evidence and remaining owners. Dated notes below are historical snapshots; newer decisions supersede older statements without rewriting provenance.

- [Third-party wake-source audit (2026-11-25)](third-party-wake-source-audit-2026-11-25.md)
- [Muse pinned inventory and file-by-file ledger](muse-runtime-audit-progress-2026-11-25.md)
- [Muse Linux SDK and firmware handover audit](muse-linux-handover-audit-2026-11-25.md)

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
| November SDK / Visor / acceptance refresh | [2026-11-24 follow-up](meta-dat-visor-companion-followup-2026-11-24.md) |
| Companion physical acceptance handoff | [Companion acceptance runbook](companion-physical-acceptance.md) |

## Sources

Most upstream evidence comes from Meta's public repositories. The SwiftPM checkout of the SDK holds only binaries and the changelog. The samples, the per-capability developer guides and the issue history exist only on GitHub, so read the repository itself:

- [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios): `samples/` (BirdSpotter, CameraAccess, DisplayAccess), `plugins/mwdat-ios/skills/*/SKILL.md`, issues and discussions.
- [facebook/meta-wearables-dat-android](https://github.com/facebook/meta-wearables-dat-android): many cross-platform answers from Meta staff are posted there only.
- [Wearables developer docs](https://wearables.developer.meta.com/docs/develop/dat/).

Historical October notes used iOS DAT 1.0.0/1.0.1; current AWL baseline is pinned to DAT 1.1.0, see [November follow-up](meta-dat-visor-companion-followup-2026-11-24.md).
