# Foreground BLE discovery research probe

Refs #660, #665, #655, #663, #658. See [Visor v3.1.0 audit](../../docs/research/visor-ios-le-transport-feasibility-2026-11-24.md). This standalone local developer tool is **not** a second shipped Companion app and is not linked into the production runtime, Meta DAT or OpenClaw.

## Scope and stop conditions

Gate A only: on the owner's physical iPhone, an explicitly entered, documented/authorized 16-, 32- or 128-bit service UUID is required. No default guessed service, broad scan, scan by name/RSSI, or automatic device selection. The user explicitly starts a bounded 15-second foreground run (including Bluetooth initialization); the app checks the OS's system-connected snapshot and requests filtered advertisement discovery with duplicate delivery disabled. These are Apple public CoreBluetooth observations, not raw RF sniffing. The list is capped at 16 ephemeral candidates; a capacity overflow, user cancellation, Bluetooth loss, non-active scene, or permission failure stops and discards candidates. No automatic retry/resume, state restoration or background entitlement.

The tool retains only transient local label hints and per-run opaque identifier keys for deduplication. It discards identifier keys when the run ends, clears all local hints on leaving the active scene, and exposes only categorical report text with no names, UUIDs, RSSI, raw service/manufacturer bytes, logs, credentials, payloads or network uploads. Explicitly confirm only an independently identified owned device; identical names, a service match or nearby RSSI are not identity. Do not copy candidate labels or screenshots. If identity or ownership is ambiguous, record inconclusive and stop.

No local peripheral connection, service/characteristic exploration, attribute reads/writes, subscriptions, pairing/bond changes, L2CAP channel, proprietary handshake, device commands, wake enrollment, microphone, firmware mutation or agent invocation. A system-connected result can be another app's connection, not an AWL-owned link. A connectable flag or advertised UUID is not a reachable GATT attribute or an authorized channel. No result is inconclusive (filters, firmware, OS caches and advertising intervals matter). Apple: [central manager](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager), [advertisement keys](https://developer.apple.com/documentation/corebluetooth/advertisement-data-retrieval-keys).

## Build and validate

From the repository root on a Mac with Xcode and the existing pinned XcodeGen installer:

```sh
swift test --package-path Tools/BLEDiscovery
python3 Tools/BLEDiscovery/check_read_only.py
bash scripts/install-xcodegen.sh
cd Tools/BLEDiscovery
xcodegen generate
xcodebuild -project BLEDiscovery.xcodeproj -scheme BLEDiscovery -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For physical evidence, open the generated project, select your own development signing team and install on your iPhone. Use an independently identified, personally owned test accessory and its documented, authorized service UUID as a positive control before trying the owned glasses. Leave the official Meta companion and existing pairing unchanged; no channel/credential probing. Start only while the app is active; if the first OS permission prompt interrupts the run, return to the app, re-enter the filter and explicitly start again. Test denied permission, Bluetooth off, no match, duplicate matches, cancel and background/lock (clear/stop; no auto restart). Record iOS/app commit, test condition, firmware version if known, and only the sanitized report. Do not enter a guessed proprietary service or identifier. If no authorized service is available, record blocked rather than expanding the scan.

## Interpretation and next gate

- Positive control visibility establishes only that iOS discovery works in that setup.
- A confirmed glasses observation establishes only the observed advertisement or system-connected service match at that moment.
- No authorized service or ambiguous identity: Gate A remains blocked/inconclusive.
- No local GATT, PSM, L2CAP, companion authorization, event delivery, lock-screen wake, Korean Alfred, or battery claim. Gate B requires a manufacturer-supported or otherwise explicitly authorized transport and separate review. Do not extend this tool to open a channel or change ownership.

Policy tests cover validation, run fencing, deduplication, caps, consent/identity confirmation and report privacy. CI builds the simulator app and checks the static API boundary. Neither proves actual device visibility, OS authorization behavior, physical teardown, or low-power wake feasibility.
