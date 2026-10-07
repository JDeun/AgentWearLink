# AgentWearLink Product Requirements Document

**Version:** 0.2  
**Status:** Implementation source of truth  
**Date:** 2026-10-07  
**Repository:** AgentWearLink

> This document is the canonical product/scope handoff for continuing work in a new session. Read it together with `docs/architecture.md`, ADRs, open GitHub issues, and the current code before changing architecture.

## 1. Product definition

AgentWearLink (AWL) is an open interoperability layer between wearable devices and AI agent runtimes.

It converts vendor-specific wearable capabilities into normalized interactions and connects them to replaceable agent/runtime adapters. AWL is not an AI agent, model router, memory system, or chat service.

**Tagline:** Connect any wearable to any AI agent.

## 2. Reference deployment

The architecture is device-agnostic and agent-agnostic. The first implementation is deliberately narrow:

- Wearable: Ray-Ban Meta
- Device SDK: Meta Wearables Device Access Toolkit (DAT)
- Companion: iPhone
- Agent runtime: OpenClaw on a Mac mini
- Private network: Tailscale
- Preferred Gateway exposure: Tailscale Serve/WSS to an OpenClaw Gateway bound to loopback
- Visible conversation/log surface in the owner's deployment: Telegram through OpenClaw
- Initial TTS: iOS native speech synthesis
- Vision: explicit/event-driven snapshots only

Neither Meta, Ray-Ban, OpenClaw, Tailscale, Telegram, nor a TTS vendor may become an AWL Core dependency.

## 3. Problem

Wearable AI integrations commonly couple:

1. vendor SDK/device lifecycle,
2. media and invocation behavior,
3. network transport,
4. a specific model/provider,
5. agent orchestration and memory,
6. a specific chat/logging surface.

That coupling makes either side difficult to replace. AWL defines stable boundaries and lets the device and agent runtime evolve independently.

## 4. Architecture invariants

```text
Wearable
   │
DeviceAdapter
   │
AgentWearLinkCore
   │
AgentAdapter
   │
runtime-specific adapter
   │
transport
   │
AI agent runtime
```

The following are invariants:

- Vendor SDK types do not leak into Core.
- Runtime-specific types do not leak into Core.
- Device events and agent request/response contracts remain distinct.
- Core does not decide which LLM/model/tool/memory to use.
- Reconnect restores transport state; it never silently replays uncertain mutating requests.
- Media queues are bounded.
- Unsupported capabilities are not advertised.
- Continuous camera capture is out of scope.
- Generic abstractions are expanded only when a real second implementation proves the need.

## 5. Current package boundaries

- `AgentWearLinkCore`: capabilities, normalized interactions, coordinator/runtime, generic transport primitives and deterministic mocks.
- `AgentWearLinkOpenClaw`: OpenClaw-specific HTTP/native Gateway protocol integration.
- `Adapters/MetaDAT`: pinned Meta DAT 1.0.0 integration. Registration, selected-device handling, and device-session lifecycle are production-wired. Camera, Speech, Voice Invocation, live-capability, and foreground/background policy slices are implemented/tested but still require composition into the concrete production session path (#230). Simulator/mock support remains isolated from the production target.

Future device/runtime adapters should remain outside Core.

## 6. Functional requirements

### FR-1 Capability discovery

A DeviceAdapter exposes only implemented and currently available capabilities.

Current capability vocabulary includes text input, speech input, raw audio input, camera snapshot, speaker output, text output, and voice invocation. Speaker/text output bits are reserved for a future device-owned callable output surface; the current reference iPhone TTS/UI path is host-owned and is composed through `InteractionOutputSink`, so reference DeviceAdapters must not advertise those bits merely because the phone can render output.

### FR-2 Interaction lifecycle

AWL must represent stable interaction correlation IDs, start, text/invocation, interruption, completion, cancellation and typed failure. A Core `InteractionID` is not itself a runtime idempotency key: a later logical agent submission may reuse the same interaction correlation ID after the prior submission has terminated.

### FR-3 Agent boundary

Agent requests/responses are distinct from wearable events. Incremental output is supported where the runtime provides it. Runtime adapters must give each logical mutating submission its own stable idempotency identity: the same submission keeps that identity for reconciliation, while a genuinely new submission receives a fresh identity.

### FR-4 Runtime lifecycle

Runtime start/stop must be deterministic and idempotent. Cancellation must propagate across the boundary. Completed tasks must not be retained. Normalized runtime output may be delivered through a typed `InteractionOutputSink`; host output lifecycle must remain separate from wearable input ownership.

### FR-5 Transport

Supported transport architecture includes buffered HTTP, SSE primitives, WebSocket, and future local IPC. Transport and agent semantics remain separate.

### FR-6 OpenClaw

Two integration paths are allowed:

1. HTTP Chat Completions compatibility path.
2. Native Gateway WebSocket path — preferred for session-aware, low-latency integration.

Native Gateway work must follow the current official protocol rather than guessed wire formats.

### FR-7 Tailscale deployment

Tailscale is an endpoint/security profile, not an SDK dependency.

Preferred owner topology:

```text
iPhone / AWL
    │
Tailscale tailnet
    │
WSS / Tailscale Serve
    │
Mac mini loopback
    │
OpenClaw Gateway :18789
```

AWL must tolerate Wi-Fi/cellular transitions, Tailnet re-establishment, Gateway restart, and Mac sleep/restart.

### FR-8 OpenClaw device identity

A remote mobile client must support OpenClaw's current device identity/pairing model:

- persistent Ed25519 device identity,
- wait for `connect.challenge`,
- bind the server nonce/timestamp into the signed device proof,
- persist issued device token and approved grant securely,
- handle pairing-required as an explicit state,
- require fresh authenticated connect after approval,
- re-read negotiated policy on every reconnect.

Private Tailnet reachability does not replace device authorization.

### FR-9 Speech/audio

The first implementation should prefer Meta DAT speech/ASR when viable and iOS native TTS for response speech. Raw audio transport is added only with explicit ownership, cancellation, buffer and retention rules.

### FR-10 Vision

Camera access is event-driven. An image is captured only for an explicit vision interaction and only sent when the target agent path supports image input.

### FR-11 Existing agent semantics

AWL must use the existing OpenClaw agent/session semantics. It must not create a parallel intelligence layer.

Telegram may remain a canonical visible history/delivery surface in the owner's deployment, but AWL does not call Telegram directly.

## 7. Security and privacy requirements

- No credentials or device private keys in source control.
- iOS secrets/device identity stored in Keychain/Secure Enclave-compatible platform storage where practical.
- Prefer private WSS/TLS paths.
- Honor negotiated Gateway payload/buffer/attachment limits.
- Never log authentication frames, tokens, private keys or raw private media.
- Pairing/scope upgrades require explicit handling.
- Request minimum necessary OpenClaw scopes.
- A disconnected/reconnected socket does not imply an application request may be replayed.
- Media retention defaults to none.

## 8. Reliability requirements

Must test:

- duplicate request suppression,
- cancellation races,
- task cleanup,
- device reconnect,
- agent/Gateway reconnect,
- Wi-Fi ↔ cellular transition,
- Tailnet tunnel re-establishment,
- late responses after cancellation,
- non-monotonic/stale Gateway events,
- bounded producer queues,
- TTS interruption,
- background/foreground transitions,
- Gateway policy changes after reconnect,
- pairing/token rotation/revocation.

## 9. Test layers

### Layer 1 — deterministic Core CI

No network/vendor SDK. AWL mocks validate lifecycle and contracts.

### Layer 2 — integration

- Meta Mock Device Kit ↔ Meta adapter
- local/mock HTTP/SSE/WebSocket ↔ transports
- development OpenClaw Gateway ↔ OpenClaw adapter

### Layer 3 — physical E2E

Ray-Ban Meta + physical iPhone + Mac mini/OpenClaw over the intended Tailnet.

Hardware-dependent features are not considered complete from mocks alone.

## 10. Delivery gates

### P0-A — Meta DAT physical validation

Validate official DAT sample on physical iPhone/Ray-Ban Meta: registration, connect, camera, speech/audio where exposed, disconnect/reconnect, OS/SDK/firmware versions.

### P0-B — Text E2E

Manual companion trigger → AWL → existing OpenClaw session → incremental text response over the real Tailnet.

### P0-C — Audio E2E

Wearable speech/audio → existing agent → streaming response → iOS TTS/device audio.

### P0-D — Hands-free invocation

Validate DAT/Hey Meta invocation, Korean behavior, lock-screen/background behavior and coexistence with Meta AI.

### P1 — Event-driven vision

Explicit vision intent → snapshot → capability check → multimodal agent path.

### P2 — Reliability/security

Network transitions, pairing, token rotation/revocation, reconnect, interruption, bounded queues, observability and privacy hardening.

## 11. Success criteria

The first reference implementation succeeds when:

1. the iPhone can remain locked/in a pocket during normal interaction,
2. the user initiates interaction from Ray-Ban Meta,
3. the existing OpenClaw runtime on the Mac mini handles the request,
4. the connection works through the intended private Tailnet deployment,
5. the response is returned audibly through the wearable path,
6. existing OpenClaw model/tool/memory/session behavior is preserved,
7. the interaction can remain visible in the existing Telegram workflow without Telegram becoming an AWL dependency,
8. explicit vision requests work without continuous capture.

## 12. Non-goals

AWL Core will not implement:

- LLM/model routing,
- persistent agent memory,
- RAG,
- MCP/tool orchestration,
- Telegram business logic,
- continuous surveillance,
- a replacement for OpenClaw/Hermes/etc.,
- speculative device/runtime adapters that cannot be tested.

## 13. Continuation checklist

When resuming work in another session:

1. Read this PRD.
2. Read `docs/architecture.md` and ADRs.
3. Inspect current `main`, open issues and open PRs.
4. Do not assume old OpenClaw or Meta DAT API shapes; verify current official docs.
5. Run/inspect CI before merging.
6. Preserve Core/vendor/runtime boundaries.
7. Continue the earliest unblocked delivery gate.
8. Record material architectural changes in this PRD and/or a new ADR.

## 14. Current implementation snapshot — 2026-10-06

Implemented code-side:

- capability/event/request/response contracts and coordinator/runtime;
- deterministic mock device/agent harness and bounded streaming/HTTP/SSE primitives;
- OpenClaw Chat Completions compatibility adapter;
- preferred native OpenClaw Gateway WebSocket stack: challenge/connect authentication, persistent Ed25519 device identity/Keychain credentials, negotiated policy, RPC/event dispatch, incremental agent runs, cancellation, reconnect supervision, event-sequence retirement, and probes;
- Meta DAT 1.0.0 pinned integration: production-wired registration/selected-device/device-session lifecycle, plus helper-implemented and deterministically tested live-capability, bounded camera capture/readiness/cancellation, Speech final-transcript filtering/deduplication, Voice Invocation acknowledgement/reopen, and foreground/background readiness slices; full production composition of those helper slices remains #230;
- Apple output/TTS boundary;
- deterministic privacy/reliability regressions including credential diagnostic redaction and representative no-replay transition scenarios.

Current unclosed evidence/work priorities:

1. compose Meta camera/Speech/Voice/capability/lifecycle helper slices into the concrete production session/adapter path (#230);
2. complete the real iOS app-hosted MockDeviceKit/XCUITest gate (#122);
3. run the read-only OpenClaw probe against the owner's Mac mini over Tailscale;
4. validate one existing-session incremental native agent turn over the real Tailnet (#97/#118);
5. validate persistent Gateway credential reuse in deployment (#117);
6. run physical Ray-Ban Meta + iPhone camera/Speech/Voice/lifecycle gates (#1/#98 and children);
7. complete physical reliability/privacy/network transition evidence (#59/#119/#120).

Helper implementation must not be reported as production wiring, and code-side completion must not be reported as deployment or physical completion. See `testing.md` for the evidence vocabulary.
