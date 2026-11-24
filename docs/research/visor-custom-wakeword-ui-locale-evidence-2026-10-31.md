# Visor custom wake-word UI + locale evidence (2026-10-31)

## Directly verified files
- https://github.com/macedonga/visor/blob/main/app/src/main/kotlin/com/macedonga/visor/settings/WakeWord.kt — blob `39ee023799d892f17fbbd38f6f7f39ccca5b0dd8`.
- https://github.com/macedonga/visor/blob/main/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/CustomWakeWord.kt — blob `98e12a6b2b8c82d510dcd9a7f2919567c72e0903`.
- https://github.com/macedonga/visor/blob/main/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/Assistant.kt — blob `1d5b584d82dc189b39d9badabd4dec8cb63d4519`.

## Enrollment UI code trace
`WakeWordModel.begin` opens glasses-side session; `record` collects **exactly three** samples; minimum phrase length **4 characters** and minimum trimmed clip **8000 bytes** (0.25s at 16kHz Int16); `enroll` submits clips and awaits result; `leave` sends session end. Persistent `open_sessions` shared preferences track orphaned sessions; `enter` tries to close old sessions. Source comments warn an abandoned session can stop normal Hey Meta wake. Result phrase stored in app preferences, while `WakeWordRow` also reads glasses' own `custom_wake_word_enabled` setting; distinguish app-displayed phrase from device truth.

### Critical locale caveat
UI checks `assistant_voice_id` starts with **`en_US`** and warns otherwise. Code comment references glasses `libassistantruntime` locale gate. This is not proof Korean fails, but Korean '알프레드' is **unverified**; test `Alfred`/`Hey Alfred` on en_US first, then Korean locale and Korean phonetics with exact device/firmware.

## Important source-level risk
`Assistant.bringUp` waits up to 4s for m0 and s0 ACK, logs timeout, but continues to set phase LISTENING and announces registered. This directly suggests a potential false-ready UI condition and deserves regression fix/verification under #664. Distinguish timeout from definitive channel failure.

`Assistant.fulfillmentRequest` reads recognized transcript from ev57 nested Thrift fields and ignores intent `IN:WAKE_WORD` when phrase alone. After custom enrollment, must confirm whether ev57 contains Alfred request, not merely enrollment success.

## Experiment matrix
1. Native Hey Meta baseline (HFP off, music on/off), glasses and phone battery.
2. Three sample English `Hey Alfred` registration and verify EV_RESULT 368 success + `custom_wake_word_enabled`.
3. Power cycle / doff-redon / lock phone, utter Alfred without Hey Meta, verify ev57, transcript, agent response and music coexistence.
4. Repeat with Korean spoken `알프레드`, en_US vs ko_KR where supported.
5. Enrollment failure and interrupted session recovery, revert to native wake phrase.
6. Compare battery drain with idle native Hey Meta and continuous HFP KWS; report firmware and sample count.

## Compatibility / license
Visor Android-only, AGPL-3.0; AWL iOS DAT does not expose these proprietary event methods publicly. No claims of successful on-device test or shippable iOS solution. No client credential extraction or signing bypass.

Track #665 (P0), #663, #664, #658, #648.
