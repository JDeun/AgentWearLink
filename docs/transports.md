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

## Request and buffered HTTP memory bounds

Core applies a default 256 KiB UTF-8 budget before dispatching an `AgentRequest`; callers can choose a different coordinator budget deliberately. Concrete transports must still enforce their own wire budget because encoded protocol overhead can exceed the source text size.

The baseline HTTP transport uses `maximumRequestBytes` as both a pre-encoding text ceiling and an exact post-encoding JSON body ceiling. Oversized text is therefore rejected before a large request body is constructed, while the exact encoded-size check preserves the wire contract.

The response is still semantically buffered: it is emitted only after the HTTP body completes. Its receive memory bound is enforced incrementally while downloading. `maximumResponseBytes` is therefore a hard response-body accumulation ceiling rather than a post-download validation limit. Known oversized `Content-Length` values are rejected before body consumption, and chunked/unknown-length responses are cancelled as soon as the next byte would exceed the configured ceiling.

## Planned transports

- buffered HTTP: baseline/simple compatibility with incrementally enforced response bounds
- SSE: when the target runtime exposes server-sent streaming
- WebSocket: bidirectional low-latency sessions
- local transport: future same-device/runtime integration

The concrete OpenClaw adapter will be implemented against the protocol actually exposed by the user's OpenClaw gateway rather than assumptions.
