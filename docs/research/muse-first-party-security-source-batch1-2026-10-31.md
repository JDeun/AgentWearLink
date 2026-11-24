# Muse first-party security source review: batch 1 (2026-10-31)

## Coverage definition
This is **content-level review of seven named C files**, not 322-file completion. Each was fetched from upstream `main`, with concrete line evidence below. Previous audit documents cover other runtime files; do not double-count them as newly reviewed.

| Source | Key reviewed behavior | Security consequence |
|---|---|---|
| `esp32/main/config_store.c:31-65` | checks NVS encryption compile flag/eFuse HMAC capability; logs plaintext/encrypted mode; aborts when encryption cannot safely initialize; refuses automatic NVS erase | Credential storage may be plaintext when encryption not compiled. Firmware configuration is a security gate. |
| `esp32/main/identity.c:80-119` | loads SDK token from NVS, validates shape, fallback to compile-time token; updates require reboot | Token format validation is **not** token authorization; compile-time token is embedded credential material. |
| `esp32/main/sdk_token_console.c:42-62` | accepts `>sdk_token=` serial command; logs first 12 token characters, restarts after storage | Local serial provisioning is a privileged channel; prefix disclosure and physical-access assumptions require threat-model coverage. |
| `esp32/main/diagnostic_log.c:31-119,156-212` | bounded log ring, truncation and snapshot; installs vprintf sink | Bounded storage does not guarantee secret redaction. |
| `esp32/main/bug_report.c:188-289,332-370` | serializes captured diagnostic log tail to base64, marks `contains_pii=true` and sensitivity `restricted`, reports over Noise session-generation fence | **Base64 is encoding, not redaction/encryption**. `redaction_profile` label alone is not evidence of sanitized log contents. |
| `esp32/main/vm_api.c:53-82,125-174` | 15s HTTPS client with certificate bundle; redirect handler deletes Authorization before redirect and restores only when origin unchanged | Positive cross-origin bearer-leak mitigation; test redirects, same-origin canonicalization and HTTPS downgrade. |
| `esp32/main/net_discovery.c` | ARP, mDNS, SSDP, WSD, SNMP, NetBIOS discovery with bounded observation/log fields | Local network discovery has privacy and network scope implications; permission and response caps require separate tests. |

## New security observation: bug report privacy
`bug_report.c` calls `mbedtls_base64_encode` directly on `logs->data` and includes it as `tail_base64`. The JSON declares `redaction_profile=hatch-link-support-v1` and `contains_pii=true`. **No sanitization of arbitrary diagnostic lines is visible in this serialization path.** It is not proof that every line contains a secret, nor proof that an upstream service leaks the report; it is a data-minimization risk and must not be copied into AWL as a supposedly redacted diagnostic pipeline.

## AWL decisions
- KEEP OS-backed credential storage and authenticated agent/device boundary.
- BORROW explicit fail-closed credential storage behavior, but do not use plaintext fallback in AWL.
- BORROW cross-origin bearer removal invariant and add redirect-negative tests if implementing analogous HTTP clients.
- EXCLUDE raw diagnostic log uploads by default; require consent, local redaction, structured allowlist and retention controls (#637).
- EXPERIMENT scoped local discovery only with explicit permission and network boundaries (#638).

## Remaining
First-party runtime candidate set contains 322 **path-classified entries**, including fonts/build files, and this batch covers only seven. No 322/322 claim, runtime tests or hardware E2E proof.
