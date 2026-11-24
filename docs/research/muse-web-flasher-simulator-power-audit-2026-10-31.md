# Muse web flasher, simulator and power-tool static audit (2026-10-31)

## Reviewed sources and direct observations

### Web flasher
- `web-flasher/index.html:223-242` stores `muse-sdk-token` in browser `localStorage`; a saved value is validated using `isSdkToken`. Password input obscures visual display but does **not** encrypt storage.
- `web-flasher/sdk-token.js:21-79` validates the `mgst_` token shape and sends `>sdk_token=...` over Web Serial, retries for up to 25 seconds, and waits for `@sdk_token ok`/error acknowledgment. Syntax validation is **not** server-side token authorization.
- `web-flasher/index.html:24` loads `esp-web-tools@10.4.0` from unpkg; version pinned, but CDN/module supply-chain integrity is a separate concern. Do not claim an exploitable vulnerability without further proof.
- `web-flasher/make_manifest.py` derives image offsets from ESP-IDF `flasher_args.json`, calculates required flash size from partition table, emits manifest; this is a build packaging mechanism, not an independent cryptographic signature verification.
- Flasher warns that updating preserves pairing/Wi-Fi/token. Assess reset vs update as separate security flows.

### Simulator
- `esp32/simulator/tests/test_simulator.py` renders deterministic headless scenario frames, SHA-256 compares repeated renders and requires different scenarios to produce different images; includes invalid CLI handling.
- `esp32/simulator/README.md` explicitly says real CPU, camera, audio, BLE radio, memory pressure and power timing are not emulated. Its Linux sanitizer jobs validate host UI code, not device hardware.

### Power tools
- `esp32/tools/power/ppk2_control.py` uses a single serial-owning process, private host FIFOs, per-session random token and bounded control timeout. This is a useful pattern for ensuring no stale command from a previous measurement session can drive hardware.
- The PPK2 power characterization is a distinct opt-in diagnostic firmware and **not** a production workload measurement. USB-free capture requires fixture safety, battery isolation and backfeed protection.

## AWL decision matrix
| Finding | Decision | Follow-up |
|---|---|---|
| Web Serial provisioning | REFERENCE, not copy | If AWL ever provisions custom firmware, require explicit device identity and confirmation |
| Browser localStorage token persistence | EXCLUDE as default | Prefer ephemeral session, secure app credential storage, token redaction |
| Pinned CDN dependency | REVIEW | Lock integrity, origin and build provenance if a browser flasher is introduced |
| Manifest from build output | REFERENCE | Separate artifact hash/signature verification from partition layout |
| UI deterministic screenshot tests | BORROW concept | Add repeatable Swift UI state snapshots only where meaningful |
| PPK2 single-owner measurement | REFERENCE | Future hardware benchmarking; not current Meta DAT adapter implementation |

## Limits and closure
This is a focused static review of selected web-flasher, simulator and power-control files. It is not an audit of all files under those subtrees, nor does it verify real flash operations, CDN integrity, or PPK2 electrical safety.

## Primary sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/web-flasher/index.html
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/web-flasher/sdk-token.js
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/web-flasher/make_manifest.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/simulator/tests/test_simulator.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/tools/power/ppk2_control.py
