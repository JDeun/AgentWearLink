# Gate B0: bounded synthetic LE L2CAP lab — policy phase

Refs #660, #663, #655. Independent research Swift package, not part of the production Companion, Core or DAT. The [Gate A probe](../BLEDiscovery/README.md) remains read-only. No Meta UUID/PSM, protocol, pairing, account, credentials, device commands, audio or wake integration.

## Current evidence boundary

This package implements a deterministic single-owner link/channel/transfer state machine, a bounded synthetic echo fixture and a Foundation stream wrapper. The duplex test is an in-memory fake transport, not Bluetooth. The memory stream test exercises Foundation I/O, not an actual CBL2CAPChannel. No CoreBluetooth peripheral/central adapter is included yet. No physical evidence, signed iPhone build or transport-support claim.

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

## Next: physical lab driver (separate change)

Use a personally controlled lab accessory with an independently defined service and an encrypted, documented lab-only L2CAP PSM. On Apple peripheral API, use [publishL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel(withencryption:)) and publish only the lab service; communicate its dynamically assigned PSM to the owner through a trusted out-of-band local setup (never guess PSMs). Use [openL2CAPChannel](https://developer.apple.com/documentation/corebluetooth/cbperipheral/openl2capchannel(_:)) only on that explicitly identified and authorized fixture. The lab owner must control both endpoints; no Meta target. Require explicit foreground start, independent identity confirmation, one connection/channel, consent to any OS security prompt, deadline and immediate stop on lifecycle or ownership loss. A fixed UUID or an encrypted link alone is not authentication. Keep PSM/identity configuration local; no persistent credentials or peer payload logs.

Implement a separate CoreBluetooth central/peripheral adapter that maps current-generation didConnect, didOpen, stream readiness/error/end and disconnect to the policy. Schedule input/output on one owner run loop and pump on readiness without spinning; test notification coalescing and cross-direction readiness (e.g. after responder's final read). Ensure independent timer and cleanup are not starved by main queue work. Never open an arbitrary target channel; no runtime inclusion in AWL.

Pilot on owned devices (iPhone + controlled fixture, e.g. Mac or a second iOS device); record model/OS, tool SHA, encryption/authorization condition, size and run number. For each size run three independent exchanges with both ends reporting exact counts and terminal success, plus cancel during each phase, missing PSM/service, unavailable peer, early EOF/disconnect, blocked stream and stale callback tests where safely reproducible. Record all failures and stage durations; three trials are screening, not p95 evidence. Verify teardown and no automatic reconnect. Passing B0 on a lab endpoint does not pass B1 (authorized Meta endpoint), B2 (target byte exchange) or C–E (session, enrollment, wake and power).
