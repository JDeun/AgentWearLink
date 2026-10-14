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

## Code-level comparison (2026-10-14)

We read the actual code of every reference that claims to work with the phone locked:

| Reference | Public code | Keep-alive | DAT link while locked |
| --- | --- | --- | --- |
| dashhound (dat-ios #322) | **Yes**, with measured logs (2 min 53 s locked, zero suspensions) | `.playback` + `.mixWithOthers`, default mode; AVAudioEngine source node writing zeros; 3 s watchdog | hvc1 camera stream |
| Lore (dat-ios #326) | No (prose only); only the "microphone from camera audio" part is in a public fork | silent output "from launch" | camera stream with PCM audio |
| Meta background streaming guide (#142) | Guide only; its sample is not public | active session, no-op on background | camera stream |
| BirdSpotter (Meta sample) | Yes | none (session held app-wide) | hvc1 7 fps "spine": "a raw stream would be a session that goes deaf when the phone is locked" |

**No public code shows a Speech-only session surviving a locked phone.** The camera "spine" works but turns the capture LED on and stops music (see [Hands-free alternatives](hands-free-alternatives.md)).

## Rules learned the hard way

| Rule | Label |
| --- | --- |
| Configure the AVAudioSession **once**, before the DAT session. Re-applying `setCategory`/`setActive`/`setPreferredInput` while a session is held made the glasses end it ("Session ended by device") 170–300 ms later, 3 times out of 3. | Reported: [dat-ios #292](https://github.com/facebook/meta-wearables-dat-ios/issues/292) |
| HFP coming up or changing during a session also ended it. HFP that was already stable before `start()` was fine. | Reported: dat-ios #292 |
| Do not tear the session down when the glasses are taken off or folded. After the link dropped (~8 s), every new `start()` was refused with "Device unavailable" until a power-switch cycle. Stop Speech instead and keep the session. | Reported: dat-ios #292 |
| iOS won't **start** recording (`'what'`) or playback (`'!pla'`) from the background. Start the keep-alive in the foreground and never stop it. | Reported: dat-ios discussion #326 |
| While the glasses consider a call active (including CallKit, FaceTime and WhatsApp), firmware 129 ends DAT sessions and declines new ones. Don't retry in a quick loop; recover when the call ends. | Verified: Meta staff, dat-ios #332 |
| A single tap pauses a session, and only a second single tap resumes it. | Verified: Meta staff, dat-ios #312 |
| On iOS 27.0.1, opening Notification Center paused `.playback` and suspended the app ~5 s later (AVPlayer + Picture-in-Picture report; relevance to audio-only keep-alive unverified). | Reported: Apple Developer Forums thread 838683 |
| App Store distribution is not possible for DAT apps today, so silent-audio review risk is moot for development-signed builds. | Verified: Wearables docs |
