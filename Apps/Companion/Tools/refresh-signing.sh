#!/bin/bash
# Keep a free-account (7-day) development build alive: when the installed
# build's provisioning profile is close to expiry, rebuild with a renewed
# profile and reinstall it on the paired iPhone (cable or "Connect via
# network"). Needs the Apple ID signed in to Xcode (Settings › Accounts) so
# -allowProvisioningUpdates can issue a new profile.
#
#   Apps/Companion/Tools/refresh-signing.sh [--days 2] [--force]
#
# Exit codes: 0 nothing to do or refreshed, 2 no device reachable,
# 3 build/sign failed (often: Xcode not signed in), 4 install failed.
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
days=2 force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days="$2"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived="${AWL_DERIVED_DATA:-$here/.build/device}"

expiry_epoch() {
  local app profile
  app="$(ls -d "$derived"/Build/Products/Debug-iphoneos/*.app 2>/dev/null | head -1)"
  profile="$app/embedded.mobileprovision"
  [ -f "$profile" ] || { echo 0; return; }
  security cms -D -i "$profile" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null \
    | python3 -c 'import sys,datetime; s=sys.stdin.read().strip(); print(int(datetime.datetime.fromisoformat(s.replace("Z","+00:00")).timestamp()) if s else 0)'
}

now=$(date +%s)
expires=$(expiry_epoch)
left=$(( (expires - now) / 3600 ))
echo "signing: ${left} h left"
if [ "$force" = 0 ] && [ "$expires" -gt $(( now + days * 86400 )) ]; then
  exit 0
fi

if ! "$here/Tools/install-and-pair.sh" --no-pair >/tmp/awl-refresh-$$.log 2>&1; then
  if grep -qiE "No Accounts|no signing certificate|requires a provisioning profile|Signing for .* requires a development team" /tmp/awl-refresh-$$.log; then
    echo "build/sign failed: sign in to Xcode (Settings › Accounts) with the Apple ID" >&2; rm -f /tmp/awl-refresh-$$.log; exit 3
  fi
  if grep -qi "no connected iPhone" /tmp/awl-refresh-$$.log; then
    echo "no iPhone reachable (cable, or Xcode › Devices › Connect via network)" >&2; rm -f /tmp/awl-refresh-$$.log; exit 2
  fi
  tail -n 5 /tmp/awl-refresh-$$.log | grep -v -i token >&2; rm -f /tmp/awl-refresh-$$.log; exit 4
fi
rm -f /tmp/awl-refresh-$$.log
new=$(expiry_epoch)
echo "refreshed: $(( (new - now) / 3600 )) h left"
[ "$new" -gt "$expires" ] || { echo "profile was not renewed" >&2; exit 3; }
