# AgentWearLink

**An open interoperability layer between wearable devices and AI agent runtimes.**

[한국어](README.ko.md) · [Architecture](docs/architecture.md) · [PRD](docs/PRD.md) · [Testing](docs/testing.md)

AgentWearLink (AWL) normalizes wearable input/capture capabilities—speech, audio, camera snapshots, and invocation—behind replaceable adapters, connects them to an existing AI agent runtime, and composes host output such as native TTS through a separate output sink.

> **Status:** pre-alpha. Core and OpenClaw foundations are implemented and tested. Meta DAT registration/device-session lifecycle, Speech, and bounded camera snapshots are production-wired; Voice Invocation, live-capability and foreground/background composition are implemented and covered by deterministic and vendor-backed mock tests; physical acceptance remains open. Physical Ray-Ban Meta + iPhone validation is still in progress.

## Why

Wearable integrations are often coupled to one device vendor, model provider, or chat surface. AWL separates the layers:

```text
Wearable SDK          AgentWearLink Core          Agent runtime
─────────────          ──────────────────          ─────────────
Meta DAT      ──────▶  normalized events  ──────▶ OpenClaw
future SDKs            capabilities               future runtimes
custom devices         lifecycle/streaming        local/custom agents
```

The agent runtime continues to own models, memory, tools, RAG, MCP, routing, and orchestration.

## Reference implementation

The first end-to-end target is:

- **Wearable:** Ray-Ban Meta
- **Phone:** iPhone + Meta Wearables Device Access Toolkit (DAT)
- **Agent:** OpenClaw on a Mac mini
- **Private network:** Tailscale
- **Output:** native Apple TTS via `AVSpeechSynthesizer`
- **Vision:** explicit, event-driven snapshots only

Meta DAT, OpenClaw, Tailscale, Telegram, and Apple TTS are reference integrations—not Core dependencies.

## What is implemented

- vendor-neutral capability and interaction contracts
- deterministic interaction/runtime lifecycle
- bounded async streaming and SSE parsing
- HTTP transport primitives
- native OpenClaw Gateway WebSocket transport
- OpenClaw device identity, challenge proof, pairing, RPC dispatch, streaming agent runs, cancellation, and reconnect supervision
- read-only OpenClaw health probe
- explicit mutating OpenClaw text E2E probe
- pinned Meta DAT 1.0.0 integration with production-wired registration/device-session lifecycle; camera, Speech, Voice Invocation, live-capability and foreground/background policies are composed in the production reference host and verified with pinned vendor MockDeviceKit integration; physical behavior remains unverified
- bounded explicit vision contracts with pre-capture agent capability checks
- typed host `InteractionOutputSink` composition plus Apple native `AVSpeechSynthesizer` output
- deterministic reliability regression suite

MockDeviceKit app-hosted integration is CI-gated with the Core and vendor adapter tests. Real Bluetooth, camera sensor timing/photo transfer, wearable audio routing, locked/pocketed invocation, mobile Tailnet transitions, and live vision remain physical/deployment gates.

## Packages

| Package | Responsibility |
| --- | --- |
| `AgentWearLinkCore` | Vendor-neutral capabilities, events, lifecycle, streaming, vision contracts |
| `AgentWearLinkOpenClaw` | OpenClaw Gateway/auth/RPC/agent integration |
| `AgentWearLinkMetaDAT` | Meta DAT adapter boundary |
| `AgentWearLinkAppleOutput` | Apple-host speech output lifecycle and native TTS bridge |

## Quick start

The vendor-neutral root package supports Swift 5.10+ and macOS 14+. The concrete `Adapters/MetaDAT` integration requires a Swift 6.0+ toolchain because the pinned Meta DAT 1.0.0 dependency uses a Swift 6 package manifest; the AWL integration sources are intentionally kept in Swift 5 language mode during migration. Its reference iOS host targets iOS 17.2+.

```bash
git clone https://github.com/JDeun/AgentWearLink.git
cd AgentWearLink
swift test
```

For Meta DAT integration work, verify a Swift 6-capable toolchain before resolving or building the adapter. The toolchain requirement does not imply that AWL's Meta sources have already migrated to Swift 6 language mode:

```bash
swift --version
cd Adapters/MetaDAT
swift package resolve
```

For a live OpenClaw deployment, first use the read-only probe documented in [docs/openclaw-probe.md](docs/openclaw-probe.md). The mutating P0-B text validation is documented in [docs/openclaw-chat-probe.md](docs/openclaw-chat-probe.md).

## Design invariants

1. Vendor SDK types do not leak into Core.
2. AWL does not reimplement agent intelligence.
3. Unsupported capabilities are not advertised.
4. Camera capture is explicit; continuous vision is not the default.
5. Media and stream queues are bounded.
6. Reconnect restores transport availability but never silently replays an uncertain mutating request.
7. Credentials and device private keys stay outside source control.
8. New abstractions require a real integration need rather than speculative generality.

## Roadmap

| Gate | Target |
| --- | --- |
| P0-A | Physical Meta DAT validation |
| P0-B | iPhone → Tailnet → OpenClaw text E2E |
| P0-C | Wearable audio → agent → native TTS/audio |
| P0-D | Hands-free DAT voice invocation |
| P1 | Physical event-driven vision E2E |
| P2 | Physical reliability, privacy, and recovery matrix |
| P3 | Additional device/agent adapters driven by real integrations |

See [docs/PRD.md](docs/PRD.md) for the canonical implementation requirements.

## Documentation

Start at [docs/README.md](docs/README.md) for the documentation map. Architecture decisions are recorded under [docs/adr](docs/adr).

## Contributing

AgentWearLink is pre-alpha, so changes should preserve package boundaries and include deterministic tests where possible. See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Security

Do not report credentials, private device keys, or private media in a public issue. See [SECURITY.md](SECURITY.md).

## License

Licensed under the Apache License 2.0. See [LICENSE](LICENSE).
