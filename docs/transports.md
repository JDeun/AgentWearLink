# Agent transports

AWL separates **agent semantics** from **wire transport**.

```text
AWL Core
   │ AgentRequest / AgentResponse
   ▼
AgentAdapter
   │ runtime mapping
   ▼
AgentTransport
   │ HTTP / SSE / WebSocket / local IPC
   ▼
Agent endpoint
```

## Why this boundary exists

A buffered HTTP request can be useful for tests and simple agents, but it is not equivalent to conversational streaming. OpenClaw or another runtime may expose a different protocol depending on deployment/version.

AWL therefore does not label buffered HTTP as streaming and does not hard-code a guessed OpenClaw wire format into the core.

## Transport requirements

A streaming transport must define:

- connection ownership
- authentication
- request correlation by `InteractionID`
- incremental text response
- completion
- cancellation
- timeout
- reconnect behavior
- bounded receive buffers/backpressure
- handling of late frames after cancellation
- behavior for mutating requests (never silently replay)

## Planned transports

- buffered HTTP: baseline/simple compatibility
- SSE: when the target runtime exposes server-sent streaming
- WebSocket: bidirectional low-latency sessions
- local transport: future same-device/runtime integration

The concrete OpenClaw adapter will be implemented against the protocol actually exposed by the user's OpenClaw gateway rather than assumptions.
