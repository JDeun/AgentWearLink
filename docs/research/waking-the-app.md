# Waking the app

**How the companion app comes back after iOS suspends or evicts it, without the wearer touching the phone.**

[Research notes](README.md) · [Background and locked phone](background-and-locked-phone.md) · [Glasses battery](glasses-battery.md)

## Summary

A silent-audio keep-alive keeps the app running while the glasses are around. With no glasses, it only drains the phone, so it stops after 5 minutes and iOS suspends the app. The way back is a **pending Core Bluetooth connection** to the glasses. iOS holds that request while the app is suspended, then wakes the app, or relaunches it after eviction, when the glasses return. A Shortcuts automation that runs a background App Intent covers the case Bluetooth cannot cover: a force quit. "Hey Meta, start <app>" is the voice fallback.

```mermaid
flowchart LR
    Away["Glasses folded or cased"] --> Disc["didDisconnect: re-arm the connect request"]
    Disc --> Grace["Keep-alive stops after 5 min"]
    Grace --> Susp["App suspended, request pending"]
    Susp --> Back["Glasses unfolded"]
    Back --> Wake["didConnect wakes or relaunches the app"]
    Wake --> Resume["Keep-alive, DAT session, Speech"]
```

## What does not wake the app

| Channel | Finding | Label |
| --- | --- | --- |
| External Accessory connect | "If your app is suspended in the background when an accessory notification arrives, that notification is put in a queue." A connect followed by a disconnect while suspended is never seen at all. The connect is queued, not a wake. | Verified: Apple, [Monitoring Accessory-Related Events](https://developer.apple.com/library/archive/featuredarticles/ExternalAccessoryPT/Articles/MonitoringEvents.html) |
| An App Intent with `openAppWhenRun = true` on a locked phone | The phone asks for an unlock first, because the app is brought to the foreground. | Reported: Apple Developer Forums [732466](https://developer.apple.com/forums/thread/732466), [714313](https://developer.apple.com/forums/thread/714313) |
| Audio route change notifications | Delivered only to a running app. | Unverified (notifications are not wake sources) |
| Silent push, background refresh | Push is throttled and never reaches a force-quit app. Refresh is opportunistic. Neither is tied to the glasses. | Verified: Apple background execution docs |
| Meta's own background guidance | It keeps the app alive with an active audio session and says nothing about waking or relaunching a suspended app. | Verified: Meta Developer Advocate, [dat-ios discussion #142](https://github.com/facebook/meta-wearables-dat-ios/discussions/142) |
| Field reports | No issue or discussion on either DAT repository reports an app woken by the glasses reconnecting. | Verified (absence): issues and discussions on both repositories, October 2026 |

## The pending-connect design (implemented)

| Step | Detail | Label |
| --- | --- | --- |
| Find the glasses | The app's own `CBCentralManager` calls `retrieveConnectedPeripherals(withServices:)` with the 16-bit service UUID `0xFD5F`, which the Bluetooth SIG assigns to Meta Platforms Technologies, LLC. This works while the glasses are linked by the Meta AI app or a DAT session. | Verified: [Bluetooth SIG member UUIDs](https://bitbucket.org/bluetooth-SIG/public/raw/main/assigned_numbers/uuids/member_uuids.yaml); Apple: the call returns peripherals "connected to the system (for instance, by another app)", [Best Practices](https://developer.apple.com/Library/ios/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html) |
| Remember them | The peripheral identifier is saved. Later, `retrievePeripherals(withIdentifiers:)` returns the peripheral without a connection. Whether the identifier stays stable over months is untested. | Unverified (stability) |
| Hold the request | `connect(_:options:)` "don't time out". The app keeps a strong reference, because deallocating the peripheral cancels the request. It re-arms the request right after each `didDisconnect` or `didFailToConnect`. | Verified: Apple, [`connect(_:options:)`](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect(_:options:)) |
| Be woken | With `bluetooth-central`, "the system wakes up your app when any of the CBCentralManagerDelegate … methods are invoked". The app then has about 10 s. | Verified: [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html) |
| Be relaunched | The manager has its own restore identifier, distinct from any other manager in the process, because reusing one breaks restoration. An app delegate creates the manager at launch, not a SwiftUI view, so a background relaunch with no scene still receives `willRestoreState` and the pending `didConnect`. | Verified: Apple, "Adding Support for State Preservation and Restoration" (same guide) |
| Stay passive | The app never discovers services or exchanges data. Core Bluetooth shares one LE link between apps, so the request adds a reference and opens no second link. Holding it may keep the LE link up while the glasses are unfolded and idle. | Unverified (glasses battery effect to measure) |
| Keep-alive | The silent keep-alive runs while a session is live, the glasses are linked or the app is in front, then stops 5 minutes after the glasses were last seen. A Bluetooth wake restarts it (mixable `.playback`) before the DAT session. | Design decision |

**Precedent.** LoopFollow, an open-source iOS app, holds a pending connect to a device that another vendor's app owns (a CGM transmitter or a pump) and offers it as the lower-battery alternative to a "silent tune" keep-alive (Verified: [LoopFollow](https://github.com/loopandlearn/LoopFollow) `BackgroundRefresh/`). A WHOOP client added a standing connect after finding that timers do not run while suspended (Reported: [noop #1413](https://github.com/ryanbr/noop/issues/1413)).

**Background audio after a wake.** Apple documents `cannotInterruptOthers` for activating a **non-mixable** session in the background, so a mixable playback session is not documented as forbidden (Verified: [AVAudioSession.ErrorCode](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode); Apple Engineer, [forums 755784](https://developer.apple.com/forums/thread/755784)). One DAT developer saw playback refused (`'!pla'`) after a Bluetooth wake unless the silent player had run since launch (Reported: [dat-ios discussion #326](https://github.com/facebook/meta-wearables-dat-ios/discussions/326)). The two conflict; the hardware test decides.

## Relaunch rules (TN3115)

Relaunch happens "if and only if it's waiting for a specific Bluetooth event or action (like scanning, connecting …) and the corresponding Bluetooth event has occurred."

| App state when the glasses return | Woken or relaunched? |
| --- | --- |
| Suspended in memory | Activated without a relaunch |
| Removed from memory by the system | Yes |
| Crashed | Yes |
| Force quit by the user | No (note 5) |
| Bluetooth turned off in Settings | No |
| Bluetooth toggled in Control Center | Yes (note 5) |
| Airplane Mode toggled | Yes (note 5) |
| Phone restarted | Yes, after the first unlock |

Verified: Apple, [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) (revision 2025-09-15).

Note 5 reads: "Starting in iOS 26 and iPadOS 26, only apps that use AccessorySetupKit to setup Bluetooth accessories will be relaunched." It applies only to the rows that cite it. An Apple engineer explained that iOS 26 **adds** relaunch after a force quit for apps that opt in to AccessorySetupKit (ASK); it does not remove relaunch after eviction for other apps (Verified: [forums 806013](https://developer.apple.com/forums/thread/806013)). ASK relaunch after a force quit is still reported as unreliable on 26.x (Reported: Apple Developer Forums).

**Why the app does not adopt ASK.** "If ASK is involved CBCentralManager will only work with accessories discovered that way", for the whole process, which would include the DAT SDK's own Bluetooth use (Verified: Apple Engineer, [forums 811101](https://developer.apple.com/forums/thread/811101)). ASK would only add the force-quit and Control Center cases, at the risk of the glasses link. If tried at all, it is a separate experiment on a branch.

## Fallbacks

| Path | Detail | Label |
| --- | --- | --- |
| Shortcuts automation | Personal automation "Bluetooth: when Ray-Ban Meta connects", set to Run Immediately, runs the app's Start Listening intent. On iOS 26 the intent declares `supportedModes = .background` and `authenticationPolicy = .alwaysAllowed`, so it runs while locked without bringing the app forward. An intent run starts the app process, so this also works after a force quit. It needs a one-time setup by the wearer. | Verified: [Shortcuts guide](https://support.apple.com/guide/shortcuts/apde31e9638b/ios), [supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes). Unverified: locked run on hardware |
| "Hey Meta, start <app>" | "If your app is not already running, the command cold-launches it." It is a voice action, not zero action, and in practice needed a Beta release channel; in Developer Mode the stream opened but `LaunchApp` never arrived. | Verified: [Wearables developer docs](https://wearables.developer.meta.com/docs/develop/dat/), voice invocations. Reported: dat-ios discussion #326 |
| Opening the app | Always works. | |

Both automatic paths may fire at once, so starting is idempotent.

## Open questions

- Does the wake happen on hardware, and how long after unfolding?
- Does playback start after a Bluetooth wake (`'!pla'` or `cannotInterruptOthers`)?
- Does holding the LE request change glasses battery while they sit unfolded and idle?
- Glasses left unfolded and connected but not worn produce no Bluetooth event when put on. The fold and unfold cycle is the trigger.

## Hardware test

Phone locked throughout, power log on, development build.

1. **Precondition.** Open the app once with the glasses linked. The log shows the pair found and the request held. Meta AI and a DAT session still work.
2. **Suspended.** Start listening, fold the glasses into the case, wait past the 5-minute grace and at least an hour more. Unfold. Pass if, within 30 s and without touching the phone, the app logs the link, playback starts, the DAT session reaches `.started` and Speech transcribes a test phrase.
3. **Evicted.** As step 2, but push the app out of memory after folding. Pass if the app is relaunched with its restore identifier and continues as in step 2.
4. **Restart.** Restart the phone, unlock once, lock, unfold. Expect the same as step 3.
5. **Force quit.** Swipe the app away, then unfold. Expect no Bluetooth relaunch. With the Shortcuts automation installed, expect the intent to run and the session to start.
6. **Side effects.** Two hours with the glasses cased (phone battery, anchor on and off) and two hours unfolded and idle (glasses battery, anchor on and off). Twenty fold and unfold cycles with no "Session ended by device" loop ([dat-ios #231](https://github.com/facebook/meta-wearables-dat-ios/issues/231)).
