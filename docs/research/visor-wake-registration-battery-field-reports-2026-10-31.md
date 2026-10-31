# Visor field regressions: wake registration and battery (2026-10-31)

## Sources
- https://github.com/macedonga/visor/issues/47 : reporter on Visor 1.4.1/1.4.2, Ray-Ban Meta Gen 3, Samsung Galaxy S25 Ultra Android 16 reports Hey Meta became silent while BT music controls, gallery and notification features still worked. Visor UI continued to report registered/ready. Re-pairing once via official Meta app restored wake. Reporter suspects toggling quick setting but has not reproduced. No causal proof; important false-ready registration risk.
- https://github.com/macedonga/visor/discussions/59 : Oct 29 user asks how to reduce fast battery drain; zero answers at research time. No numeric measurements or attribution.
- https://github.com/macedonga/visor/releases : v1.3.3 notes reply-without-wake and Android companion device background support; potential different audio/listening duty cycle, no measured effect.
- https://github.com/macedonga/visor/blob/main/CLAUDE.md : svc15 ev57 inbound / VARM outbound; does not itself prove audio route or battery characteristics.

## Impact on AWL
A custom companion may preserve glasses DSP 'Hey Meta' trigger, but can silently lose assistant registration and still show link ready. Do not infer wake readiness from Bluetooth connected or registration attempt. Need ack/liveness, explicit recovery and UI differentiation.

Persistent HFP vs on-demand voice transport remains unknown for Visor; battery issue #59 is a report, not a benchmark. A follow-up window without wake may have different power behavior; measure.

## Follow-up
#664 new upstream regression and battery audit; #663 Visor svc15 decoder, #659 companion protocol, #658 battery benchmark, #655 wake source decision. Track upstream #47 and Discussion #59 without assuming fix.

Status: public reports triaged and issue registered; no physical reproduction, firmware intervention or code implementation.
