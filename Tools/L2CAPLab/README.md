# Gate B0: bounded synthetic LE L2CAP lab

Refs #660, #663, #655. Independent research Swift package, not part of the production Companion, Core or DAT. The [Gate A probe](../BLEDiscovery/README.md) remains read-only. No Meta UUID/PSM, protocol, pairing, account, credentials, device commands, audio or wake integration.

## Current evidence boundary

This package implements a deterministic single-owner link/channel/transfer state machine, a bounded synthetic echo fixture and a Foundation stream wrapper. The duplex test is an in-memory fake transport, not Bluetooth. The memory stream test exercises Foundation I/O, not an actual CBL2CAPChannel. Separate developer apps bind the policy to public CoreBluetooth and Foundation on iOS/macOS. CI builds the two apps and exercises pure policy; no physical evidence, signed iPhone build or Meta transport-support claim.

```sh
swift test --package-path Tools/L2CAPLab
```

## Fixture contract

- Explicit fresh generation per run; link -> channel -> transfer -> terminal. Stale callbacks and terminal I/O ignored; duplicate phase transitions cannot extend deadlines. Use monotonic milliseconds from one clock. Independent timer tick required even without readiness.
- Three fixed payload sizes: 64, 1024, 4096 bytes. Deterministic byte at offset i = low 8 bits of ((31*i + 17) XOR (73 * floor(i/256))); varying the block index detects whole-chunk reorder or repetition; no arbitrary input. Initiator sends the fixture, responder verifies all bytes before generating the same fixture, initiator validates it. A responder's success records bytes accepted by the local output stream, not delivery; require both endpoint reports. This is neither a cryptographic challenge nor identity/authentication.
- At most one operation per pump, at most 256 bytes per operation; no unbounded accumulation of peer data. Handle partial counts, zero write / would-block, invalid counts, unexpected bytes, EOF and I/O errors. The state machine does not inspect trailing data after terminal cleanup. The fixture is a single exchange, not a production framing protocol.
- 10 seconds per phase and 30 seconds total from run start, no progress-based deadline extension. These are initial lab limits, not product latency targets. Readiness is advisory; the platform adapter must avoid blocking its owner or delaying the independent timer.
- Every terminal path requests cleanup once. Foundation wrapper provides idempotent close; the platform owner must remove run-loop scheduling, invalidate delegates, cancel connection/unpublish local service and retire generation. No auto-retry.
- Report only role, outcome, byte counts, stage durations and explicit not-tested markers. Never include identities, raw payload or private metadata.

## Physical lab driver and operating procedure

Use a personally controlled lab accessory with an independently defined service and an encrypted, documented lab-only L2CAP PSM. On Apple peripheral API, use [publishL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel(withencryption:)) and publish only the lab service; communicate its dynamically assigned PSM to the owner through a trusted out-of-band local setup (never guess PSMs). Use [openL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:)) only on that explicitly identified and authorized fixture. The lab owner must control both endpoints; no Meta target. Require explicit foreground start, independent identity confirmation, one connection/channel, consent to any OS security prompt, deadline and immediate stop on lifecycle or ownership loss. A fixed UUID or an encrypted link alone is not authentication. Keep PSM/identity configuration local; no persistent credentials or peer payload logs.

### Build both lab-only applications

From the repository root on macOS with Xcode:

```sh
bash scripts/install-xcodegen.sh
cd Tools/L2CAPLab
../../.build/tools/xcodegen generate
xcodebuild -project L2CAPLab.xcodeproj -scheme L2CAPLabMac -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project L2CAPLab.xcodeproj -scheme L2CAPLabPhone -configuration Release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Open the generated project in Xcode. Run L2CAPLabMac locally and select your own signing team and physical iPhone for L2CAPLabPhone. Simulator builds are compilation checks only. The Mac app has no sandbox or background capability; do not distribute these developer tools. No external account or network is needed.

1. In a controlled radio environment, keep both apps foreground and explicitly authorize both owned devices. On Mac choose a fixture size and start. The app requests an encrypted L2CAP listener, gets the dynamically assigned PSM, publishes a fresh lab-namespace GATT service with a read-only synthetic descriptor, and advertises only that service. The invitation is local-only and expires with the run. No third-party device or production service.
2. Transfer the exact invitation (service UUID, PSM and size) to the iPhone using a trusted local method, without posting it to GitHub or saving it. Scan for the specific service; the app permits one candidate only after the bounded scan. Independently confirm that it is the Mac you control, then explicitly connect. Verify the advertised service and the lab descriptor against the invitation before opening the given PSM. Never try arbitrary UUIDs or PSMs. Only dynamic LE SPSM 0x0080–0x00FF is admitted, per Bluetooth Core specification Vol 3 Part A Table 4.15; the live GATT descriptor must match the exact invitation. A descriptor match, encrypted link and invitation are not cryptographic peer authentication; do not use this tool in an uncontrolled environment.
3. Mac accepts the opened channel only after the operator confirms that the owned iPhone just initiated the connection; no stream I/O before acceptance. If there is unexpected or ambiguous activity, stop both apps. One channel only. System security prompts may require explicit approval; a non-active scene cancels the run (retry manually after returning active). Never change an existing Meta pairing or use the tool on glasses.
4. Compare sanitized reports on both ends. A run passes the synthetic exchange only if both sides report success and exactly the agreed counts. Responder stage timings omit independently unobserved link/channel intervals. Responder transfer elapsed time includes the brief operator acceptance; after local write success it allows a bounded 2 s drain before cleanup, not a delivery guarantee. The driver reports listener-to-open separately. Initiator link duration starts at explicit connect; channel duration includes the synthetic GATT verification. Do not interpret them as raw radio latency.
5. Cancel/timeout/disconnect stops the local run, retires manager/peer identities, closes/unschedules streams and requests removal of the owned listener/service. A bounded retirement grace handles pending publication callbacks; physical teardown/unpublish success remains to be verified. No automatic retry or background mode. The 100 ms timer checks deadlines independently of readiness and attempts at most one bounded pump when active; immediate subsequent work is queued only after positive progress. A generation-scoped stream event coalescer defers callback handling to avoid reentrant I/O and bounds queued drain work. Main-queue scheduling can delay timer callbacks. Use Stop if the device state changes.

The invitation/PSM is transient UI setup, not part of the shareable report. Do not capture device names, UUIDs, invitations, RSSI, raw payloads, peer identifiers or OS pairing dialogs. Report fixture size, condition, trial number, model/OS and app SHA plus categorical report only. Run three independent exchanges per size, including failures, and negative cases for denied authorization, wrong invitation, unavailable peer, ambiguity, disconnect, cancel and inactivity. Test two devices, check teardown and no reconnect. A responder drain deadline is not proof of delivery; both endpoint evidence is required. Three trials are screening, not p95. B0 success does not pass B1/B2 or Gates C–E.

Known limits: the local lab namespace is a scope guard, not authentication; an attacker can spoof an advertisement/descriptor. Use only an isolated, personally controlled fixture. Link encryption is requested via the Apple API, not independently measured. No Meta transport, session, enrollment, wake, power or production compatibility claim.
