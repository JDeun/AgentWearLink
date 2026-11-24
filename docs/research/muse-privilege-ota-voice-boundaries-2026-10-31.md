# Muse Linux privilege, ESP32 OTA, and realtime voice boundary audit (2026-10-31)

## Evidence: selected actual source functions
- `linux/src/musegadget/executor.py:203+` `system_run` invokes `/bin/bash -c` as the configured account, with timeout capped at 600s; `_run_child` uses a subprocess group and bounded stdout/stderr (96 KiB). **This is remote code execution by design**, not a sandbox. Linux README warns that an account with sudo grants Muse sudo too.
- `linux/src/musegadget/fileops.py` limits file chunks to 64 KiB, writes through partial/rename paths. Limits are not filesystem permission restrictions. Source alone does not establish a workspace jail.
- `esp32/main/ota.c:217+` downloads and stages OTA; `ota.c:309` documents `finish()` checking SHA-256 and a signature **when enabled**. The repository README states builds use a development signing key and Secure Boot is disabled; do not equate OTA image checks with production chain of trust. `ota_verify_recorded_for_running` stores/compares boot verification record.
- `esp32/components/muse/muse_voice_call_core.c` is a 1711-line IDF-independent core. It parses bounded JSON, processes 40ms audio appends, call IDs, turn/response lineage, reply gates, idle/overall deadlines and explicit end-call body. A `response.done` (including cancelled) does **not** itself end the call; `session_dead` is fatal after readiness.
- `esp32/AGENTS.md` describes independent voice Noise session (no `link.register`), `POST /voice/realtime` admission, `POST /voice/end-call` explicit termination, up to three retries for unacknowledged cleanup within ten minutes. Hardware half duplex is default unless board supplies echo-cancelled audio.
- `linux/README.md` documents 24 kHz mono PCM16LE, 960 samples/40ms, half duplex gating, 45s idle and 300s overall limits, finite buffers and stale response-ID fencing. The Linux voice CLI is one-shot and does not reconnect; firmware has its own cleanup retry. Do not conflate these clients.

## Decision matrix
| Finding | AWL decision | Why |
|---|---|---|
| Linux `system.run` remote shell | EXCLUDE from wearable action API | privilege escalation and unbounded authority; explicit allowlist + user approval required |
| 64 KiB atomic file write | REFERENCE for optional future file actions | bounded writes, but separate path authorization necessary |
| OTA staging + digest + optional signature | REFERENCE; production profile required | Secure Boot and trusted signer policy not proven by development build |
| Voice call explicit end-call, bounded buffers and response lineage | EXPERIMENT (#634/#635) | useful invariants for future realtime voice, not existing Meta DAT transcript path |
| Separate voice Noise connection | EXCLUDE as dependency | Muse-specific backend; use independent AWL transport if voice implemented |
| Session interruption and stale audio | TEST (#634/#638) | voice correctness requires actual audio and late-event injection |

## Threat-model acceptance additions
1. For any typed action: per-device allowlist, caller identity, consent, audit trail, path scope and idempotency.
2. OTA: image authenticity, downgrade protection, trust-root rotation, interrupted install, rollback and physical recovery.
3. Voice: call-ID binding, reply lineage, duplicate end-call and failed acknowledgment, bounded queues, background suspension and permission loss.
4. Linux: demonstrate restricted service account cannot escalate through sudo, shell expansion or symlink paths before considering command execution.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/executor.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/src/musegadget/fileops.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/main/ota.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse/muse_voice_call_core.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/AGENTS.md
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/README.md
