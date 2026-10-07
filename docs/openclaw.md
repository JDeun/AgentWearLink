# OpenClaw reference adapter

AgentWearLink's first agent-runtime integration uses OpenClaw Gateway while keeping OpenClaw responsible for models, tools, memory, permissions, and session semantics.

## Preferred path: native Gateway WebSocket

The primary adapter is `OpenClawNativeAgentAdapter`. It uses the native Gateway WebSocket protocol and implements:

- Gateway challenge/hello authentication
- persistent device identity and credential reuse
- RPC dispatch and correlation
- agent run submission and terminal wait
- incremental agent updates
- cancellation
- bounded reconnect supervision
- preservation of accepted OpenClaw session keys

A reconnect restores transport readiness. It does **not** silently replay an in-flight request whose delivery or completion is uncertain.

### Gateway client identity

AWL uses OpenClaw's canonical protocol-v4 client registry instead of inventing a private client ID or treating the operator role as a client mode. The production native adapter identifies as `gateway-client` / `backend`; the read-only validation probe uses `openclaw-probe` / `probe`. AWL deliberately does not claim the official `openclaw-ios` application identity.

The same client ID, mode, platform, and device family are used both in the emitted connect frame and in the signed V3 device-proof tuple.

## Compatibility path: Chat Completions

`OpenClawChatCompletionsAdapter` remains available for OpenClaw's OpenAI-compatible HTTP/SSE endpoint. That endpoint must be explicitly enabled in OpenClaw:

```json5
{
  gateway: {
    http: {
      endpoints: {
        chatCompletions: { enabled: true }
      }
    }
  }
}
```

The compatibility adapter requests streaming responses, bounds individual SSE events, and maps content deltas into AWL response deltas. Do not confuse this HTTP/SSE path with the preferred native Gateway transport.

## Deployment

The intended personal reference topology is:

```text
Ray-Ban Meta → iPhone/AWL → Tailscale → Mac mini → OpenClaw Gateway
```

Tailscale is an exposure profile, not an AWL dependency. Prefer a private authenticated WSS endpoint such as Tailscale Serve where practical. See [tailscale.md](tailscale.md).

## Session ownership

AWL transports an interaction into OpenClaw; it does not recreate OpenClaw's agent state. Existing model/tool/memory/session behavior remains owned by OpenClaw.

For the native adapter, the session key returned by an accepted run is retained as the authoritative run context. For the Chat Completions compatibility path, a stable AWL conversation identifier is mapped into the endpoint's session semantics.

Telegram is optional visibility only. It is never required as AWL transport.

## Credentials, diagnostics, and least privilege

Reusable Gateway credentials and device private material belong in Keychain or equivalent secure storage. They must not be committed, logged, or exposed through diagnostic descriptions. Configuration diagnostics redact bearer credentials, stable conversation/session routing identifiers, private text, and private media payloads. Test and CI fixtures must use synthetic, non-sensitive values.

Tailnet reachability is not authorization. Gateway authentication remains required by the selected OpenClaw deployment mode.

Request only the scopes required by the active workflow:

- read-only validation/probes use `operator.read`;
- interactive agent submission/cancellation requires the write capability in addition to the read capability used by the reference flow;
- do not request broader scopes merely because the Gateway account can grant them.

A persisted device credential keeps the exact scopes that were previously approved. When AWL reconnects with that stored credential, a caller asking for additional scopes does **not** silently widen the grant: the assembler reuses the stored scope set. A broader grant must therefore go through an explicit authorization/pairing or credential-replacement flow accepted by the Gateway. Local role/scope admission enforcement is tracked separately in #292; this section documents the credential-request and upgrade policy rather than claiming that work is already complete.

## Validation status

Deterministic tests cover protocol framing, authentication/pairing contracts, RPC routing, incremental run updates, cancellation, reconnect boundaries, credential persistence, and secret-redaction invariants.

Still requiring deployment/physical evidence:

- iPhone → Tailnet → Mac mini/OpenClaw live text E2E
- persistent credential reuse against the real Gateway
- existing-session incremental streaming against the real Gateway
- Wi-Fi/cellular/Tailnet transition behavior

Use [openclaw-probe.md](openclaw-probe.md) for the read-only probe, [openclaw-chat-probe.md](openclaw-chat-probe.md) for the explicit mutating probe, and [p0b-openclaw-validation.md](p0b-openclaw-validation.md) for the full P0-B runbook.
