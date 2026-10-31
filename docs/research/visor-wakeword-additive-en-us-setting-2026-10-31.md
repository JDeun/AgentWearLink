# Visor wake phrase settings and Korean/English split (2026-10-31)

## Newly verified primary sources
- https://github.com/macedonga/visor/blob/main/core/settings/src/main/resources/com/macedonga/visor/core/settings/settings.tsv : `custom_wake_word_enabled` ID 196, bool, default false, `individual_device_settings`. Indicates a glasses-side setting in Visor's reconstructed setting catalogue, **not** independently confirmed on AWL physical glasses.
- https://github.com/macedonga/visor/blob/main/core/settings/src/main/resources/com/macedonga/visor/core/settings/settings_ui.json : setting note says 'Uses a phrase you record as a voice command trigger, **in addition to Hey Meta**.' Thus a supplemental keyword is intended, not necessarily replacement.
- https://github.com/macedonga/visor/blob/main/app/src/main/res/values/strings.xml : `ww_english` explicitly says 'The glasses use it only while the assistant speaks US English.' This is stronger than merely an en_US UI warning.
- https://github.com/macedonga/visor/blob/main/app/src/main/kotlin/com/macedonga/visor/settings/WakeWord.kt : checks `assistant_voice_id` starts with en_US, takes three clips and saves result.

## Revised feasibility
A user may be able to enroll spoken English 'Alfred' as **additional** native glasses wake phrase and then route the ensuing utterance to an agent. Whether the device transcribes Korean after an en_US-only wake, and whether a third-party iOS app can receive the invocation, are separate unknowns. Do not promise Korean mixed-language speech works.

## Test gates
- Enroll 'Alfred' / 'Hey Alfred' in en_US; confirm result 368, setting ID 196 true, subsequent wake event and assistant route.
- Test 'Hey Meta' still triggers (additive claim).
- After Alfred wake, test Korean command recognition separately from English and track whether on-device transcript, phone-side transcription or HFP fallback is needed.
- Switch voice locale and observe whether custom wake disables, persists or can re-enable without new training.
- Track firmware version, standby battery, music coexistence and restart/recovery.

## Caveats
Code-level source evidence only, no AWL hardware test. Visor Android AGPL-3.0, account/session ownership, iOS RFCOMM limits, official DAT API gap. No claim of shipped support.

Track #665 and #663; supersedes blanket 'custom wake impossible' claim.
