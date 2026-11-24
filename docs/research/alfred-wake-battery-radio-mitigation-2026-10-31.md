# Alfred wake battery and radio power: research and mitigation plan (2026-10-31)

## Executive finding
Small wake-word model inference is not equivalent to low-power wake on the glasses. The primary unresolved cost is keeping the **glasses microphone transport** active via Bluetooth HFP/SCO and competing with A2DP and DAT camera media. No public DAT API for registering a custom keyword on the glasses low-power wake engine is verified. Distinguish measured evidence, third-party reports and estimates.

## Source evidence
- Meta DAT iOS Discussion #250: https://github.com/facebook/meta-wearables-dat-ios/discussions/250 . Developer reports continuous HFP PCM via AVAudioSession/AVAudioEngine, ~8 kHz mono, camera quality degradation and A2DP music contention. Claims of ~24 to 8 fps are field reports, not AWL benchmark. Some users report wake phrase detection via HFP.
- Meta DAT iOS #260: https://github.com/facebook/meta-wearables-dat-ios/issues/260 . HFP audio active during camera stream can cause photo capture callbacks to stall; disabling HFP restores behavior in reporter's setup.
- Meta DAT Android Discussion #130: https://github.com/facebook/meta-wearables-dat-android/discussions/130 . Meta states some firmware versions end camera session on HFP microphone activation, advises keeping HFP closed during DAT until glasses firmware fix; experimental camera-stream PCM is development/beta only and not publishable.
- Meta DAT iOS CHANGELOG 1.0.0: https://github.com/facebook/meta-wearables-dat-ios/blob/main/CHANGELOG.md . DeviceState now has batteryLevel, chargingState, thermalLevel; StreamError includes batteryLow, thermalHot, peakPowerLimit.
- Existing AWL upstream #343: single-run reported glasses 94%→79% over 18 minutes continuous Speech+Inputs+DeviceSession (~50 percentage points/hour extrapolation; not statistically reliable).

## Candidate mitigation ranking
1. **Bounded listening lease**: explicit user trigger starts HFP/KWS for a time-limited window, tear down on timeout/cancel/done. Lowest engineering risk, but not true always-on Alfred. Track #656.
2. **Adaptive power governor**: respect battery/charging/thermal and capability errors, shed continuous camera/Speech/HFP, hysteresis and user-visible state. Track #657.
3. **Event-first architecture**: no persistent microphone, rely on gesture/manual trigger or supported voice invocation; minimizes idle radio cost but cannot independently recognize '알프레드'.
4. **KWS on iPhone**: optimize CPU with VAD, frame gating and Core ML/ONNX, but HFP must stay active for continuous Alfred detection. Treat as phone CPU optimization, NOT proof of glasses battery savings.
5. **Vendor DSP custom wake API**: monitor upstream #343; not currently public, cannot promise delivery.
6. **Experimental DAT camera-associated PCM**: camera LED/privacy, battery and publication restrictions make it unsuitable as default production always-on wake.

## Benchmark design
- Fixed glasses model/firmware, Meta AI, phone/iOS, SDK SHA, audio routes, radio conditions, music/camera state; >=3 runs per scenario.
- Cases: idle; DAT connected idle; Speech; Inputs; HFP mic; HFP+KWS; HFP+DAT camera; A2DP music; bounded listening; event/manual wake.
- Record glasses and phone battery deltas, thermal, disconnects, wake FAR/hour, FRR, p50/p95 latency, radio provenance, music interruption, DAT session failures. Percentages are coarse; no fabricated watt-hours or battery lifetime.
- Battery duty-cycle approximation: P_avg = P_idle*(1-d) + P_listen*d + P_inference. Not valid if transport connection/reconnection costs dominate; measure them.
- Keep true always-on Alfred as a research target; do not claim that finite leases satisfy the exact UX requirement.

## Decision and ownership
- #656 HFP lease and release.
- #657 battery/thermal adaptive governor.
- #658 physical power benchmarks.
- #655 wake architecture comparison, #654 HFP upstream audit, #648 official low-power wake tracking.
- Do not ship continuous HFP as default before physical measurements; do not infer battery improvement from smaller KWS models alone.

Status: research and tracking only. No device battery measurements or production code modifications performed.
