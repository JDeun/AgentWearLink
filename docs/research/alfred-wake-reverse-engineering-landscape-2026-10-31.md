# Alfred low-power wake: independent companion and reverse-engineering research (2026-10-31)

## Objective
Assess whether a custom spoken '알프레드' can wake AgentWearLink with low glasses power without persistent HFP or DAT Speech. Keep three claims separate: (A) rerouting existing 'Hey Meta' to another agent, (B) recognizing custom phrase on a phone with active microphone transport, (C) changing on-glasses low-power detector. Only (C) fully meets target without 'Hey Meta'.

## New public cases and confidence
1. **MoTechnocious/rayban-meta-linux** https://github.com/MoTechnocious/rayban-meta-linux — first-party project README claims Linux A2DP/HFP pairing, RFCOMM vendor control channels, authenticated ECDH/AES-GCM/protobuf, Noise transport and Meta server-bound account/device attestation. Source report, not independently reproduced; shows access != authorized companion enrollment. No custom DSP wake shown.
2. **lingster/meta-rayban-bluetooth** https://github.com/lingster/meta-rayban-bluetooth — scanner, GATT enumerator, monitor and packet analyzer. README's voice assistant and camera UUIDs are marked TBD, NOT discovered interfaces. Potential for lawful passive observations; no custom wake implementation.
3. **Visor independent Android companion** https://awesomerea.org/resources/visor-ray-ban-meta-client-case/ — third-party secondary summary reports Meta companion replacement, 'Hey Meta' requests sent to user's chosen LLM, Gen2 firmware-specific constraints. Must locate primary repository and independently verify. Does not demonstrate '알프레드' DSP registration.
4. **Paula, 'Beeps and Patches: arbitrary code execution on Meta Ray-Ban'** https://nullcon.net/talk/beeps-and-patches-arbitrary-code-execution-on-meta-ray-ban/ — conference abstract claims OTA firmware extraction, bypassed signing checks, unsigned unprivileged app and shell. Abstract-level claim only; even verified unprivileged execution does not imply access to privileged DSP wake models. Not suitable as production dependency.
5. **Android DAT HFP silence regression** https://github.com/facebook/meta-wearables-dat-android/issues/196 — reporter initially documented all-zero HFP/SCO audio during DAT camera; subsequent retest says speech recovered with multiple simultaneous changes (SDK 0.7.0→1.0.1, Meta AI and glasses DWA runtime), causality unknown. Requires renewed physical testing; prior blanket claims of permanent incompatibility are too strong.
6. **Hebrew assistant transport problem** https://github.com/facebook/meta-wearables-dat-android/issues/141 — developer reports 8kHz HFP degrades wake-word phoneme recognition and requires fuzzy matching; a language-specific caution for Korean '알프레드', not battery fix.

## Power analysis
- Replacing a phone KWS model does not eliminate glasses microphone radio cost; HFP/SCO continuous capture must be measured separately.
- Passive BLE notifications or RFCOMM wake signals might be low duty cycle, but no verified signal carries *custom phrase* recognition. Receiving a wake event from 'Hey Meta' still violates product UX requirement.
- Firmware research could theoretically uncover internal wake architecture but risks signed firmware, device integrity, Meta services, privacy indicators, and firmware update stability. Keep a non-invasive research-only boundary.
- Official low-power API remains the preferred maintainable production solution if Meta exposes it.

## Tracked follow-ups
- #659 independent companion/Visor and RFCOMM attestation
- #660 BLE/GATT event observation and iOS feasibility
- #661 firmware DSP/signing boundary and go/no-go
- #662 HFP+camera silence regression retest
- Existing #648 low-power wake API, #655 decision matrix, #658 power benchmarks, #654 HFP source audit

## Evidence gates
Require primary-source pinned commits, exact firmware/SDK versions, lawful owned-device validation, microphone provenance, iOS background constraints, false accept/miss rates, measured glasses and phone battery and license review. No claim of implemented custom hardware wake or battery improvement without physical tests.

Status: public-source reconnaissance and issue registration; no firmware modification, bypass, reverse-engineering lab test, device measurement, or production integration completed.
