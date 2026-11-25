# AgentWearLink research register

Last reviewed: 2026-11-25. AWL baseline [bd9e75c](https://github.com/JDeun/AgentWearLink/tree/bd9e75cb424aea85e9182be53f8e8a92e4a40fa2). Canonical current decision/evidence index; dated reports remain historical snapshots. Issues own execution/acceptance, not a duplicate research corpus. Closed research decisions may be reference-only or deferred/no-go, never imply that physical trials passed.

## Maintenance contract

- SOURCE: immutable commit/blob or dated official documentation. REPORT: upstream/author claim, not independently reproduced. TEST: executed CI/harness at exact revision. PHYSICAL: sanitized measured owned-device/operator evidence with versions/conditions. UNKNOWN: missing/blocked.
- Record decision (keep/reference/experiment/defer/no-go) independently of evidence and outstanding action. No code, model or binary import without specific license/provenance/security review.
- Close a research issue only after linking the merged decision, transferring outstanding implementation/deployment/physical/monitoring requirements to named owners, and recording reopening triggers. Reassess when upstream revision, product requirements or contrary evidence changes.
- Do not equate static decisions, builds, deterministic fake exchanges, physical radio, supported vendor sessions and measured product capability.

## Research streams

| Issue | Evidence and decision | Remaining action / owner |
| --- | --- | --- |
| [#639](https://github.com/JDeun/AgentWearLink/issues/639) Muse license | [Dependency provenance](muse-dependency-provenance-closure-gates-2026-10-31.md); no vendor dependency approved | OPEN: [Linux/dependency audit](muse-linux-handover-audit-2026-11-25.md); [ESP32 file headers and boundaries](muse-esp32-main-audit-2026-11-25.md); [Main MIT/BSD notice exceptions](muse-esp32-main-residual-audit-2026-11-25.md); per-component/service terms and proposed reuse remain, #643/#637 |
| [#641](https://github.com/JDeun/AgentWearLink/issues/641) ESP32 BLE/Wi-Fi/Noise | [E2E call paths](muse-esp32-awl-e2e-callpaths-2026-10-31.md), [protocol audit](muse-protocol-firmware-test-audit-2026-10-31.md); reference, no Noise import | OPEN: [pinned host CI and shared vector evidence](muse-linux-handover-audit-2026-11-25.md); [ESP32 handover/ACK readiness audit](muse-esp32-main-audit-2026-11-25.md); [Main residual ACK/parser/cancel findings](muse-esp32-main-residual-audit-2026-11-25.md); independent Python↔ESP32 Noise duplex/fault runs and complete caller graph remain |
| [#643](https://github.com/JDeun/AgentWearLink/issues/643) 322-file Muse audit | [Pinned ledger](muse-runtime-audit-progress-2026-11-25.md); reconstructed 322 targets | OPEN: 124/322 file-specific initial content records (31 Linux + 93 ESP32 main), 198 inventory-only; [Main residual risk register](muse-esp32-main-residual-audit-2026-11-25.md), full reachability/security/test review remains |
| [#648](https://github.com/JDeun/AgentWearLink/issues/648) official wake/VAD | [DAT follow-up](meta-dat-visor-companion-followup-2026-11-24.md), [official reply](meta-dat-upstream-343-official-reply-2026-10-31.md); pinned DAT 1.1.0 no established public custom enrollment | OPEN: monitor #343, iOS/Android public interfaces/channel eligibility |
| [#649](https://github.com/JDeun/AgentWearLink/issues/649) tap/media | DAT 1.1.0 pause/resume, no established tap passthrough | OPEN: #646 actual controls, media ownership/UX and monitoring |
| [#652](https://github.com/JDeun/AgentWearLink/issues/652) OpenVision | [Pinned audit](third-party-wake-source-audit-2026-11-25.md); host Speech/HFP reference, no import | CLOSED completed static decision; physical/implementation residuals #634/#646/#650/#651/#656/#655/#658 |
| [#653](https://github.com/JDeun/AgentWearLink/issues/653) KWS | [Pinned audit](third-party-wake-source-audit-2026-11-25.md); Porcupine Korean support, openWakeWord English/model-license limits | CLOSED not planned: #655/#658 comparison; reopen for selected engine/rights/experiment |
| [#654](https://github.com/JDeun/AgentWearLink/issues/654) Voice Bridge | [Pinned audit](third-party-wake-source-audit-2026-11-25.md); bounded HFP reference, no persistent default/import | CLOSED completed static decision; residuals #646/#656/#655/#658 |
| [#655](https://github.com/JDeun/AgentWearLink/issues/655) Alfred | [Wake/power](alfred-wake-battery-radio-mitigation-2026-10-31.md), [new audit](third-party-wake-source-audit-2026-11-25.md); official invocation/manual baseline, opt-in bounded host lease | OPEN: accuracy, language, distribution and battery #658; authorized transport |
| [#660](https://github.com/JDeun/AgentWearLink/issues/660) BLE | [Lab](../../Tools/L2CAPLab/README.md), [Visor LE audit](visor-ios-le-transport-feasibility-2026-11-24.md); #691–#697 research software | OPEN: framed app binding and separate analyzer; physical B0, B1 target authorization/coexistence; generic stack not Meta proof |
| [#661](https://github.com/JDeun/AgentWearLink/issues/661) firmware/DSP | [New audit](third-party-wake-source-audit-2026-11-25.md); abstract not proof of DSP path | OPEN: lawful public technical evidence; no bypass/modification |
| [#663](https://github.com/JDeun/AgentWearLink/issues/663) independent companion | [Visor LE](visor-ios-le-transport-feasibility-2026-11-24.md), [Linux comparison](third-party-wake-source-audit-2026-11-25.md); AGPL/authorization boundary | OPEN: authorized session ownership/coexistence, firmware and legal conditions |
| [#664](https://github.com/JDeun/AgentWearLink/issues/664) false-ready | [November audit](meta-dat-visor-companion-followup-2026-11-24.md); #686 separates SDK readiness/callback health | OPEN: missing/late ACK/disconnect/re-registration regression, actual power #644/#651/#655/#658 |
| [#665](https://github.com/JDeun/AgentWearLink/issues/665) custom enrollment | [November audit](meta-dat-visor-companion-followup-2026-11-24.md); en_US constraint, Korean unverified | OPEN: authorized transport/session then attempt fencing, enrollment/rollback and physical language/power proof |
| [#666](https://github.com/JDeun/AgentWearLink/issues/666) Gateway Voice Wake | [Pinned decision](third-party-wake-source-audit-2026-11-25.md); not adopted, Gateway-global != glasses wake | CLOSED completed decision; #56/#97 deployment; reopen if workflow needs new RPC |
| [#670](https://github.com/JDeun/AgentWearLink/issues/670) OSAIG ABI/provenance | issue has actual pinned ARM32 ABI/archive/dependency evidence; root license not redistribution clearance | OPEN: device/firmware/toolchain and per-component grants, reproducible deploy |
| [#669](https://github.com/JDeun/AgentWearLink/issues/669) OSAIG integration | independent fake bridge GO, physical/SDK conditional | OPEN: #671/#672/#673 then #674/#675; #676 after snapshot/security |
| [#642](https://github.com/JDeun/AgentWearLink/issues/642) Apple Watch | [Feasibility](apple-watch-adapter-feasibility-2026-10-31.md); second adapter PoC, not always-on | Implementation #642, typed capability/action #633/#636, security #637 |

## Delivery and empirical tracks

- Product: #644 SDK/registration, #651 Speech, #656 HFP lease, #657 power, #635 streaming, #638 fault injection, #637 security.
- PoCs: #633 actions, #634 realtime voice, #636 capability negotiation, #642 Watch, #671–#676 OSAIG after provenance/ownership gates.
- Physical/deployment: #1/#3/#5/#6/#56/#58/#59/#97/#98/#117/#118/#303/#646/#650/#658. Historical smoke is not current full acceptance. [Runbook](companion-physical-acceptance.md).
- #697 [exact-head CI](https://github.com/JDeun/AgentWearLink/actions/runs/45577180835) and [main CI](https://github.com/JDeun/AgentWearLink/actions/runs/45577386214): bounded message session software, 55 Swift tests per OS, 13 report tests, builds. No physical B0 or proprietary transport proof.

Prioritize concrete unresolved evidence before expanding experiments. Stop source-only research when decision/owner/next evidence are explicit, but retain incomplete audit and test work. Never close #660/#655 or physical gates on mocks alone.
