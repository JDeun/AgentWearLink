# Muse BLE central, image fetch and tunnel resource ownership (2026-10-31)

## Static source observations
- `esp32/main/ble_client.c` (927 lines): connection slots, operation-generation lock, timeout invalidation before worker buffer release, late NimBLE callback fencing, deferred cleanup of cached GATT discovery and kept subscriptions; `ble_client_secure` initiates SMP security. **Distinct from Home Link application pairing**.
- `esp32/main/ble_commands.c` (912 lines): typed BLE scan/connect/read/write/subscribe commands with bounded parameters (scan <=30s, max 40 devices, subscription <=60s), command timeout metadata, worker and originating Noise session generation. The BLE client is a device-control bridge, not necessarily an AWL wearable adapter.
- `esp32/main/ble_central.c` (330 lines): discovery/probe helper serializes scan/connect operations and waits on semaphores; separate from general BLE client.
- `esp32/main/tunnel_netif.c` (378 lines): preallocated PSRAM packet slots, bounded free/work queues, no malloc on packet TX hot path, batches <=16 packets / <=8192 bytes, drops on congestion rather than blocking lwIP. This is **best-effort network traffic**, unlike command completion or terminal events.
- `esp32/main/image_fetch.c` (784 lines): explicit TLS stack and internal heap floor, <=3 redirects, generation-fenced async image responses and cancellation. HTTPS memory reservation differs between PSRAM-capable and constrained devices.

## AWL decisions
| Pattern | Decision | Why |
|---|---|---|
| BLE callback generation invalidation before buffer free | BORROW design invariant (#633/#637) | stale callbacks must not access released request storage |
| BLE command limits and session generation | REFERENCE (#633/#641) | bounded and correlated device actions |
| Bounded tunnel queue with packet drops | REFERENCE only for best-effort media (#635) | terminal/semantic events must never silently drop |
| Heap-floor gating for optional image work | REFERENCE (#638) | memory-aware admission, but no direct ESP-IDF transplant |
| SMP security as authorization | EXCLUDE assumption | link encryption is not command-level authorization |

## Audit limitation
This is static source review of five implementations. No actual BLE peripheral, packet-loss test, heap pressure run or physical image decode was performed. No AWL runtime code was modified.
