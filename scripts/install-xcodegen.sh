#!/bin/bash
set -euo pipefail

XCODEGEN_VERSION="2.46.0"
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${XCODEGEN_INSTALL_DIR:-${ROOT_DIR}/.build/tools}"
ARCHIVE_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
DISTRIBUTION_DIR="${INSTALL_DIR}/xcodegen-${XCODEGEN_VERSION}"
BINARY="${DISTRIBUTION_DIR}/bin/xcodegen"
PRESETS_DIR="${DISTRIBUTION_DIR}/share/xcodegen/SettingPresets"
LAUNCHER="${INSTALL_DIR}/xcodegen"

mkdir -p "${INSTALL_DIR}"

if [[ -x "${LAUNCHER}" ]] \
  && [[ -x "${BINARY}" ]] \
  && [[ -d "${PRESETS_DIR}" ]] \
  && "${LAUNCHER}" --version 2>&1 | grep -Fq "${XCODEGEN_VERSION}"; then
  echo "Using pinned XcodeGen ${XCODEGEN_VERSION}: ${DISTRIBUTION_DIR}"
  "${LAUNCHER}" --version
  exit 0
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive="${tmp_dir}/xcodegen.zip"
curl --fail --location --silent --show-error "${ARCHIVE_URL}" --output "${archive}"
printf '%s  %s\n' "${XCODEGEN_SHA256}" "${archive}" | shasum -a 256 -c -

unpack_dir="${tmp_dir}/unpacked"
unzip -q "${archive}" -d "${unpack_dir}"

archive_distribution="${unpack_dir}/xcodegen"
archive_binary="${archive_distribution}/bin/xcodegen"
archive_presets="${archive_distribution}/share/xcodegen/SettingPresets"

if [[ ! -x "${archive_binary}" ]]; then
  echo "Pinned XcodeGen archive did not contain xcodegen/bin/xcodegen" >&2
  exit 1
fi

if [[ ! -d "${archive_presets}" ]]; then
  echo "Pinned XcodeGen archive did not contain share/xcodegen/SettingPresets" >&2
  exit 1
fi

rm -rf "${DISTRIBUTION_DIR}"
cp -R "${archive_distribution}" "${DISTRIBUTION_DIR}"

cat > "${LAUNCHER}" <<EOF
#!/bin/bash
set -euo pipefail
exec "${DISTRIBUTION_DIR}/bin/xcodegen" "\$@"
EOF
chmod 0755 "${LAUNCHER}"

echo "Installed pinned XcodeGen ${XCODEGEN_VERSION}: ${DISTRIBUTION_DIR}"
"${LAUNCHER}" --version
