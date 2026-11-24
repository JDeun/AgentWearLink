# Visor original source discovery and Alfred low-power wake implications (2026-10-31)

## Primary source located
https://github.com/macedonga/visor — independent Android Meta glasses companion (AGPL-3.0). README states it can replace Meta AI app, use authenticated Meta account/ownership provisioning, speak glasses RFCOMM and Wi-Fi Direct protocols, and route **existing 'Hey Meta'** assistant requests to Claude/OpenAI-compatible endpoints. This is a much stronger primary source than the previously cited third-party Visor overview, but **does not implement registering '알프레드' into the glasses' low-power detector**.

### Relevant code ownership
- `core/protocol`: wire frames, ciphers, handshake
- `core/transport`: RFCOMM transport and wire logs
- `core/session`: multiplexed link, reconnect
- `core/identity`: account, owner provisioning, key storage
- `core/connection`: device battery/state
- `core/assistant`: assistant request routing
- `app`: lifecycle and Android UI
These are README-defined modules, not yet source-level traced. Audit actual classes and data paths before proposing reuse.

## Comparison
https://github.com/MoTechnocious/rayban-meta-linux describes server-side account/device ownership as the hard boundary for *no-Meta-software, offline* independent pairing. Visor's README says it uses Meta login and server ownership receipts, so the two claims are compatible in principle. Visor warns one owner session at a time and build signing keys cannot be mixed.

Visor source README requires separate Meta client tokens for self-built owner enrollment, and the released application contains its own signing context. Do not copy/extract/distribute app credentials. This is not a supported Meta DAT integration and carries maintenance/terms risk.

https://github.com/lingster/meta-rayban-bluetooth offers GATT probing but labels proprietary voice-assistant UUID as TBD. It does not prove a BLE wake notification or DSP wake replacement.

https://nullcon.net/talk/beeps-and-patches-arbitrary-code-execution-on-meta-ray-ban/ conference abstract claims OTA firmware extraction and unprivileged code execution. It does not prove privileged DSP model modification, battery gains, or safe production deployment.

## Distinct wake modes
1. 'Hey Meta' DSP triggers Visor assistant routing: plausibly low-power idle, but user still says 'Hey Meta'; transport and idle power not measured here.
2. Phone-side '알프레드' KWS via continuous HFP: meets custom phrase, potentially high radio energy.
3. Hardware '알프레드' DSP keyword: target unmet by any verified public project.
4. Gesture or bounded HFP lease: lower standby cost, not hands-free custom phrase.

## Newly identified source-audit issue
#663 original Visor source, voice event path, energy, AGPL, iOS feasibility.
Existing #659 companion protocols, #660 GATT, #661 firmware, #655 wake architecture, #658 energy benchmark.

## Next falsifiable questions
- Does Visor receive a post-Hey-Meta recognized utterance as text or via on-demand audio? How does it know wake happened without HFP?
- What state is the glasses radio in before and after 'Hey Meta'? What are current/battery deltas?
- Can an iOS application access equivalent RFCOMM service under public platform entitlements? Likely constrained; verify rather than assert.
- Can the wake phrase itself be changed without privileged DSP model changes? No verified evidence.

Status: primary-source identification, architectural triage and issue registration; no full code trace, binary analysis or physical battery measurement.
