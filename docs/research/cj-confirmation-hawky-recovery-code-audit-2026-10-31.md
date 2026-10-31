# Focused upstream audit: CJ approval boundary and Hawky restart semantics (2026-10-31)

## CJ GOD MODE — actual code reviewed
Sources:
- https://github.com/GhanshyamPaunikar/rayban-meta-god-mode/blob/main/brain/app/mac.py blob `4c4675f32901533f4776b152a7305ff047fdca49`, lines 439–484, 558–596.
- https://github.com/GhanshyamPaunikar/rayban-meta-god-mode/blob/main/brain/app/main.py blob `8b3ebcabaea10eff634f8b734ef007052f1fcdba`, lines 36–42, 230–235.

Verified: `ACTIONS` contains per-action `confirm` strings; `handle()` calls `_prepare()` then sets `_pending=(name,args,time.time())` for protected actions, emits `mac_confirm`, and only calls `_execute` after a later `data["confirm"] is True` within 30 seconds. Thus README's assertion of a **code-level gate** has evidence for this Mac action path.

Security qualification: `_pending` is a **module-global single slot** and `handle(data)` accepts the model-provided `confirm` boolean. The examined code does not itself bind approval to a session, authenticated human event, nonce or exact turn identity. Whether an untrusted model output can produce an inappropriate confirmation depends on upstream model/tool and session controls, which remain to be traced. This is a **potential authorization design weakness**, not a demonstrated exploit. `main.py` uses `secrets.compare_digest` for HTTP bearer and WS pairing token validation; authenticated transport alone does not prove human confirmation.

For AWL, do not copy a model-generated confirmation flag as sole authorization. Bind approval to user gesture/verified input, task ID, action fingerprint, session and expiration, reject mismatched or replayed approval.

## Hawky — actual recovery logic reviewed
Sources:
- https://github.com/hao-ai-lab/hawky/blob/main/src/gateway/delegation-methods.ts blob `51e4de286b0d6506f0ec7eec02821acf724860d3`, lines 36–110.
- https://github.com/hao-ai-lab/hawky/blob/main/src/gateway/delegation-store.ts blob `86ebdf65b708757bce0df128f0074078fa0b784a`.

Verified: owner identity from `deviceTokenId`, ownerSession check on lookup, persistent JSON/JSONL store; `recover()` marks nonterminal non-active tasks `interrupted` with explicit instruction to inspect effects before retry. `cancel()` transitions to cancelling, persists event, aborts controller; task delivery status is separate from execution status. Input response checks `inputId` matches pending request. Caveat: actual runtime cancellation of external side effects and authorization of `ownerSession` at initial submit require more tracing.

## Cross-project AWL implications
1. Add/verify typed approval record `{actionId, requestId, sessionId, actionDigest, expiresAt, source, consumedAt}` and atomic one-shot consume.
2. Keep task state and delivery state distinct; mark unknown outcome `interrupted` after crash, never silently replay non-idempotent actions.
3. Ensure cancellation is best-effort for external actions and expose uncertainty to the user.
4. Scope tasks by authenticated device principal **and** session; never trust user-supplied session alone.
5. Test concurrent approval requests, approval replay, late confirmation, session crossover, disconnect/reconnect, crash during tool execution.

## Audit status
CJ Android Vosk lifecycle, other CJ phone-agent approval code, Hawky integration tests, TurboMeta gateway scopes, OpenVision handshake/reconnect tests and AWL current source gap comparison remain pending. No runtime tests executed.
