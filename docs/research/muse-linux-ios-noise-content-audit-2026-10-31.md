# Muse first-party runtime source review — Linux and iOS/Noise continuation (2026-10-31)

## Actual content reviewed in this pass
Eleven upstream files retrieved and their function, error and lifecycle paths inspected. This is **not** a claim of all 322.

| File | Observed code behavior | Risk/decision |
|---|---|---|
| `linux/src/musegadget/config.py` | SDK token env/file, regex validation, JSON state atomic os.replace | Token shape not authentication; check permissions/atomic durability |
| `linux/src/musegadget/doctor.py` | Read-only diagnostics, avoids exposing saved token values, distinguishes structural token check from server acceptance | BORROW read-only safe diagnostics |
| `linux/src/musegadget/cli.py` | CLI pairing/service/voice and 90s local socket timeout; reduces websocket logs on credentialed call | KEEP separation of local command privileges |
| `linux/src/musegadget/muse_turn.py` | bounded replay scope, status transitions, acknowledgement and reply settlement | BORROW lineage-aware turn replay fencing |
| `linux/src/musegadget/service.py` | token refresh 3h, retry 300s; explicit rejected-token retry logic | EXPERIMENT backoff/rotation independent of Muse service |
| `linux/src/musegadget/commands.py` | command parameter schema and 600s timeout max; drop-in command definition isolation | EXCLUDE unsandboxed execution; borrow validation only |
| `ios/musegadgetstest/Sources/WifiLink.swift` | Bonjour/TCP, serialized video queue, credits and bounded writes | EXCLUDE unauthenticated media channel, BORROW credit accounting |
| `ios/musegadgetstest/Sources/CameraStreamer.swift` | AVFoundation camera and H.264/optional codec encoder cleanup, dispatch timer cancellation | BORROW cancellation/cleanup invariants |
| `ios/musegadgetstest/Sources/MainViewController.swift` | camera permission handling, clip failure and device selection, queue budget | BORROW explicit permission and queue budget |
| `esp32/components/noise_core/src/ClientSession.cpp` | scratch overlap check and explicit frame buffer bounds before transport encoding | BORROW buffer/alias validation |
| `esp32/components/noise_core/src/InitiatorHandshake.cpp` | Noise handshake decrypt/verify, explicit temporary secret zeroization | BORROW cryptographic zeroization discipline, not vendor token architecture |
| `esp32/components/camera/camera_sscma.c` | SPI camera command request deadlines, JPEG buffer handling, PM lock and release | BORROW bounded camera ownership and power lifecycle |

**Correction:** 12 named files in this pass, not 11.

## Provenance
- https://github.com/facebookincubator/muse-gadget-sdk/tree/main/linux/src/musegadget
- https://github.com/facebookincubator/muse-gadget-sdk/tree/main/ios/musegadgetstest/Sources
- https://github.com/facebookincubator/muse-gadget-sdk/tree/main/esp32/components/noise_core/src
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/camera/camera_sscma.c

## Scope integrity
The 322 path-classified candidates remain the target; there has been **no user-authorized scope reduction**. Full-file semantic review and per-file acceptance for the remaining candidates is not yet established. No tests executed, no hardware E2E, no static-audit completion declaration.
