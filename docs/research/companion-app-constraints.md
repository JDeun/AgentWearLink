# Companion app constraints

**What a user-facing iOS companion app can honestly show and do. Recorded from an adversarial review of the first screen designs.**

[Research notes](README.md)

## Direction

The companion app is a **connection manager**, not a chat client. Conversation history stays in the agent's own channel. The main screen shows the health of the path glasses → phone → network → gateway → agent (`AWLConnectionChain` in Core, #625). Each hop shows when it was last checked, and every hop after the first broken one shows as unknown.

## Claims checked

| Claim | Verdict | What to do instead |
| --- | --- | --- |
| "Say the agent's name to the glasses" (with no running session) | Not possible: DAT only offers "Hey Meta, start {app}" | Use a running session with Speech ([Hands-free speech](hands-free-speech.md)) |
| "We alert you when something breaks, even if the app is closed" | Not possible from the app alone: local notifications need a running process | A gateway-side heartbeat watchdog notifies through the agent's channel |
| Always-on lock-screen card with a live waveform | Not possible: Live Activities are limited to about 8 h active (12 h on screen), have an update budget, and must start in the foreground | Show a Live Activity per turn only, with a static icon |
| Detect, open or auto-discover Tailscale from the app | Not possible: an app can't read another VPN app's state, and tailnet discovery needs an API token | Probe the gateway, list likely causes, guide the user to Tailscale **VPN On Demand**, and pair through a QR code (address + one-time code) |
| Approve a new device from the chat channel | Needs gateway-side work. Taking over the chat account would then mean approval rights | Show a device fingerprint to compare during approval. Until then, approve through the CLI |
| Glasses battery | Possible: `Device.batteryLevel`, `chargingState` | Case battery isn't exposed |
| "Agent ready" | The app can't know | Show "last reply N min ago". Get the agent name from `agent.identity.get` |
| "Test connection" through a real agent turn | Pollutes the chat history and uses quota | Use a health check that doesn't run an agent turn |

## States that need a screen or a recovery path

- **Phone reboot or app killed.** iOS doesn't relaunch the app. Use the watchdog alert plus automatic reconnect on the next launch. Store the device grant with `AfterFirstUnlock`.
- **Glasses state.** In the case or folded, not worn, out of range, battery or thermal critical (`DeviceState`: `hingeState`, `donState`, `linkState`, `thermalLevel`).
- **Firmware or SDK mismatch.** `datAppOnTheGlassesUpdateRequired` (open the update), `insufficientSDKVersion` (needs a rebuilt app).
- **Registration.** Meta AI registration lost or the microphone permission revoked.
- **Gateway access.** Device grant revoked or gateway token rotated. Offer "re-approve this device" separately from "reset everything".
- **Slow or failed agent.** A reply over 30 s, quota exhausted or an agent error: play an earcon and say "check your chat".
- **Interruptions.** Network change mid-turn needs idempotent resubmission. A phone call or music needs the reply queued, and the session ends during calls.
- **Development signing expiry.** Show the expiry date and warn ahead of it.

## Location is a separate channel

AgentWearLink doesn't attach the phone's location to turns. Location-aware agents should get it from their own private channel. For example, [local_context](https://github.com/JDeun/local_context) pushes the phone's location over a private mesh to the agent host, and the agent reads it locally. That keeps the voice path small and avoids a second location permission in the companion app. Its accuracy depends on how often that channel pushes.

## Personalisation without hardcoding

The agent's display name and avatar come from the gateway (`agent.identity.get`, `operator.read`). Per-user values such as the Apple team ID and chat IDs belong in local, uncommitted configuration.
