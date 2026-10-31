# Apple Watch as a second AgentWearLink adapter — feasibility audit (2026-10-31)

**Decision: feasible as an opt-in watchOS device adapter, subject to hardware validation.** This is a platform/API assessment, not a watchOS build or physical test. No claim of always-on hotword or guaranteed real-time background delivery.

## Proposed topology

**Phase 1 (recommended):** watchOS app (tap/Dictation or short recording, text UI and haptic) -> `WCSession` -> iOS companion -> existing AWL Core runtime/coordinator -> OpenClaw -> iOS companion -> `WCSession` -> watchOS UI. Keep OpenClaw credentials and Tailscale connectivity on the iPhone. Watch-specific transport and output sinks are separate; a watch-originated request is not a Meta DAT transcript.

**Phase 2 (conditional):** independent watchOS networking -> OpenClaw gateway. Requires supported watchOS network and secure credential storage, explicit endpoint trust and reachability handling, foreground/allowed runtime behavior. Do not assume iOS Tailscale route is transparently inherited by the watch.

## Capability honesty

| Feature | Proposed | Caveat |
|---|---|---|
| Button/complication opens app and submits a request | PoC | complication/widget is an entry point, not an unrestricted background executor |
| Typed text/dictation -> agent | PoC | validate OS-provided transcription UI and permission flows on device |
| Recorded voice -> agent | PoC | short bounded audio, user-initiated, permission and audio session; do not advertise always-on raw mic |
| Text reply, haptics | PoC | watchOS view lifecycle, delivery when foreground |
| TTS/watch speaker reply | Conditional | watchOS audio session/route, interruptions, background modes and resource limits |
| Continuous duplex voice | Research | latency, playback/input interference, audio routing, lifetime and battery |
| Always-listening arbitrary hotword with wrist down | Excluded from baseline | watchOS does not provide general unrestricted persistent background microphone execution |
| Camera snapshot | Not supported | Apple Watch has no camera; don't reuse Meta DAT camera capability |
| Offline queue | Optional | `transferUserInfo` asynchronous delivery; do not mislabel as immediate agent turn |

## WatchConnectivity delivery contracts

- `sendMessage` / `sendMessageData`: live messages only when counterpart `isReachable`; delivery errors must be surfaced.
- `transferUserInfo`: queued, ordered background delivery; not a realtime channel. Attach request ID, expiry, and dedupe policy.
- `updateApplicationContext`: latest-state replacement, not an event queue.
- Multi-watch switching: `WCSessionDelegate` activation/deactivation, invalidate stale watch session generations.
- `WKWatchConnectivityRefreshBackgroundTask` must be completed to avoid consuming background task budget.

## AWL implementation boundary

- Create `Adapters/AppleWatch` watchOS-side protocol adapter and iOS-side `WatchConnectivityDeviceAdapter`. The latter can conform to `DeviceAdapter` by yielding normalized `InteractionEvent`.
- Create a separate watch reply transport; existing `InteractionOutputSink` is host-owned and does **not** magically render on the watch.
- Extend device routing only after an actual second adapter test proves the need: current `AgentWearLinkRuntime` binds one device stream and one agent coordinator.
- Explicit `deviceID`, `interactionID`, `sessionGeneration`, request expiry, cancellation/terminal barrier; reject duplicate/stale cross-watch replies.
- Secure defaults: never forward credentials in WCSession messages, no raw transcript persistence, bounded text/audio and opt-in audio permissions.
- No Swift Core rewrite or Muse Noise protocol dependency required.

## Validation matrix

1. iPhone + physical Apple Watch: foreground button -> WCSession -> Core -> OpenClaw -> watch text; inspect IDs and latency.
2. Watch unreachable / iPhone app terminated / phone locked: distinguish delivery unavailable vs queued; never claim realtime.
3. Watch switch/re-pair: no stale results to another watch.
4. Cancellation and repeated taps: one logical agent run and exactly one terminal result.
5. Dictation and microphone permission denial; no silent fallback.
6. Audio route, speaker TTS, wrist-down interruption and background session limits.
7. Cellular/Wi-Fi watch with phone out of range; only attempt independent mode if endpoint and network can actually be reached.
8. Battery and memory measurements, logs with privacy redaction.

## References (Apple official)

- https://developer.apple.com/documentation/watchconnectivity
- https://developer.apple.com/documentation/watchconnectivity/wcsession
- https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity
- https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
- https://developer.apple.com/documentation/watchkit/enabling-background-sessions

## Decision and stop condition

Start with watch -> iPhone relay, not independent watch -> OpenClaw. Watch app is a meaningful second adapter to validate #633/#636. **Static feasibility supported; code and hardware evidence pending.**
