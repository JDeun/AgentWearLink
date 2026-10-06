# OpenClaw reference adapter

AgentWearLink's first agent-side reference adapter targets OpenClaw's OpenAI-compatible Chat Completions endpoint.

## Why this endpoint

OpenClaw documents this endpoint as a normal Gateway agent run. It therefore keeps model routing, permissions, memory/session behavior, and tool execution in OpenClaw rather than reimplementing them in AWL.

The endpoint supports streaming responses and runs on the same Gateway port.

## Required OpenClaw configuration

The Chat Completions endpoint is disabled by default. Enable it explicitly:

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

Keep the Gateway on loopback, tailnet, or another private authenticated ingress.

## Authentication

With `gateway.auth.mode = "token"`, AWL sends:

```text
Authorization: Bearer <gateway token>
```

OpenClaw treats possession of this shared secret as full operator/owner authority. The token must therefore be stored in iOS Keychain or equivalent secure storage and must never be committed.

## Session behavior

AWL sets the OpenAI `user` field to:

```text
agentwearlink:<conversationID>
```

Reusing one conversation ID gives repeated wearable turns a stable OpenClaw agent session.

For explicit cross-client routing, `x-openclaw-session-key` can be configured. Do not use OpenClaw reserved internal namespaces.

## Channel context

The optional `x-openclaw-message-channel` header can provide synthetic ingress context for channel-aware policies. It is not a Telegram integration and does not make Telegram an AWL dependency.

## Streaming

The adapter requests `stream: true` and consumes OpenAI-compatible SSE data frames. Each content delta becomes an AWL `AgentResponse.textDelta`.

The adapter bounds individual SSE events and supports cancellation per `InteractionID`.

## Security

Do not expose the bearer-token endpoint directly to the public Internet. Prefer a private Tailnet/VPN or another authenticated private ingress.
