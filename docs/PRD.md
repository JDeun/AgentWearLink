# AgentWearLink Product Requirements Document

**Version:** 0.1  
**Status:** Draft for implementation  
**Date:** 2026-10-06

## 1. Product definition

AgentWearLink (AWL) is an open interoperability layer between wearable devices and AI agent runtimes.

It converts vendor-specific wearable capabilities into normalized interaction events and connects them to replaceable agent adapters. The project is not an AI agent itself.

## 2. Problem

Wearable AI integrations tend to couple four concerns:

1. device vendor SDKs,
2. speech/vision transport,
3. a specific model provider,
4. agent orchestration.

This makes changing either the wearable or the agent runtime expensive. AWL introduces explicit boundaries between the device and agent sides.

## 3. Goals

- Define a small capability-based DeviceAdapter contract.
- Define an AgentAdapter contract supporting request/response streaming.
- Normalize text, audio, image, invocation, lifecycle, and error events.
- Keep model routing, memory, RAG, and tools outside the core.
- Validate the design against real hardware and a real agent.
- Support secure authenticated transports and robust reconnect semantics.

## 4. Non-goals

The core will not implement:

- an LLM router,
- persistent agent memory,
- RAG,
- MCP/tool orchestration,
- a replacement chat application,
- continuous camera surveillance,
- speculative integrations that cannot be tested.

## 5. First reference implementation

### Device side

Ray-Ban Meta via Meta Wearables DAT on iOS.

### Agent side

OpenClaw.

### MVP interaction

1. User initiates an interaction.
2. Wearable speech/audio is normalized by the device adapter.
3. The event is sent to the connected agent adapter.
4. The agent runtime performs its existing model/tool/memory work.
5. Streaming output returns to the companion.
6. Text is rendered and optionally spoken through device audio.
7. Vision is captured only for an explicit vision interaction.

The user's OpenClaw deployment may mirror/log the interaction to Telegram, but Telegram is not an AWL core dependency.

## 6. Functional requirements

### FR-1 Device capabilities
A device adapter must expose supported input/output capabilities without forcing unsupported features.

### FR-2 Sessions
The core must represent interaction start, active, interruption, completion, disconnect, reconnect, and failure.

### FR-3 Events
The core must support normalized text and lifecycle events first, with audio/image payloads added behind capability checks.

### FR-4 Agent transport
An agent adapter must accept normalized requests and expose incremental responses where supported.

### FR-5 Output
Responses must be routable to text and speech/audio output without requiring a specific TTS vendor.

### FR-6 Vision
Image capture must be explicit/event-driven by default.

### FR-7 Failure semantics
Authentication, transport, capability, timeout, device, and agent failures must be distinguishable.

## 7. Non-functional requirements

- No credentials in source control.
- Secrets stored using platform secure storage.
- No public unauthenticated agent gateway.
- Bounded buffers for streaming media.
- Cancellation/backpressure for long-running streams.
- Deterministic session ownership.
- Useful diagnostics without logging secrets or raw private media by default.
- Core contracts should not expose Meta/OpenClaw-specific types.

## 8. Delivery gates

### P0-A — Hardware validation
Build an official DAT sample on a physical iPhone and validate glasses connection, camera, microphone/audio, disconnect/reconnect.

### P0-B — Text E2E
AWL core contracts + OpenClaw adapter; manual app trigger; streaming text response.

### P0-C — Audio E2E
Wearable audio/speech → agent → TTS/audio output.

### P0-D — Hands-free invocation
Validate DAT voice invocation including lock-screen/background behavior.

### P1 — Event-driven vision
Explicit camera snapshot → multimodal-capable agent path.

### P2 — Reliability
Recovery, network transitions, interruption, bounded queues, observability, privacy/security hardening.

## 9. Success criteria

The first reference implementation succeeds when a locked/pocketed iPhone can support a repeatable wearable interaction with the existing agent runtime, return an audible response, and preserve the agent's existing conversation/tool semantics without creating a second AI agent.

## 10. Extension criteria

A second device or agent implementation should be addable without modifying the opposite adapter. Generic abstractions will only be expanded when a concrete second implementation demonstrates the need.
