# Muse negative-test evidence: voice lineage, Linux executor, OTA (2026-10-31)

This document classifies **source-inspected tests**. Tests were not executed in this audit.

## Linux voice lineage — `linux/tests/test_voice_lineage.py`
- Rejects settlement relabelling that would unlock unrelated waiting PCM.
- Checks replayed settled submission cannot admit foreign audio; tests UTF-8 byte length, NUL and invalid surrogate identities.
- Tests more than 64 settled aliases and fail-closed behavior at bounded lineage capacity.
- **AWL:** require explicit response lineage and terminal tombstones for realtime voice (#634), not timer-based reopening.

## Linux executor — `linux/tests/test_executor.py`
- Shell exit/status, working directory, timeout/process-group kill, detached process and inherited pipe, large output/JSON encoding limits.
- File round trip, checksum, out-of-order chunks, permissions, dropping setuid/setgid/sticky bits, partial file privacy, absolute paths.
- **AWL:** do not mistake these for a sandbox or remote command authorization tests. `system.run` still invokes `bash -c`.

## ESP32 OTA — `esp32/tests/test_link_ota.py`
- Compiled harness (skips without C compiler), OTA enabled/disabled, no setup interruption when disabled, recorded-update boot checks and command advertisement only when enabled.
- **Gap:** not a board-level signed-update/downgrade/rollback/flash-corruption test. Do not label as secure-boot validation.

## Static audit completion rule
The upstream repository inventory contains 1,096 blobs. Only the identified security, voice, protocol, CI and application paths have undergone content review; unreviewed device BSPs, UI, simulator, tools, web flasher and all 262 ESP32 test files remain outside a defensible **repository-wide all-files** completion claim.

**Closure status:** key functional/security pathways inspected, decisions recorded, physical/empirical gaps tracked; **full static repository audit NOT complete**. Do not merge/close the research PR on an assertion of exhaustive coverage.
