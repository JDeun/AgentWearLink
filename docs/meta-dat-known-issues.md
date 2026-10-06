# Meta DAT 1.0 integration risks

This file tracks upstream behavior that affects AgentWearLink design decisions.

## Camera memory growth

An open Meta DAT iOS 1.0 report describes camera streaming heap growth at the stream data rate without release.

AWL mitigation:

- do not keep camera streaming active continuously,
- prefer explicit/event-driven capture,
- bound any AWL-owned media queue,
- release frame references immediately after processing,
- make repeated long-duration soak testing a P2 release gate.

## Audio playback interruption

An upstream report describes camera streaming pausing A2DP playback without reliably resuming it after the stream ends.

AWL mitigation:

- treat camera and TTS/audio output as competing resources until validated,
- stop camera work before response playback when practical,
- test Ray-Ban audio route state before/after every capture flow.

## Session/stream availability

Previous SDK versions have reports of sessions stopping before `.started` and streams remaining in `waitingForDevice`.

AWL mitigation:

- distinguish DeviceSession readiness from Camera Stream readiness,
- never call camera capability APIs before DeviceSession reaches `.started`,
- surface typed adapter diagnostics rather than auto-retrying forever,
- never silently replay agent actions during reconnect.

## Experimental 1.0 APIs

Speech, voice invocation, inputs, motion, camera audio streaming and some camera capture functionality are experimental in DAT 1.0 and may not be publishable yet.

AWL treats them as negotiated optional capabilities rather than guaranteed device features.
