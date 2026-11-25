# Muse historical runtime audit ledger — 2026-11-25

Refs #643 #639 #641 #634. The 2026-10-31 inventory used mutable main. Reconstructed its exact-count baseline from the last commit on upstream main before the end of October 31 UTC: [1b894f551e64416e2844452ec6056ec56d6a10f1](https://github.com/facebookincubator/muse-gadget-sdk/tree/1b894f551e64416e2844452ec6056ec56d6a10f1), committed October 30 18:33:06 UTC, tree 39c16f5ec2263d75c6ccb1534c2d2e9e37662d89. Counts and total bytes match; no original per-file manifest was stored, so this is a count-matched reconstruction, not independent proof of the original fetched SHA. Current main has moved.

[Ledger (TSV)](muse-runtime-audit-ledger-2026-10-31.tsv): 322 runtime candidates, blob SHA, size, provisional path/extension classification, review status/evidence. Query [pinned recursive tree](https://api.github.com/repos/facebookincubator/muse-gadget-sdk/git/trees/1b894f551e64416e2844452ec6056ec56d6a10f1?recursive=1), filter type=blob, apply [original classification precedence](muse-upstream-path-classification-pr-readiness-2026-10-31.md). Results: 1096 blobs / 28000296 bytes; runtime 322, vendored 177, tests 302, boards 60, tools 81, assets 15, other 139. Runtime: Android 21, ESP32 components 158, ESP32 main 93, iOS 19, Linux 31.

## This pass: four content reviews

| Path | Evidence / dependency |
| --- | --- |
| [Linux package init](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/src/musegadget/__init__.py) | Constant metadata/Apache header; runtime trust/cleanup N/A. |
| [BLE framing](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/src/musegadget/ble_framing.py) | Actual encoder/assembler, in-order/reset/assembled limit; unframed passthrough and sender bound asymmetry need caller analysis. [Test source](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/tests/test_ble_framing.py) covers split/round-trip, malformed/order/reset and oversize; not run. |
| [Noise framing](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/src/musegadget/noise/framing.py) | Actual encoding/decoding and assembly: bounds, expiry on decode, duplicate/inconsistent frames and sticky poison. Wall clock/owner disposal/aggregate budget and conformance need evidence. |
| [Provider audio gate](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/src/musegadget/voice_gate.py) | Bounded identity and interruption gate, hold/drop/play; unfenced lineage-free audio and owner flush/termination require independent stricter design. [Test source](https://github.com/facebookincubator/muse-gadget-sdk/blob/1b894f551e64416e2844452ec6056ec56d6a10f1/linux/tests/test_voice_gate.py) covers stale identity/missing lineage/overflow; not run. |

**4/322 content rows individually reconciled, 318 not reconciled.** Earlier [synthesis](muse-gadget-sdk-research-synthesis-handoff-2026-10-31.md) and batch documents examined more paths; do not count them as completed rows until tied to exact blobs and evidence fields. No upstream tests executed, no full caller graph, license clearance, hardware result or full-file audit.

## Closure procedure

Inspect actual pinned content or binary metadata per path; record role/entrypoint, caller reachability, trust, failure/cancel/cleanup, license/provenance, exact tests or justified N/A, severity/disposition. Reconcile old batch evidence by hash. Prove generated assets, not automatic source coverage. Derive executable/host/hardware matrix; link executed conformance #641. Keep #643 open before all rows and cross-file security/test mapping are reconciled; #639 adoption gate separate. No source/binary imported.
