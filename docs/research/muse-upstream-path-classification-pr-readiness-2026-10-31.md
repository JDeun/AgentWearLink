# Muse upstream inventory classification and PR readiness (2026-10-31)

## Reproducible inventory method
GitHub recursive tree `GET /repos/facebookincubator/muse-gadget-sdk/git/trees/main?recursive=1`; filter `type=blob`. Total **1,096 tracked blobs**, sum of blob sizes **28,000,296 bytes**. Counts below are disjoint, applied in priority order:

| Category | Blob count | Matching logic |
|---|---:|---|
| Vendored codec candidates | 177 | `esp32/components/{libvpx_vp8,tinyh264,minimp3}/` |
| Test/fixture candidates | 302 | `esp32/tests/`, `linux/tests/`, other `/tests/` |
| Board overlays/docs | 60 | `esp32/devices/` |
| First-party runtime candidates | 322 | `esp32/main/`, `esp32/components/{muse,noise_core,camera,muse_vstream}/`, `linux/src/`, Android `src/`, iOS `Sources/` |
| Tools/simulator | 81 | `esp32/tools/`, `web-flasher/`, `esp32/simulator/` |
| Image/font/binary assets (extension heuristic) | 15 | PNG/JPEG/GIF/BIN/PPM/PBM/TTF/WOFF/SVG after earlier categories |
| Other build/docs | 139 | remainder |
| **Total** | **1,096** | **All tree entries classified at path level** |

**Important limitations:** This is an exhaustive *path-level classification*, not a content or license audit. Heuristic categories can include markdown/headers/build files, and earlier category precedence intentionally wins over file extension. Git tree may change; pin upstream commit SHA before a final reproducible audit. Runtime candidate count is not an assertion that all 322 files have been inspected.

## PR #640 readiness
On 2026-10-31, GitHub reported PR #640 **open, non-draft, mergeable=true**, with 17 research markdown files. `mergeable=true` is a merge-conflict assessment, not an audit acceptance, CI pass or implementation proof. PR is the correct integration vehicle; do not open duplicate PR.

## Required remaining evidence
- Inspect and map remaining first-party runtime candidates (especially Linux, Android/iOS and ESP32 security utilities) against tests and feature flags.
- Produce a traceability ledger of reachable entrypoints, guards, failure paths and test cases; distinguish source assertions from executable host tests.
- Reconcile upstream revision and dependency licenses. Hardware tests remain tracked separately.

## Sources
- https://api.github.com/repos/facebookincubator/muse-gadget-sdk/git/trees/main?recursive=1
- https://github.com/JDeun/AgentWearLink/pull/640
