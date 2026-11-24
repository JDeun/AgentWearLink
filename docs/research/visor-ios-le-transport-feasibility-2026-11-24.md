# Visor v3.1.0: iOS custom wake transport feasibility

Reviewed 2026-11-24. This is a static source/API audit, not a glasses test, protocol implementation, or authorization to replace the Meta companion.

## Decision update (#655 / #665)

**Android reference: viable for separately consented hardware investigation. iOS production: no-go until supported transport, ownership and runtime wake evidence. iOS BLE research: conditional go for a read-only discovery experiment on the owner's device.** Keep official DAT Speech/Voice Invocation and the bounded foreground HFP experiment (#688) as separate paths. Do not add a fake hardware wake capability.

### Important correction: RFCOMM is not the only Visor transport

[Visor v3.1.0](https://github.com/macedonga/visor/releases/tag/v3.1.0), exact source commit `303b68035e013b0804f06914f6416c88cb8cc875`:

- [AndroidTransportFactory](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/app/src/main/kotlin/com/macedonga/visor/connection/AndroidTransportFactory.kt) creates a LE-first transport with RFCOMM fallback, and a distinct TCP Wi-Fi path.
- [BluetoothLeTransport](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/transport/src/main/kotlin/com/macedonga/visor/core/transport/BluetoothLeTransport.kt) maintains a bonded LE link, obtains the L2CAP service multiplexer from its configured/advertised metadata and opens an Android L2CAP byte stream; it falls back to GATT discovery when necessary. This is not merely a GATT characteristic write.
- [BluetoothRfcommTransport](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/transport/src/main/kotlin/com/macedonga/visor/core/transport/BluetoothRfcommTransport.kt) uses Android BluetoothSocket RFCOMM APIs.
- [SecureLink](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/session/src/main/kotlin/com/macedonga/visor/core/session/SecureLink.kt) adds a session-level encrypted handshake and framed transport; the upper assistant protocol is not equivalent to a socket connection.
- [CustomWakeWord](https://github.com/macedonga/visor/blob/303b68035e013b0804f06914f6416c88cb8cc875/core/assistant/src/main/kotlin/com/macedonga/visor/core/assistant/CustomWakeWord.kt) operates above that established assistant/session path. See the earlier [locale and enrollment audit](meta-dat-visor-companion-followup-2026-11-24.md). The existence of a byte transport does not establish enrollment authorization, runtime assistant ownership, locale support, or actual firmware persistence.

### Public iOS APIs

Apple's [CBPeripheral.openL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:)) and [CBL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbl2capchannel) establish that the generic L2CAP primitive exists on iOS. They do not authorize a particular proprietary Meta service. Core Bluetooth's [BR/EDR discussion](https://developer.apple.com/videos/play/wwdc2019/901/) describes GATT over Classic, not an Android-equivalent arbitrary RFCOMM socket. [External Accessory](https://developer.apple.com/documentation/externalaccessory/) requires an accessory-supported/manufacturer-authorized protocol; [protocolStrings](https://developer.apple.com/documentation/externalaccessory/eaaccessory/protocolstrings) is the supported discovery boundary. No documented Meta-authorized EA protocol for AWL has been established. Do not add a guessed Info.plist protocol or credential.

The pinned DAT 1.1.0 [public SDK](https://github.com/meta/meta-wearables-dat-ios/tree/2c772e03e6a2e74282ac6564c2424acf6e58d8f0) Core/Speech Swift interfaces were rechecked: VoiceInvocation / LaunchApp and transcription/state/error/locale publishers are present; no public custom enrollment/keyword/raw companion transport API was found in those interfaces. [Meta discussion #343](https://github.com/meta/meta-wearables-dat-ios/discussions/343) acknowledges feature requests, not a delivered low-power keyword API. Thus BLE L2CAP changes the research feasibility assessment, not the supported DAT contract.

## Gates before any prototype that changes the device

| Gate | Pass evidence | Failure disposition |
| --- | --- | --- |
| A: Existing device discovery | Owner explicitly starts a foreground diagnostic on their own glasses; known device is unambiguously identified; OS Bluetooth permission and public service visibility recorded without identifiers | Stop; do not scan indefinitely, select by RSSI, or guess identity |
| B: Transport availability | Manufacturer-supported or explicitly authorized service/channel, with approved ownership/compatibility boundaries and no pairing change | Stop; public iOS L2CAP existence is not permission or proof of Meta access |
| C: Companion/session interoperability | Independent authorized reference session; documented coexistence/rollback; do not reuse Meta client secrets, impersonate official app, or transfer ownership silently | No iOS integration |
| D: Enrollment | Three consented samples, verified firmware/locale, attempt correlation, confirmed result and rollback to native wake; no samples/transcripts persisted | Do not advertise a registered wake capability |
| E: Wake and battery | English Alfred in supported en_US first; distinguish device-generated wake vs phone-side recognition; idle audio routes and HFP released; lock screen/A2DP/turn delivery, false accepts and rejects, power per #658 | Keep disabled; no Korean or low-power claim |

A read-only foreground discovery can report categorical availability and time limits, without opening a proprietary channel, writing characteristic values, changing pairing, or changing firmware wake settings. It must not be added to a normal startup flow. The existing AWL wake anchor is not proof of the correct companion service or session identity.

## License and product boundaries

Visor is AGPL-3.0; AWL is Apache-2.0. No source is copied, linked or reimplemented from private companion enrollment messages here. Independently design test evidence and supported-interface boundaries; separately assess licensing and authorization before any transport integration. Android source-level behavior and firmware claims do not establish App Store publishability, Korean recognition or measured savings. Do not implement a custom enrollment API or change Gateway-global Voice Wake settings in production based on this audit.

## Follow-up

Update #665 and #655 to distinguish BLE feasibility from RFCOMM limitations. #663 owns independent companion transport risks, #664 owns false readiness, #656/#688 owns bounded HFP, #658 owns measurement. Keep all physical gates open.
