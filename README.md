# AgentWearLink

**An open interoperability layer between wearable devices and AI agents.**

AgentWearLink (AWL) connects wearable device capabilities—speech, audio, cameras, buttons, sensors, and output surfaces—to AI agent runtimes through explicit, replaceable adapters.

> **Project status:** pre-alpha / architecture and hardware validation.

## Why AgentWearLink?

Wearable integrations are commonly coupled to one device vendor, one model provider, or one agent runtime. AgentWearLink separates those concerns:

```text
Wearable / Device SDK
        │
   Device Adapter
        │
  AgentWearLink Core
        │
    Agent Adapter
        │
    AI Agent Runtime
```

The core is intended to remain **device-agnostic** and **agent-agnostic**.

## First reference implementation

The first implementation validates the architecture with:

- **Device:** Ray-Ban Meta through Meta Wearables Device Access Toolkit (DAT), using iOS.
- **Agent:** OpenClaw.
- **Interaction:** speech/audio first, event-driven camera snapshots, streaming responses, and device audio output.
- **Invocation:** manual interaction first; DAT voice invocation is a later reliability gate.

These are reference adapters, **not dependencies of the AgentWearLink core**.

## Design principles

1. **Adapters over vendor coupling.** Vendor SDK details stay behind device adapters.
2. **Agents stay agents.** Memory, tools, model routing, RAG, and orchestration belong to the connected agent runtime.
3. **Capability-driven I/O.** Devices advertise what they can input and output.
4. **Event-driven vision.** Camera access is intentional, not continuous by default.
5. **Streaming where it matters.** Interactive responses should not depend on polling.
6. **Local-first where practical.** Avoid unnecessary paid model or media services.
7. **Secure by default.** Credentials are never committed and transports must authenticate.

## Planned architecture

```text
┌──────────────── Device side ────────────────┐
│ Meta DAT │ future SDKs │ custom devices     │
└───────────────────┬─────────────────────────┘
                    │ DeviceAdapter
                    ▼
             ┌───────────────┐
             │ AWL Core      │
             │ capabilities  │
             │ events        │
             │ sessions      │
             │ streaming     │
             └───────┬───────┘
                     │ AgentAdapter
                     ▼
┌──────────────── Agent side ─────────────────┐
│ OpenClaw │ Hermes │ custom/local runtimes   │
└─────────────────────────────────────────────┘
```

## Scope

### AgentWearLink owns

- device capability normalization
- interaction/session lifecycle
- normalized multimodal events
- transport boundaries
- agent adapter contracts
- response streaming
- audio/output handoff
- reconnect and failure semantics

### AgentWearLink does not own

- LLM/model routing
- agent memory
- RAG
- tool/MCP orchestration
- business logic
- a canonical chat service

Those responsibilities remain with the connected agent.

## Roadmap

- **P0-A:** Meta DAT + physical iPhone/Ray-Ban hardware validation
- **P0-B:** generic core contracts + OpenClaw text E2E
- **P0-C:** Ray-Ban audio → agent → TTS/audio E2E
- **P0-D:** hands-free voice invocation
- **P1:** event-driven vision
- **P2:** reliability, recovery, telemetry, security hardening
- **P3:** additional device/agent adapters when real integrations require them

## Development rule

AgentWearLink will not add speculative adapters merely to appear generic. The interfaces are generic; implementations are added when they can be tested against a real device or agent runtime.

## License

License selection is pending the initial repository governance decision.
