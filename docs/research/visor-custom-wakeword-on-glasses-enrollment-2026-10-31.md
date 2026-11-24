# Critical discovery: Visor on-glasses custom wake word enrollment (2026-10-31)

## Verified code, not just README
- https://github.com/macedonga/visor/blob/main/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/CustomWakeWord.kt (Git blob `98e12a6b2b8c82d510dcd9a7f2919567c72e0903`)
- https://github.com/macedonga/visor/blob/main/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/Assistant.kt (Git blob `1d5b584d82dc189b39d9badabd4dec8cb63d4519`)

**Correction**: Earlier AWL research repeatedly stated no third-party on-glasses custom wake-word registration implementation had been found. That claim is outdated. Visor has concrete code for Meta glasses-side **custom wake-word enrollment** via proprietary protocol. Source author says glasses build the model themselves, without server. This is materially different from phone KWS. **It does not yet prove successful enrollment on the user's model/firmware, that Alfred wakes without Hey Meta, or low idle power.**

## Protocol flow (from source)
1. `CustomWakeWord.begin(phrase)`: `EV_SESSION_BEGIN=390`, Thrift string session UUID + phrase.
2. `capture(start, request)`: `EV_CAPTURE_CONTROL=394`.
3. Glasses stream enrollment audio: `MT_ENROLLMENT_HEADER=6106`, `MT_STREAMER_DATA=6100`, `MT_STREAMER_END=6101`. Opus decoding then 16 kHz 16-bit mono PCM, voice segment trimming. Some pairs starve this stream, then enrollment sample capture may fallback to Bluetooth headset mic; fallback is during enrollment, not evidence of continuous HFP for wake.
4. `enroll(phrase, clips)`: `EV_BATCH_ENROLLMENT=386`, phrase, list of PCM clips and request ID; awaits result up to 180 seconds.
5. `onResult(fields)`: `EV_RESULT=368`, success/error/wakeword/transcript/enrollmentId.
6. `end(session)`: `EV_SESSION_END=391`.
`Assistant.kt` owns `wakeWord=CustomWakeWord(...)`, receives streamer messages and enrollment result.

## Battery implication
If actual detection runs on glasses' own low-power wake engine, it may avoid 24h HFP streaming. **This is a hypothesis requiring physical tests**; code shows glasses-side enrollment but does not establish which chip runs inference, wake idle power, persistence or model support.

## Caveats
- This is proprietary, unsupported Meta companion protocol; Visor Android AGPL-3.0 and Meta account owner enrollment may conflict with iOS AWL app.
- No authorized public DAT API for sending these enrollment events is verified. iOS RFCOMM/LE L2CAP accessibility must be investigated separately.
- Do not distribute Meta client credentials or claim warranty-safe/production-compatible integration.
- Existing 'Hey Meta' wake route in Visor and this *custom wake enrollment* are distinct features.

## Next tests / tracking
**#665** P0 source trace and real hardware proof. Link #648 official API tracking, #655 architecture, #659 companion, #661 firmware, #663 svc15, #658 power. Need verify UI entrypoint, sample count, supported phrase/locale, wake behavior, rollback and battery with owned hardware.

Status: code-level confirmation only, no physical reproduction, successful model enrollment or battery measurements.
