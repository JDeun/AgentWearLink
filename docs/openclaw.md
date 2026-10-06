# OpenClaw reference adapter

AgentWearLink integrates with OpenClaw through the official Gateway WebSocket protocol.

## Baseline

Validated against the public protocol documentation on 2026-10-06:

- WebSocket text frames containing JSON
- first client request: `connect`
- protocol version: v4 for current operator/UI clients
- frame families: `req`, `res`, `event`
- default Gateway port: `18789`
- pre-auth frame ceiling: 64 KiB
- negotiated limits come from `hello-ok.policy`
- authenticated clients should honor the scopes returned by `hello-ok.auth`
- reconnect must not silently replay rejected requests

## AWL role

The first reference adapter connects as an operator client because it needs to submit/observe agent work rather than act as a wearable node that exposes host commands.

The requested scope set must remain minimal for the actual RPCs used.

## Conversation ownership

AWL must reuse the target OpenClaw session/conversation semantics rather than creating a second agent. Telegram or another channel may remain a visible log/delivery surface owned by OpenClaw.

## Security

- Prefer a private Tailnet/LAN path or secure `wss://`.
- Never commit Gateway tokens/passwords.
- Store reusable credentials in iOS Keychain.
- Validate negotiated payload/buffer limits after every reconnect.
- Never log connect auth frames.
- Do not automatically replay a failed mutating request after reconnect.

## Implementation sequence

1. Protocol frame models and tests.
2. WebSocket lifecycle + connect handshake.
3. Parse `hello-ok` and negotiated limits.
4. RPC request correlation.
5. Agent/session RPC mapping.
6. Stream agent events into `AgentResponse`.
7. Cancellation.
8. Reconnect without silent replay.
9. Real Gateway integration test.
