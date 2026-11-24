# OpenClaw real Gateway: grant contract stage attribution

Date: 2026-11-24. Pinned upstream: `172a5d6202214eea253234c3b04c8184df9fea70`.

## Evidence correction

Companion run [45319257400](https://github.com/JDeun/AgentWearLink/actions/runs/45319257400) failed in the CI step named "Reconnect with issued read-only device grant in a second Swift process". Its actual message was `Isolated real Gateway disposable-grant-contract failed: handshake-or-protocol-failure (last-phase=connect-sent, failure-class=hello-timeout)`. Inspection of the runner at head `9dbfab1` shows that this message is emitted from the initial grant-issuance branch, after the first subprocess returned nonzero. A failure in the second process instead prints "second-process grant-only reconnect failed". Thus the stage label alone did not establish second-process failure. Earlier [45311200520](https://github.com/JDeun/AgentWearLink/actions/runs/45311200520) succeeded; another failure occurred at positive health [45309920921](https://github.com/JDeun/AgentWearLink/actions/runs/45309920921).

The known observation is local send completion with no hello response before the client's 10 s receive deadline, not server receipt, a grant rejection or a Keychain failure. Pinned upstream [connect-hello](https://github.com/openclaw/openclaw/blob/172a5d6202214eea253234c3b04c8184df9fea70/src/gateway/server/ws-connection/connect-hello.ts) awaits membership preparation and sends hello; [connect-device-tokens](https://github.com/openclaw/openclaw/blob/172a5d6202214eea253234c3b04c8184df9fea70/src/gateway/server/ws-connection/connect-device-tokens.ts) awaits grant creation. These are possible pre-hello latency contributors, not proven causes.

## Diagnostic change

Emit separate allowlisted issuance and stored-grant-reconnect phase/result, elapsed milliseconds and Gateway process liveness. Require the authenticated health marker as well as exit zero. Clear diagnostic markers between processes. Preserve existing structured startup-pending retry rule, do not retry unclassified hello-timeout or auth failures, and do not change the production deadline, scopes, identity or credentials. No raw Gateway output, tokens or request IDs are logged. The next real run can distinguish cold-start/issuance and stored-token reconnect. This change is diagnostic and must not be presented as a resolved transport defect.

Follow-up: if the same phase recurs, instrument pinned upstream with an isolated, redacted phase-only trace (without altering the canonical contract gate), compare server pre-hello admission/processing duration to client deadline, and separately investigate client socket receipt. Avoid masking the failure with a blanket timeout increase or repeated authentication.
