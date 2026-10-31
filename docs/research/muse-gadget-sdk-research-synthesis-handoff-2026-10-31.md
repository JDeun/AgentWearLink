# Muse Gadget SDK research synthesis and implementation handoff
Date: 2026-10-31
Status: **architecture research decision complete; upstream full-file static audit incomplete**
Source: https://github.com/facebookincubator/muse-gadget-sdk
AWL research PR: https://github.com/JDeun/AgentWearLink/pull/640

## Executive decision
Muse is a useful **architecture reference**, not a drop-in replacement for AWL's vendor-neutral Swift `DeviceAdapter` / OpenClaw integration. Retain AWL's existing adapter, interaction coordinator, bounded channel and vision contracts; borrow protocol invariants, cancellation, bounded buffers, replay fencing and permission boundaries only where independently validated. Do not couple AWL to Muse-hosted provisioning, VM leases or token service.

## Findings and decisions

| Domain | Evidence summary | Decision | Delivery issue |
|---|---|---|---|
| Device-to-agent commands | Muse has BLE setup, encrypted Home Link/Noise and command dispatch; AWL lacks typed bidirectional DeviceAction contract | BORROW typed opt-in command surface, not Muse command payloads | #633 |
| BLE and Noise | P256 BLE pairing + Noise XX, generation-fenced handover, BLE/Noise frame limits; BLE pairing may lack authenticated peer verification | EXPERIMENT protocol conformance and active-MITM defenses before implementation | #641, #637 |
| Voice | 24kHz PCM16LE 960-sample framing, session/turn lineage, bounded playback and explicit cleanup; AWL voice wake is not duplex voice | BORROW stale-turn and cancellation invariants; EXPERIMENT independent realtime voice adapter | #634, #638 |
| Backpressure | Muse credits, bounded framing and queue caps; AWL drop-oldest ring can discard terminal events | BORROW credit-aware bounded delivery; KEEP AWL abstraction; enforce terminal event reliability | #635 |
| Capability negotiation | Muse board/feature flags vary by hardware and memory; AWL CapabilitySet has reserved outputs | EXPERIMENT versioned capability descriptors; KEEP backwards compatibility | #636 |
| Camera and video | Android/iOS send video toward gadget, Watcher JPEG capture is device-to-command; unauthenticated optional Wi-Fi video listener | KEEP one-shot vision, EXCLUDE unauthenticated video listener, EXPERIMENT opt-in streaming | #638, #637 |
| Security and credentials | ESP32 NVS may run plaintext by config; serial SDK token provisioning; Linux token rotation; privileged `system.run` invokes shell | EXCLUDE implicit plaintext fallback and unrestricted shell; BORROW fail-closed storage and redirect bearer removal | #637 |
| Diagnostics | ESP32 bug report includes raw log tail as base64 with `contains_pii=true`; profile label does not prove redaction | EXCLUDE automatic raw-log upload; structured allowlist, consent, redaction, retention | #637 |
| Firmware, OTA and power | ESP-IDF 6.0.1, board overlays, OTA/secure-boot configuration, camera/power ownership and bounded resource use | BORROW lifecycle and threat-model controls, not board-specific firmware | #638 |
| Apple Watch | Muse mobile demos are phone video senders, not a watchOS agent adapter | KEEP vendor-neutral adapter; implement WatchConnectivity relay PoC | #642 |
| License and services | Third-party codec licensing and Muse cloud token/VM services have separate constraints | EXCLUDE unreviewed source copying; audit per-file licenses and service independence | #639 |

## Static audit coverage and research limitation
Recursive upstream tree inventory: **1,096 blobs**, of which **322 were path-classified as first-party runtime candidates** (includes headers, build metadata and large generated font tables). Multiple targeted content-level investigations were documented in this PR, including BLE/Noise, Linux service, ESP32 firmware, iOS/Android video, security, tests and board overlays. **The 322 candidates have NOT all undergone individual content-level inspection.** The tree count is not a reviewed-file count. No upstream runtime test, firmware build or hardware test was executed as part of this synthesis.

The architectural decision is sufficiently supported to **proceed with scoped AWL implementation experiments**, but this does not close the user's separate request for 322-file content audit. Track that as a distinct, explicit audit deliverable, not an implicit part of implementation issues.

## Delivery order and acceptance
1. **P0 foundations:** #637 security/threat model; #635 terminal-event and backpressure invariants; #633 typed DeviceAction contract.
2. **P0 protocol:** #641 BLE-to-Noise conformance, test vectors, and negative cases; gate any cryptographic reuse on this.
3. **P1 adapters:** #636 capability descriptors, #634 realtime voice lifecycle, #642 WatchConnectivity adapter.
4. **P1 evidence:** #638 real device camera/voice, fault injection and benchmarks; #639 legal/service independence before copying code.
5. **Audit gate:** complete the 322-file file-by-file ledger separately, including SHA, role, entrypoints, guards, tests, license/provenance and disposition. Do not claim complete until all 322 are accounted for.

## Research index
- [Architecture overview](muse-gadget-sdk-architecture-audit-2026-10-31.md)
- [Closure matrix](muse-awl-research-closure-matrix-2026-10-31.md)
- [BLE/Noise E2E call paths](muse-esp32-awl-e2e-callpaths-2026-10-31.md)
- [Pairing test boundaries](muse-ble-pairing-test-boundaries-2026-10-31.md)
- [Security/OTA/voice](muse-privilege-ota-voice-boundaries-2026-10-31.md)
- [Negative test evidence](muse-negative-test-evidence-2026-10-31.md)
- [Android/iOS video](muse-mobile-video-codec-audit-2026-10-31.md)
- [Unauthenticated video plane](muse-unauthenticated-video-plane-audit-2026-10-31.md)
- [Board capability evidence](muse-board-overlays-capability-evidence-2026-10-31.md)
- [Dependencies and licensing gates](muse-dependency-provenance-closure-gates-2026-10-31.md)
- [Inventory and CI](muse-repository-inventory-ci-audit-2026-10-31.md)
- [Path classification](muse-upstream-path-classification-pr-readiness-2026-10-31.md)
- [Security code review](muse-first-party-security-source-batch1-2026-10-31.md)
- [Android/Linux code review](muse-android-linux-content-audit-batch-2026-10-31.md)
- [Linux/iOS/Noise code review](muse-linux-ios-noise-content-audit-2026-10-31.md)

## Definition of research closure
**Closed:** technology-selection decisions and issue handoff. **Open:** full upstream 322-file content audit, CI/hardware execution, proof of license compliance and code integration. The synthesis is an architecture research handoff, not a security certification.
