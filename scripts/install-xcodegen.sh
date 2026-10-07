#!/bin/bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${XCODEGEN_INSTALL_DIR:-${ROOT_DIR}/.build/tools}"
ARCHIVE_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"

mkdir -p "${INSTALL_DIR}"

existing="${INSTALL_DIR}/xcodegen"
if [[ -x "${existing}" ]] && "${existing}" --version 2>&1 | grep -Fq "${XCODEGEN_VERSION}"; then
  echo "Using pinned XcodeGen ${XCODEGEN_VERSION}: ${existing}"
  "${existing}" --version
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive="${tmp_dir}/xcodegen.zip"
curl --fail --location --silent --show-error "${ARCHIVE_URL}" --output "${archive}"
printf '%s  %s\n' "${XCODEGEN_SHA256}" "${archive}" | shasum -a 256 -c -

unzip -q "${archive}" -d "${tmp_dir}/unpacked"
binary="$(find "${tmp_dir}/unpacked" -type f -name xcodegen -perm -111 | head -n 1)"
if [[ -z "${binary}" ]]; then
  echo "Pinned XcodeGen archive did not contain an executable xcodegen binary" >&2
  exit 1
fi

install -m 0755 "${binary}" "${existing}"
echo "Installed pinned XcodeGen ${XCODEGEN_VERSION}: ${existing}"
"${existing}" --version
