# November 24 follow-up: Meta DAT 1.1.0, Visor 3.1.0 and Companion acceptance

Status: source review and backlog reconciliation; no new physical tests. The October 13 field evidence is historical, not full acceptance. Keep the October research snapshots rather than rewriting their dates.

## Meta DAT 1.1.0

[Tagged changelog and package](https://github.com/meta/meta-wearables-dat-ios/tree/2c772e03e6a2e74282ac6564c2424acf6e58d8f0) (1.1.0, Nov 20) and the actual Core, Speech and MockDeviceTestClient XCFramework public interfaces were inspected. The previous AWL pin is 1f38beecba83c4c8b5e343540f9cd615323ab19a. Candidate PR [#677](https://github.com/JDeun/AgentWearLink/pull/677) updates package/project/verifier, source/built host privacy checks and registration-loss handling. CI and physical acceptance are distinct.

| Upstream change | AWL action |
| --- | --- |
| Session pause/resume, no-op outside valid state | Test explicit session control and state/capability changes in #649/#646; not proof of tap passthrough or hardware wake |
| Session creation notRegistered; registration unauthorized; unregister stops all active sessions | #644/#646 registration gate, generation teardown, local cancellation/explicit app-switch consent |
| Typed low-power/thermal stream refusal | #657/#646, no speculative retry loops |
| Stream photo failure at 10 seconds instead of 30 | #58/#303/#646, retain stricter AWL deadline and terminal ownership |
| Unified Analytics.OptOut for analytics and crashes; old CrashReporting key removed | #677 opts out and checks plist; align Companion when integrated |
| New MockDeviceKit kit, update requirements and MockDevice MCP | #644/#632 simulator-only migration and fault injection; old flat API is deprecated, not removed |
| Speech/Inputs/Voice Invocation and standalone Photo experimental | No publishability claim; public SDK symbol is not hardware proof |

[Upstream #324](https://github.com/meta/meta-wearables-dat-ios/issues/324) and [#360](https://github.com/meta/meta-wearables-dat-ios/issues/360) are still open as of Nov 24. Changelog does not establish fixes for camera retained-buffer growth or missing Speech stopped transition. Track #303/#651. Use no long-lived camera or persistent audio by default. 

## Visor re-audit, latest pinned v3.1.0

[Release v3.1.0](https://github.com/macedonga/visor/releases/tag/v3.1.0) Nov 21, commit 303b68035e013b0804f06914f6416c88cb8cc875. [v2.1.0](https://github.com/macedonga/visor/releases/tag/v2.1.0) notes a firmware-dependent setting for custom wake support; later release does not prove hardware compatibility. Source is AGPL-3.0, do not copy into Apache-2.0 AWL. Study behavior and independently designed invariants; no private protocol implementation or credential handling authorized.

- [WakeWord.kt](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/app/src/main/kotlin/com/macedonga/visor/settings/WakeWord.kt): UI takes 3 recordings, min 4 characters and 8000 bytes, pair-scoped remembered enrollment, persisted open session IDs and attempted cleanup on revisit/leave, switch-off. Source comment states custom phrases only active in en_US. Korean UI length does not prove Korean hardware recognition; test English Alfred first. Android post-wake ASR language support is different from hardware wake language.
- [CustomWakeWord.kt](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/CustomWakeWord.kt): local registration path, bounded recording wait, temporary headset microphone fallback when device recording is starved. Author claims on-device model; no steady-state battery or hardware evidence. Result contains enrollment ID but the shown completion path does not visibly validate that ID against the active waiter; late result handling may race subsequent attempts. Require attempt/pair/generation fencing and rollback in any independent design. Never log phrase/transcript or keep enrollment clips by default.
- [Assistant.kt](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/Assistant.kt): channel-close re-registration checks link identity/readiness and cancels previous retry. Registration ACK waits can time out and log while execution continues to LISTENING after announcement. Link healthy does not imply assistant ready. Treat as static risk, not a reproduced bug. [Issue #47](https://github.com/macedonga/visor/issues/47) closed Nov 2; closure does not establish this risk gone.
- [GlassesEars.kt](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/GlassesEars.kt): post-wake recognition pipeline and bounded consecutive immediate restarts. Do not conflate with steady-state custom wake inference.

Decision: retain official DAT/VoiceInvocation and manual fallback, evaluate Visor only as a separately licensed Android reference under #663/#664/#665; no direct port. #655 owns wake decision; #658 owns comparable energy and latency. OSAIG #673 is non-Meta control experiment, not proof of Meta support.

## Backlog consolidation and evidence

#659 -> #663, #662 -> #646 and #323 -> #58 (remaining physical and release-channel acceptance transferred; implementation already merged #588/#589). No hardware issue marked physically complete. #645/#631 historical research merged; #667/#668 dependencies merged. Companion #632 integrates #629's distinct files and main; original Release failure in PowerLog.swift was fixed by explicitly typed smaller arrays. Latest checks are needed before merge, and 1.1.0 pin alignment remains necessary before both branches can land.

[Historical field log](validation-log-2026-10.md) records partial actual device/Tailnet evidence: health, explicit pairing, tokenless reconnect, Meta registration, microphone permission, Korean spoken turn and audible output. Unverified: unchanged official CameraAccess baseline, current revision, camera, lock screen, continuous Speech, actual existing-session incremental output, >30 s response after fix, network transition, failure/recovery and no replay. Existing #1/#3/#5/#6/#56/#58/#59/#97/#98/#117/#118 remain acceptance gates; see [Companion runbook](companion-physical-acceptance.md).
