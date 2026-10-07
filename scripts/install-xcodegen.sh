#!/bin/bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_BOTTLE_REBUILD="1"
XCODEGEN_FORMULA_SHA256="10ad1aeee58bcef59ae74dd83652f4cefdce36413a3660650cb1b94a229c330a"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${XCODEGEN_INSTALL_DIR:-${ROOT_DIR}/.build/tools}"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install the repository-pinned XcodeGen bottle." >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"

metadata="$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 xcodegen)"

METADATA="${metadata}" /usr/bin/python3 <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["METADATA"])
formulae = payload.get("formulae", [])
if len(formulae) != 1:
    raise SystemExit("Expected exactly one xcodegen formula in Homebrew metadata")

formula = formulae[0]
expected_version = "2.46.0"
expected_rebuild = 1
expected_formula_sha256 = "10ad1aeee58bcef59ae74dd83652f4cefdce36413a3660650cb1b94a229c330a"
expected_bottles = {
    "arm64_golden_gate": "cc5980a1ffd679edf00e4204473b1cfa8c3abcce69c22c084d4d079b277e248b",
    "arm64_tahoe": "69a3584c1c9118cd37e45565b8679e1c84663e783e720c68e85ef6000a52c870",
    "arm64_sequoia": "0f06608766b94ca4ca5eb380ff38abfa908015f05c7f0eef41f22ac2a97c4288",
    "arm64_sonoma": "e23b1e8501ad0276d810f41d195ad30787e55634e845c039d4ce015491455dba",
    "sonoma": "d0e021076a96894c2d48a51003e99ab4885130f69ea922a67de8bef3062c5a50",
}

if formula.get("versions", {}).get("stable") != expected_version:
    raise SystemExit(
        f"XcodeGen stable version drifted: expected {expected_version}, "
        f"found {formula.get('versions', {}).get('stable')}"
    )

stable_bottle = formula.get("bottle", {}).get("stable", {})
if stable_bottle.get("rebuild") != expected_rebuild:
    raise SystemExit(
        f"XcodeGen bottle rebuild drifted: expected {expected_rebuild}, "
        f"found {stable_bottle.get('rebuild')}"
    )

formula_sha = formula.get("ruby_source_checksum", {}).get("sha256")
if formula_sha != expected_formula_sha256:
    raise SystemExit(
        f"XcodeGen formula checksum drifted: expected {expected_formula_sha256}, "
        f"found {formula_sha}"
    )

files = stable_bottle.get("files", {})
for tag, expected_sha in expected_bottles.items():
    actual_sha = files.get(tag, {}).get("sha256")
    if actual_sha != expected_sha:
        raise SystemExit(
            f"XcodeGen bottle checksum drifted for {tag}: "
            f"expected {expected_sha}, found {actual_sha}"
        )

print(
    "Verified Homebrew XcodeGen metadata: "
    f"{expected_version}, bottle rebuild {expected_rebuild}"
)
PY

existing="${INSTALL_DIR}/xcodegen"
if [[ -x "${existing}" ]] && "${existing}" --version 2>&1 | grep -Fq "${XCODEGEN_VERSION}"; then
  echo "Using pinned XcodeGen ${XCODEGEN_VERSION}: ${existing}"
  "${existing}" --version
  exit 0
fi

export HOMEBREW_NO_AUTO_UPDATE=1
brew install xcodegen

installed_version="$(xcodegen --version 2>&1)"
if ! grep -Fq "${XCODEGEN_VERSION}" <<<"${installed_version}"; then
  echo "Installed XcodeGen version does not match pin ${XCODEGEN_VERSION}: ${installed_version}" >&2
  exit 1
fi

brew_prefix="$(brew --prefix xcodegen)"
ln -sf "${brew_prefix}/bin/xcodegen" "${existing}"

echo "Installed pinned Homebrew XcodeGen ${XCODEGEN_VERSION}: ${existing}"
"${existing}" --version
