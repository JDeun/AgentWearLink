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

## Offline report assessment

Use the standard-library-only analyzer; no Bluetooth, network, device identity, credentials or report contents are exported. Run locally, with a JSON manifest containing schema 1 and up to nine trial entries. Each entry has exactly size (64, 1024 or 4096), trial (1–3), initiator (complete sanitized phone report text or null), responder (complete sanitized Mac report text or null). Use JSON string escaping for report newlines. No extra metadata fields, invitations, UUIDs or raw data. The manifest is not an authenticated pairing of reports: manually associate both endpoints with the same run, preserve failures, and record hardware/OS/app revision separately in a sanitized lab record. The following is a deliberately incomplete example, not measured evidence.

```json
{"schema":1,"trials":[{"size":64,"trial":1,"initiator":null,"responder":null}]}
```

```sh
python3 Tools/L2CAPLab/analyze_reports.py < lab-trials.json
python3 -m unittest discover -s Tools/L2CAPLab/report_tests
```

Exit 0 means all nine manually correlated report pairs satisfy the report contract; 1 means at least one missing, failed or invalid pair; 2 means malformed/oversized manifest or duplicate trial slot. Only exact schema keys and enumerated values are accepted, including the actual no-session terminal report format. Unknown fields and invalid values are rejected without echoing them. Counts, stage timings, role and driver terminal must agree. A local successful responder write followed by cancellation is not a pass. Missing trials remain visible; no p95 or power extrapolation. Median/range are descriptive only and calculated from passing pairs with explicit sample size. A passing matrix is textual evidence consistency only, never physical radio, peer identity, encryption, teardown, Meta authorization, or wake evidence. Identical reports can occur independently; this format cannot detect replay or prove both endpoints participated in the same exchange. Do not commit personal manifests or use the tool to authenticate peer evidence.

## Driver lifecycle regression boundary

The live CoreBluetooth driver uses the same pure lifecycle policy as the deterministic tests: allowed central/peripheral stage transitions, generation admission, setup/confirmation/listener/drain deadlines, cancellation retirement, and one-shot late publication/add/advertising cleanup eligibility. Duplicate or out-of-order stage callbacks cannot advance the policy or extend its deadlines; the driver also checks actual manager, peripheral, characteristic and stream object identity. A stale connect-failure/disconnect callback outside a valid stage is ignored. Only the matching retired manager and pending owned resource may trigger a late cleanup request; a duplicate cannot consume that request twice. The bounded retirement grace and cleanup requests are not proof of OS teardown.

The tests run without CoreBluetooth and inject logical events/time. They cover the shared policy, not the OS delegate delivery order, actual radio commands, UI foreground behavior, or physical resource cleanup. The standalone iOS/macOS compilation and privacy CI remain separate.

## Independent framed transport (AWLF v1)

This is a new lab-only wire contract, not a Visor/Meta protocol or production integration. The existing physical apps still run the raw synthetic report-v1 fixture; no invitation/report or radio behavior changed. The framed library binds to the same LabPort interface and is exercised by deterministic two-endpoint in-memory tests. A later explicitly versioned physical framed mode must have independent evidence and report compatibility.

| Offset | Bytes | Meaning |
| --- | ---: | --- |
| 0 | 4 | ASCII AWLF magic |
| 4 | 1 | version = 1 |
| 5 | 1 | kind: request = 1, response = 2 |
| 6 | 2 | unsigned payload length, 1 through 4096 |
| 8 | 4 | directional sequence, starts at 1, maximum 1024 |
| 12 | 4 | nonzero request/response correlation |
| 16 | 1–4096 | synthetic payload |
| 16 + length | 4 | CRC-32/ISO-HDLC of header + payload |

All multi-byte integers are big-endian; no padding. Maximum wire frame 4116 bytes. Golden vector (response, sequence 1, correlation 0x01020304, payload 0xAB): `41 57 4c 46 01 02 00 01 00 00 00 01 01 02 03 04 ab b5 ae 1e 42`. CRC detects accidental corruption, not authentication, authorization or adversarial tampering. Sequence is strict within each direction/generation, no wrap, no automatic retry; a new generation requires a fresh object. Correlation matches a response to the caller's outstanding request, not a device/session identity or cross-run replay proof. No proprietary constants, credentials or upstream code used.

Parser validates the 16-byte header before accepting payload, accepts arbitrary fragmentation, stops after a complete frame and returns exact consumed length so the caller retains any coalesced suffix. Ready-frame backpressure is explicit; no unbounded receive list, no scanning for magic after a malformed frame. EOF mid-header/body/trailer is terminal; clean boundary EOF is only an input-side event, never proof of exchange success. The LabPort adapter requests at most the remaining header/body and 256 bytes per call, never reads ahead while a frame is ready, and retains one TX wire frame plus one RX partial wire frame or ready payload (logical retained maximum 8232 bytes; transient bounded copy/allocator overhead not measured). Zero writes and would-block do not spin; partial writes advance exact offsets. An invalid count, stream failure or malformed inbound frame poisons both directions and clears retained data. Caller owns scheduling, independent deadlines, cancellation, and OS cleanup; retirement invalidates the old generation, no retry/replay. The pure codec is not a transport-level authentication or session protocol.

Tests include the standard CRC vector, fixed header byte order, all single split points, one-byte fragmentation, maximum payload, coalesced suffix/backpressure, malformed header/CRC, missing/repeated sequence, exhaustion, truncated EOF, stale generation/retirement, request/response matching, invalid I/O counts and repeated 64/1024/4096-byte synthetic round trips through bounded pipes with partial I/O and backpressure. These are deterministic LabPort tests; no radio, iOS background, Meta access, session/wake or power evidence.

## Independent message session (application session v1)

The pure Swift LabMessageSession owns LabFramedTransport for one explicit generation. This is separate from the AWLF envelope version, actual radio driver and raw report-v1 experiment. No changes to CoreBluetooth apps, invitation, raw report analyzer or production. Only synthetic echo is implemented; no arbitrary commands, credentials, upstream protocol or wire authentication.

### Wire and negotiation

The first request/response uses reserved correlation 1 (directional frame sequence starts at 1). HELLO is a six-byte payload: minimum application version, maximum application version, 16-bit capability bitmap, 16-bit maximum payload (all multi-byte values big-endian). Only application version 1 and capability bit 0 (synthetic echo) are implemented. ACCEPT has the same layout with min=max=selected version, exactly the selected supported capability and a maximum payload no greater than either endpoint's offer. Unknown offered bits are not selected; unknown selected bits, version mismatch, malformed length/range, or absent required echo capability fail closed. The payload limit must be 64–4096; supported fixture sizes are 64/1024/4096 bytes at or below that limit. Negotiation is compatibility checking, not cryptographic downgrade protection. There is no silent raw fallback.

After negotiation, only the initiator may submit an application request, with monotonic correlation 2–1024 (the envelope has its own independent directional sequence). Its payload must be one known synthetic fixture; the responder validates all bytes and regenerates the same fixture. An exact matching response is necessary for completion. Out-of-order, repeated or mismatched correlation, wrong direction, unknown or altered fixture, malformed frame and EOF fail the session. A local responder write is not proof of remote delivery.

One outstanding request and one consumable metadata-only completion per initiator. Until the owner consumes the completion, further requests are backpressured; rejected requests consume no IDs. Duplicate or delayed response while idle is rejected even on the first partial bytes. Terminal cancellation (including targeted cancellation of the active correlation) and timeout close the generation: bytes already accepted by the stream cannot be unsent, so no wire cancellation, automatic retransmission or reconnect/replay. The initiator resolves the accepted request once with verified response or typed failure; teardown leaves at most that bounded metadata completion for the caller to collect. The owner consumes one cleanup obligation and closes the physical resources. Explicit local close is admitted only when ready with no exchange in flight; this is not a wire close acknowledgement. The responder's local agreement is selected before ACCEPT finishes writing, not proof the initiator received it. A compliant initiator has one outstanding request; the responder does not claim it can detect the actual arrival time of additional bytes buffered by the OS during a response write. Stale generation events do not touch I/O or deadlines.

Use a monotonic clock: 10 s negotiation (both directions combined), 10 s idle (also bounds partial responder request reception), 10 s request/response-send window (initiator from admission, responder from full validated request), and 60 s total. Progress does not extend a deadline; caller must invoke tick independently of readiness. Each pump does at most one bounded LabPort operation. The underlying one TX/one RX frame limit is unchanged (8232 logical retained wire/payload bytes, not allocator measurements). No queued application payloads, no unbounded correlation history. Both endpoint evidence is required.

Deterministic tests exercise the actual message session over framed LabPort adapters and bounded synthetic pipes, plus injected hostile/malformed logical frames, mismatched negotiation, partial TX, correlation, timeout and lifecycle events. The separate session report is categorical diagnostic text, not raw report-v1 and not accepted by the existing analyzer. A physical framed mode needs explicit invitation/marker mode agreement and a separately versioned evidence/assessment contract before device trials. No hardware, Meta transport, session authorization or wake/power evidence.
