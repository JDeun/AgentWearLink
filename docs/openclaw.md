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
Production native WebSocket construction accepts a validated `OpenClawEndpoint`, not an arbitrary raw URL. The endpoint binds transport policy to an explicit exposure profile: loopback, Tailnet-direct, Tailscale Serve, or private reverse proxy. Loopback/Tailnet-direct hosts are validated against their expected address families, while Serve/reverse-proxy paths require `wss://`. This prevents a caller from bypassing transport policy by handing credentials to an arbitrary public `ws://` URL.


Accepted native runs also have a bounded terminal-wait policy: by default AWL performs at most 10 `agent.wait` polls with a 30-second Gateway timeout per poll. Bare wait-deadline timeouts and Gateway-draining wait interruptions remain non-terminal and are polled again; a timeout carrying terminal run metadata is surfaced immediately as a typed terminal-run timeout. Repeated non-terminal `pending`/wait-timeout results therefore end in a typed local poll-limit failure instead of retaining an interaction indefinitely. Expiry cleans the local run/update context and never resubmits the accepted run.

For each accepted run, AWL drains the run-local event stream before publishing terminal completion, ignores replayed/stale `agent` events whose payload `seq` is not newer than the highest accepted sequence, and reconciles the drained append-only text against `agent.wait.terminalReply.text`. An exact terminal replay emits nothing; a longer authoritative reply contributes only its missing suffix. A non-prefix correction fails closed because Core cannot safely express replacement through an append-only `textDelta`. Forward sequence gaps remain an authoritative-state recovery concern tracked separately in #280.

The native dispatcher treats negotiated `policy.maxBufferedBytes` as the byte budget for its own pre-subscription agent-event backlog, measured using received raw frame sizes. This is separate from the local per-frame inbound limit and the count-bounded active subscriber queues. Exceeding the negotiated backlog budget retires the current transport generation; a reconnect reads the replacement budget from the new hello snapshot.

Outbound native agent text is preflighted against the current negotiated `policy.maxPayload` before JSON frame encoding, and the completed frame is checked again for exact protocol size. The Chat Completions compatibility path similarly uses `maximumRequestBytes` before body encoding and again on the final JSON body. These checks complement Core's default 256 KiB request-text admission budget rather than replacing Gateway policy.

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

The compatibility adapter requests streaming responses, bounds individual SSE events, and maps content deltas into AWL response deltas. Because this path always carries a bearer credential, plain `http://` is accepted only for explicit loopback hosts (`localhost`, `127.0.0.0/8`, or `::1`); every non-loopback endpoint must use `https://`, including direct Tailnet addresses. Transport validation happens before the Authorization header can be sent. Do not confuse this HTTP/SSE path with the preferred native Gateway transport.

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

A persisted device credential keeps the exact scopes that were previously approved. When AWL reconnects with that stored credential, a caller asking for additional scopes does **not** silently widen the grant: the assembler reuses the stored scope set. A broader grant must therefore go through an explicit authorization/pairing or credential-replacement flow accepted by the Gateway. Native mutating RPCs (`agent`, `agent.wait`, and `chat.abort`) also require an authenticated `operator` role plus `operator.write` (or `operator.admin`) before any socket send, so a reduced grant is rejected locally as well as remaining subject to Gateway authorization.

## Validation status

Deterministic tests cover protocol framing, authentication/pairing contracts, RPC routing, incremental run updates, cancellation, reconnect boundaries, credential persistence, and secret-redaction invariants.

Still requiring deployment/physical evidence:

- iPhone → Tailnet → Mac mini/OpenClaw live text E2E
- persistent credential reuse against the real Gateway
- existing-session incremental streaming against the real Gateway
- Wi-Fi/cellular/Tailnet transition behavior

Use [openclaw-probe.md](openclaw-probe.md) for the read-only probe, [openclaw-chat-probe.md](openclaw-chat-probe.md) for the explicit mutating probe, and [p0b-openclaw-validation.md](p0b-openclaw-validation.md) for the full P0-B runbook.
