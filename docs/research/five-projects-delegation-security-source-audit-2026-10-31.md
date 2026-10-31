# Five-project deeper source audit: delegation, identity, stream authorization (2026-10-31)

Evidence is based on GitHub connector fetching source files; no runtime or physical device verification.

## PortWorld: OpenClaw task lifecycle
Source: https://github.com/portworld/PortWorld/blob/main/backend/tools/openclaw_runtime.py (blob `69394f7e2412c43f168847b993b8b93ea6721332`).
- `OpenClawDelegationRuntime` maintains `_tasks: dict[str, _OpenClawTaskRecord]`, `asyncio.Semaphore` for max concurrent tasks, `asyncio.Lock`, cleanup worker, task TTL, queued/running/succeeded/failed/cancelled states.
- **Important limitation:** the examined runtime stores task records **in process memory**. No persistence backend is visible in this class. Do not infer crash-safe durable task continuation from the existence of task IDs; audit external persistence before adopting.
- Sanitizes bearer/token strings and control chars in summary/result previews; these regex-based redactions are defense in depth, not exhaustive secret detection.
- Verify timeout, cancellation, per-session access checks, and whether request/retry can duplicate external effects.

## Hawky: realtime bridge and delegated tasks
Source: https://github.com/hao-ai-lab/hawky/blob/main/src/gateway/live-stream-methods.ts (blob `d8e5a5e7e7bd5cf6e32e675dcfd255aa725d9f73`).
- `validateStreamCreate` constrains stream ID, ownerSession, runtime, model, history count/bytes; `validateStreamInput` bounds audio/image/text payload sizes.
- Session lookup requires **same connection object and ownerSession**, rejects closed/closing sessions; on disconnect closes active streams.
- Task update propagation checks ownerSession and deviceTokenId, supports superseded result handling; audio delivery failure closes stream rather than accumulating packets.
- Tool-call promises keyed by id; `session_send_message` delegates tasks and `session_task_control` handles controls. Must still inspect DelegationService for durable storage, permissions, idempotency and cancellation guarantees.
- Potential design to reuse: distinguish streaming connection lifecycle from long-running task lifecycle, propagate task IDs and terminal/superseded states.

## TurboMeta: OpenClaw device identity
Source: https://github.com/Turbo1123/turbometa-rayban-ai/blob/main/CameraAccess/Services/OpenClaw/OpenClawDeviceIdentity.swift (blob `cf416fbe9b011015c261d3fb31896ec0c74dc73d`).
- Uses CryptoKit Curve25519.Signing.PrivateKey (Ed25519), deviceId SHA-256(raw public key), signed v3 connect payload including nonce/timestamp/scopes/platform, stores private key in iOS Keychain `kSecAttrAccessibleAfterFirstUnlock`.
- **Reliability finding:** `loadOrCreate()` calls `saveToKeychain()` without checking `SecItemAdd` status; if persistence fails, a new identity may be generated on later launches and pairing can break. Audit AWL identity persistence errors, duplicate writes, key rotation and Keychain migration. This is a code-level risk, not demonstrated failure.
- Validate signature canonicalization and nonce handling against the target OpenClaw gateway version before reusing.

## CJ GOD MODE
README https://github.com/GhanshyamPaunikar/rayban-meta-god-mode/blob/main/README.md blob `a52ed63ebb53f56aa05359566e19183ce2675bf7`: states approval for high-risk actions is code-enforced and phone wake uses Vosk; **implementation still not verified**. Needs actual Android source path and Mac tool execution approval review.

## OpenVision
Source https://github.com/rayl15/OpenVision/blob/main/OpenVision/Services/Voice/VoiceCommandService.swift blob `e16857c60d7e946a1189ac0d62eb9ac4699eb0d6`: recognizer generation guards, 0.6s restart throttling, VAD end-of-turn, HFP 8kHz comment. OpenClaw reconnect implementation and permission boundary not yet audited.

## AWL action plan
1. Compare AWL current agent task store and OpenClaw client before copying PortWorld's in-memory approach.
2. Verify Hawky DelegationService persistence and permission checks, task cancellation and resume.
3. Verify TurboMeta node router commands, device identity persistence failure handling, replay/nonce.
4. Verify CJ high-risk tool approval in actual executor, not only README.
5. Verify OpenVision OpenClaw auth/reconnect and HFP battery under idle.
6. Create implementation issues only for demonstrated AWL gaps after examining AWL current code.

Audit status: **in progress, not complete**; source files inspected are narrow slices and do not establish end-to-end or hardware correctness.
