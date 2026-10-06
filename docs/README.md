# Documentation

This directory is the implementation and validation documentation for AgentWearLink.

## Start here

| Document | Purpose |
| --- | --- |
| [PRD.md](PRD.md) | Canonical product and implementation requirements |
| [architecture.md](architecture.md) | Package boundaries and system architecture |
| [testing.md](testing.md) | Test strategy and validation layers |
| [reliability-matrix.md](reliability-matrix.md) | Deterministic vs physical reliability checks |

## Device integration

- [meta-dat-ios.md](meta-dat-ios.md) — Meta DAT iOS integration
- [meta-dat-known-issues.md](meta-dat-known-issues.md) — known DAT constraints and validation notes
- [meta-dat-validation.md](meta-dat-validation.md) — P0-A physical DAT validation runbook
- [meta-mock-device-kit.md](meta-mock-device-kit.md) — MockDeviceKit setup, capabilities, limitations, and AWL test architecture

## OpenClaw integration

- [openclaw.md](openclaw.md) — OpenClaw architecture and protocol integration
- [openclaw-probe.md](openclaw-probe.md) — read-only Gateway/authentication probe
- [openclaw-chat-probe.md](openclaw-chat-probe.md) — explicit mutating text E2E probe
- [p0b-openclaw-validation.md](p0b-openclaw-validation.md) — full iPhone/Tailnet/OpenClaw P0-B validation runbook

## Networking and transports

- [tailscale.md](tailscale.md) — reference private-network deployment
- [transports.md](transports.md) — transport boundaries and semantics

## Architecture decisions

- [ADR-0001](adr/0001-core-boundaries.md) — Core boundaries
- [ADR-0002](adr/0002-agent-runtime-owns-intelligence.md) — agent runtime owns intelligence

## Source of truth

When documents disagree, [PRD.md](PRD.md) is the implementation source of truth. Code and tests determine current implemented behavior; GitHub issues track validation work that remains open.
