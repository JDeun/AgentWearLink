# Background and locked phone

**What keeps a DAT session alive when the app is not in front of the wearer.**

[Research notes](README.md)

## Summary

The declared background modes alone don't keep the app running once the phone locks. Field reports agree that an **active audio session** keeps the process alive. With that in place, sessions have survived several minutes locked. AgentWearLink itself currently retires the session on background by design (#96). The experiments below must turn that off for voice-only sessions.

## Findings

| Finding | Label |
| --- | --- |
| Without a keep-alive, iOS suspends the app about 2 s after locking, and the glasses end the session about 20 s later. A silent-audio loop kept it running (2 min 53 s and 7 min 14 s locked). The author doubts it would pass App Review. | Reported: [dat-ios discussion #322](https://github.com/facebook/meta-wearables-dat-ios/discussions/322) |
| Meta's background streaming guide uses an active `AVAudioSession` (`.playAndRecord`, `.allowBluetoothHFP`, `.mixWithOthers`), does nothing special on background, and declares `audio`, `bluetooth-central`, `bluetooth-peripheral`, `external-accessory` and `processing`. | Verified: Meta Developer Advocate in [dat-ios discussion #142](https://github.com/facebook/meta-wearables-dat-ios/discussions/142) |
| iOS will not *start* recording or playback from the background. Running a silent `.playback` + `.mixWithOthers` player from launch made later replies possible while locked, and "Hey Meta, open {app}" worked with the phone locked. | Reported: [dat-ios discussion #326](https://github.com/facebook/meta-wearables-dat-ios/discussions/326) |
| BirdSpotter declares `audio`, `bluetooth-central`, `bluetooth-peripheral`, `external-accessory` and `fetch`. It keeps the session app-wide "with the phone locked in a pocket" and does not end it on background. | Verified: BirdSpotter `Info.plist`, `AppContainer.swift` |
| Camera streaming continues in the background only with the HEVC codec (`.hvc1`). The default `.raw` codec pauses. Camera Access ends its preview on background. | Verified: CHANGELOG 0.5.0 and 1.0.0, [dat-ios #55](https://github.com/facebook/meta-wearables-dat-ios/issues/55) |
| Whether a **Speech-only** session (no camera) survives a locked phone. | Unverified (key hardware test) |
| Firmware 129 ends DAT sessions during any phone call, including CallKit calls. | Verified: Meta staff, [dat-ios #332](https://github.com/facebook/meta-wearables-dat-ios/issues/332) |
| Folding the glasses disconnects Bluetooth and stops the session. Unfolding does not restart it, so the app must create a new session. Wait at least 2 s before recreating. | Verified: session-lifecycle skill. Reported: dat-ios #231 |
| Do not restart while `.paused`. Wait for `.started` or `.stopped`. | Verified: session-lifecycle skill |

## Distribution note

A keep-alive audio session that plays nothing audible is a known App Store review risk. It does not affect development or beta-channel installs. Experimental DAT capabilities can't ship to production channels yet anyway.

## Hardware test plan

1. Speech-only session, phone locked, no keep-alive: measure the time until the session stops.
2. The same with a silent `.playback` + `.mixWithOthers` keep-alive started at launch. Target at least 30 min, and log Speech stop and restart counts.
3. Stay silent for 5–10 min. Record automatic stops and confirm a restart needs no user action.
4. Fold and unfold, take the glasses off and put them back on, and take a phone call. Check that recovery is automatic.
5. Log `batteryLevel` and `thermalLevel` over one hour.
