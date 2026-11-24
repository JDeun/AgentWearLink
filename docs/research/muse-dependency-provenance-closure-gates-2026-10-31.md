# Muse dependency provenance and static audit closure criteria (2026-10-31)

## Repository accounting
The upstream recursive Git tree contains 1,096 tracked blobs (~28 MB). Not every blob is executable first-party code: includes binary images, golden fixtures, board BSPs, build overlays, third-party codecs and generated assets. **An inventory is not an audit of contents**.

## New inspected evidence
- `esp32/components/libvpx_vp8/CMakeLists.txt`: conditionally compiles vendored VP8 C sources with -O2; its source license remains BSD and PATENTS, not re-licensed by top-level Apache-2.0.
- `esp32/components/tinyh264/CMakeLists.txt`: conditionally compiles upstream H.264 decoder C and target SIMD with -O2; inspect its README and upstream attribution before reuse.
- `esp32/components/noise_core/CMakeLists.txt`: seven C++ source files compiled C++17 with exceptions and RTTI disabled, backed by mbedTLS.
- `esp32/components/muse_vstream/muse_vstream.c`: power-of-two bounded ring, max_frame <= half ring, producer/consumer stream rollover; requires concurrent tests for memory-order and reset transitions.
- `esp32/components/camera/camera.c`: atomic single-owner capture/stream gate, explicit capture-release lifecycle; different from SenseCAP driver and Watcher preview.
- `android/musegadgetstest/build.gradle.kts`: Android Gradle Plugin 8.13.2, minSdk 33, targetSdk 34, optional native codecs copied from configurable local library directory. Local build configuration is not supply-chain provenance.
- `ios/musegadgetstest/README.md`: iOS17+ Xcode16+ phone video demo uses AVFoundation, Bonjour, VideoToolbox and Wi-Fi TCP; not an Apple Watch wearable adapter.

## Required closure gates (not yet satisfied)
1. Record per-file classifications (owned code, vendored code, generated/binary, test, documentation, build), hashes, license attribution and feature reachability for **all** tracked blobs.
2. Trace every **reachable first-party** security-sensitive entrypoint, including token handling, provisioning, OTA, local BLE, unauthenticated video, commands, filesystem, camera and audio.
3. Map reachable implementations to exact tests (static assertions vs compiled harness vs integration vs physical), and record negative-case gaps.
4. Decide each reusable architecture item KEEP/BORROW/EXPERIMENT/EXCLUDE with AWL issue and acceptance gate.
5. Check PR #640 consistency and preserve unresolved physical E2E as explicit separate issue; do not equate static closure with hardware E2E.

## Current conclusion
**Not complete.** Key critical paths have been examined, but no systematic all-blob classification and reachable-code-to-test traceability ledger has been produced. The remaining work is finite and can be scoped by first-party reachable code; declaring completion now would be inaccurate.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/tree/main/esp32/components
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/libvpx_vp8/CMakeLists.txt
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/tinyh264/CMakeLists.txt
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/noise_core/CMakeLists.txt
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/muse_vstream/muse_vstream.c
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/components/camera/camera.c
