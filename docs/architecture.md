# Architecture

## Boundary

AgentWearLink is an I/O interoperability layer, not an agent runtime.

```text
Device SDK
   │
DeviceAdapter
   │
   ▼
┌────────────────────────────┐
│ AgentWearLink Core         │
│                            │
│ CapabilitySet              │
│ InteractionEvent           │
│ Session                    │
│ Cancellation / Backpressure│
│ Failure model              │
└─────────────┬──────────────┘
              │
         AgentAdapter
              │
              ▼
        Agent Runtime
```

## Core contracts

### DeviceAdapter

Responsibilities:

- connect/disconnect device session
- advertise capabilities
- emit normalized input/lifecycle events
- accept supported output commands
- hide vendor SDK types from the core

### AgentAdapter

Responsibilities:

- authenticate/connect to an agent runtime
- map normalized AWL requests to runtime requests
- stream normalized responses
- expose cancellation/failure semantics
- hide runtime-specific protocol types from the core

## Capability model

Initial capability vocabulary:

- textInput
- speechInput
- rawAudioInput
- cameraSnapshot
- speakerOutput
- textOutput
- voiceInvocation

Capabilities are negotiated, not assumed.

## Event model

Initial events:

- sessionStarted
- sessionEnded
- text
- invocation
- interruption
- error

Private media crosses AWL boundaries only through explicit bounded contracts. Image snapshots already use bounded `ImageAttachment` ownership; raw audio remains capability-gated until an integration proves explicit ownership, cancellation, retention, and backpressure semantics.

## Session invariants

- One interaction has one stable correlation ID.
- An interaction may produce a later, distinct agent submission after a prior submission has terminated; only one submission for the same interaction is admitted concurrently by the coordinator.
- Each logical runtime submission owns a separate adapter/runtime idempotency identity. Reconciliation of the same submission reuses that identity, while a new submission receives a fresh identity even when its Core `InteractionID` is unchanged.
- Cancellation is idempotent.
- Late responses from a cancelled interaction are ignored.
- Device reconnect does not silently create duplicate agent requests.
- Agent reconnect does not silently replay mutating requests.
- Media buffers are bounded.

## Reference adapters

```text
Meta Wearables DAT
      │
 MetaDATAdapter
      │
    AWL Core
      │
 OpenClawAdapter
      │
   OpenClaw
```

Meta DAT and OpenClaw types must not leak into AWL Core.

## Deployment surfaces

Tailscale and Telegram are deployment choices, not Core dependencies. Tailscale may provide private reachability to an agent runtime; it does not replace runtime authentication. Telegram may remain a visible conversation surface through OpenClaw, but AWL does not call or synchronize Telegram directly.

## Security

- credentials: platform secure storage
- transport: TLS/private network + authentication; bearer-token HTTP compatibility paths require HTTPS except explicit loopback development endpoints
- logs: redact credentials and sensitive payloads
- camera: explicit capture
- microphone/media: no persistence by default
- gateway: never assume trusted public network

## Evolution rule

Do not generalize an interface because a hypothetical future integration might need it. Generalize when a concrete adapter proves the requirement.
