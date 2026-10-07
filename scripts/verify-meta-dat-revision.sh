#!/bin/bash
set -euo pipefail

EXPECTED_REVISION="1f38beecba83c4c8b5e343540f9cd615323ab19a"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_FILE="${ROOT_DIR}/Adapters/MetaDAT/Package.resolved"
TEST_APP_SPEC="${ROOT_DIR}/Adapters/MetaDAT/TestApp/project.yml"

if [[ ! -f "${RESOLVED_FILE}" ]]; then
  echo "Meta DAT Package.resolved was not produced; run swift package resolve in Adapters/MetaDAT first." >&2
  exit 1
fi

/usr/bin/python3 - "${RESOLVED_FILE}" "${EXPECTED_REVISION}" <<'PY'
import json
import pathlib
import sys

resolved_path = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
payload = json.loads(resolved_path.read_text())
pins = payload.get("pins", [])

pin = next(
    (
        candidate
        for candidate in pins
        if candidate.get("identity") == "meta-wearables-dat-ios"
        or candidate.get("package") == "meta-wearables-dat-ios"
    ),
    None,
)

if pin is None:
    raise SystemExit("Meta DAT pin is missing from Package.resolved")

actual = pin.get("state", {}).get("revision")
if actual != expected:
    raise SystemExit(
        f"Meta DAT resolved revision drifted: expected {expected}, found {actual}"
    )

print(f"Verified Meta DAT resolved revision: {actual}")
PY

if ! grep -Fq "revision: ${EXPECTED_REVISION}" "${TEST_APP_SPEC}"; then
  echo "Meta DAT TestApp revision does not match ${EXPECTED_REVISION}" >&2
  exit 1
fi

echo "Verified Meta DAT TestApp revision: ${EXPECTED_REVISION}"
