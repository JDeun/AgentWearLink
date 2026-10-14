# Validation log — October 2026

**Physical bring-up of the reference host. Personal identifiers are redacted.**

[Research notes](README.md) · [P0-B runbook](../p0b-openclaw-validation.md) · [Meta DAT validation](../meta-dat-validation.md)

Setup:
- iPhone 16 Pro on iOS 27.0.1, with Developer Mode enabled
- Ray-Ban Meta glasses, with Meta AI app Developer Mode
- OpenClaw 2026.9.6 on a Mac mini, loopback bind, reached through Tailscale Serve (HTTPS, tailnet only)
- Xcode 27.0, SDK iOS 1.0.0

## 2026-10-13

| Step | Result |
| --- | --- |
| iPhone → Tailnet → Serve → Gateway health | Passed |
| First connect returns pairing required, then operator approval, then `health` ok | Passed |
| Tokenless reconnect using the stored Keychain grant | Passed |
| Meta Developer Mode registration (no App ID or client token) | Passed (`meta-callback-received`); #619 |
| Glasses microphone permission | First found missing: the host never requested it, so Speech was skipped silently. Passed after #621 |
| Spoken question → agent → spoken reply on the glasses | Passed. A Korean question was answered in Korean in a dedicated session |
| Turn into an existing chat session | Context shared; nothing posted to the chat (expected without `deliver`) |
| Reply longer than 30 s over Tailnet | **Failed** with `deadlineExceeded` at t+30 s; fixed in #622, re-test pending |
| `xcodebuild test` driver | Reinstalling the app kills the running host, so long listening sessions need a hold-open test |

## Open hardware checks

- Display name: say "Hey Meta, start/open {home-screen name}" with a speakable name.
- Speech-only session with the phone locked, with and without an audio keep-alive ([Background and locked phone](background-and-locked-phone.md)).
- Korean Speech transcripts on iOS, and how the agent's name is transcribed.
- "Hey Meta …" spoken while the app's Speech is listening.
- Double tap reaching the app as `.select`.
- Reply delivery to the user's chat, and the re-test of turns longer than 30 s.
