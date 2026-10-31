# Muse SDK repository-wide static audit inventory and CI coverage (2026-10-31)

## Scope and methodology
Queried the upstream `main` recursive Git tree using GitHub API. **1,096 tracked blobs** at the time of inspection. This is a *complete filename inventory*, not a 1,096-file content review. Paths are grouped by top-level two components; counts include docs, images, source, fixtures, generated/test artifacts.

| Tree prefix | Files |
|---|---:|
| `esp32/components` | 338 |
| `esp32/tests` | 262 |
| `esp32/main` | 93 |
| `esp32/devices` | 60 |
| `esp32/tools` | 49 |
| `android/musegadgetstest` | 44 |
| `ios/musegadgetstest` | 36 |
| `esp32/simulator` | 33 |
| `linux/tests` | 32 |
| `linux/src` | 31 |
| other (skills, docs, workflows, fixtures) | 118 |
| **Total** | **1,096** |

## CI as defined, not assumed green

- `.github/workflows/linux.yml`: `pytest -q` on newest Python 3.x and Python 3.9 pinned `cryptography==3.3.2 websockets==13.1`; ShellCheck install.sh. This is a compatibility matrix, **not** proof of live BLE hardware.
- `.github/workflows/esp32.yml`: ESP-IDF `espressif/idf:v6.0.1`, host C/C++ tests via Python unittest discovery, installed `libmbedtls-dev`; pinned external FreeInk SDK test source; CMake simulator with Linux sanitizers and two macOS runners; many per-board firmware build variants. Build success is **not** runtime BLE/Wi-Fi/OTA evidence.
- Host tests are heterogeneous. `esp32/tests/test_link_encrypted_pairing_contract.py` uses *source string assertions* on `ble_server.c`, `app.c` and `link_pairing.c`; these prove specific lexical wiring and ordering, not runtime cryptographic behavior.
- `esp32/tests/test_link_noise_session.py` combines actual C harness compilation/execution with source-string checks. Its own comment explicitly says the auth rejection -> reconnect -> token refresh end-to-end path needs FreeRTOS/TLS and is **not exercised by the harness**.
- Python test collection is not a coverage report. No line/branch coverage threshold is established by these two workflows.

## Major ownership boundaries

| Subtree | Owner / primary concern | Static test relation | Residual risk |
|---|---|---|---|
| `esp32/main` | BLE ingress, Wi-Fi provisioning, Noise, OTA, device commands | `esp32/tests/test_link_*.py` + harnesses | callback races, transport failures |
| `esp32/components/noise_core` | Noise cryptography | host noise tests | full device/host interoperability |
| `esp32/components/muse` | UI, voice, board services | `test_muse_*.py`, harnesses | physical audio/display and power |
| `esp32/components/muse_vstream` | phone-to-device media | video loop tests and simulator | radio, buffer and decoder timing |
| `esp32/devices` | per-board BSP/config | build matrix and power fixtures | per-board runtime variation |
| `esp32/simulator` | UI host simulator | CTest Linux/macOS | excludes radio and actual peripherals |
| `linux/src` | BLE, pairing, Noise, command executor, voice | `linux/tests` pytest | real daemon/service and BLE link |
| `ios/musegadgetstest` | phone video source | no dedicated iOS CI workflow visible | Xcode/device behavior |
| `android/musegadgetstest` | phone video source | no dedicated Android CI workflow visible | Gradle/device behavior |
| `protocols` | video protocol specification | indirect video tests | protocol schema drift |

## Specific static coverage findings

1. Source-contract tests and executable harness tests must be reported separately; count of test files is not coverage percentage.
2. The existing Noise test explicitly acknowledges a missing full TLS/FreeRTOS auth-refresh E2E exercise.
3. Current CI covers Linux, ESP32 host, simulator and firmware builds, but the checked workflows do not run iOS or Android sample app builds.
4. Neither workflow publishes coverage percentages or branch thresholds; avoid describing upstream as fully tested.
5. An external FreeInk source checkout is pinned to a commit, improving reproducibility; it is a distinct third-party dependency and license review item.

## Decisions and executable follow-ups

- **KEEP** AWL's existing Swift tests and CI as independent release gates; do not import Muse's CI unchanged.
- **REFERENCE** layered checks: source contract, executable protocol harness, host simulator, per-board build matrix.
- **ADD** explicit test-classification and skip reporting to #641, and full physical E2E evidence to #638.
- **ADD** Apple/iOS and Android sample build feasibility to #639 if codec transport is ever imported.
- **DO NOT CLAIM** 1,096 files were read; the inventory is complete but code-content audit is targeted.

## Sources
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/.github/workflows/linux.yml
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/.github/workflows/esp32.yml
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/tests/test_link_encrypted_pairing_contract.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/esp32/tests/test_link_noise_session.py
- https://github.com/facebookincubator/muse-gadget-sdk/blob/main/linux/pyproject.toml
