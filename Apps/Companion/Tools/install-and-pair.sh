#!/bin/bash
# Build, install and pair the companion app over USB in one step.
#
# Run on the computer that hosts the OpenClaw Gateway, with the iPhone
# connected by cable (or paired for wireless debugging). The app receives a
# one-time setup code as a launch argument, so no QR scan or paste is needed.
#
#   Apps/Companion/Tools/install-and-pair.sh --url wss://<host>.ts.net:8443 [--device <udid>] [--skip-build]
#     [--session-key <agent session key>] [--telegram-chat-id <id>]
#     [--voice-stream-url https://<host>.ts.net:8445 --voice-stream-key-file ~/.openclaw/tts/alfred/client-key]
#
# --session-key makes glasses turns join an existing conversation (for example
# the Telegram DM session) instead of a new one per turn; --telegram-chat-id
# also posts replies to that chat. Both are saved in the app. --no-pair skips
# the setup code (the app is already paired; update or settings only).
# --voice-stream-url / --voice-stream-key-file hand the app the streaming
# voice (the local TTS on the tailnet). The key is read from the file here and
# passed as a launch argument; it is never printed, and launch output is
# hidden while it is passed. The app keeps both in its Keychain.
#
# The setup code is never printed. Approve the device afterwards with
# `openclaw devices approve` after checking its fingerprint.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
url="" device="" build=1 pair=1 session_key="" chat_id="" voice_url="" voice_key_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --url) url="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --skip-build) build=0; shift ;;
    --no-pair) pair=0; shift ;;
    --session-key) session_key="$2"; shift 2 ;;
    --telegram-chat-id) chat_id="$2"; shift 2 ;;
    --voice-stream-url) voice_url="$2"; shift 2 ;;
    --voice-stream-key-file) voice_key_file="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ "$pair" = 0 ] || [ -n "$url" ] || { echo "--url wss://<gateway-host>:<port> is required" >&2; exit 2; }
if [ -n "$voice_url" ] || [ -n "$voice_key_file" ]; then
  [ -n "$voice_url" ] && [ -n "$voice_key_file" ] || { echo "--voice-stream-url and --voice-stream-key-file go together" >&2; exit 2; }
  case "$voice_url" in https://*) ;; *) echo "--voice-stream-url must be https://" >&2; exit 2 ;; esac
  [ -r "$voice_key_file" ] || { echo "cannot read the voice stream key file" >&2; exit 2; }
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
derived="${AWL_DERIVED_DATA:-$here/.build/device}"

if [ -z "$device" ]; then
  list="$(mktemp)"
  xcrun devicectl list devices --json-output "$list" >/dev/null 2>&1 || true
  device="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for x in d.get("result",{}).get("devices",[]):
    if x.get("hardwareProperties",{}).get("reality")=="physical" and x.get("connectionProperties",{}).get("tunnelState")=="connected":
        print(x["hardwareProperties"]["udid"]); break' "$list" 2>/dev/null || true)"
  rm -f "$list"
  [ -n "$device" ] || { echo "no connected iPhone found (xcrun devicectl list devices)" >&2; exit 1; }
fi

cd "$here"
if [ "$build" = 1 ]; then
  ../../.build/tools/xcodegen generate --spec project.yml --quiet
  xcodebuild -project AgentWearLinkCompanion.xcodeproj -scheme AgentWearLinkCompanion \
    -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$derived" \
    -allowProvisioningUpdates build -quiet
fi
app="$(ls -d "$derived"/Build/Products/Debug-iphoneos/*.app | head -1)"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"

xcrun devicectl device install app --device "$device" "$app" >/dev/null
echo "installed $bundle"

extra=()
[ -n "$session_key" ] && extra+=(-AWLSessionKey "$session_key")
[ -n "$chat_id" ] && extra+=(-AWLTelegramChatID "$chat_id")
secret_args=0
if [ -n "$voice_url" ]; then
  voice_key="$(tr -d '[:space:]' < "$voice_key_file")"
  [ "${#voice_key}" -ge 32 ] || { unset voice_key; echo "the voice stream key file holds no usable key" >&2; exit 2; }
  extra+=(-AWLVoiceStreamURL "$voice_url" -AWLVoiceStreamKey "$voice_key")
  unset voice_key
  secret_args=1
fi

if [ "$pair" = 0 ]; then
  if [ "$secret_args" = 1 ]; then
    # stderr hidden: devicectl may echo argument values (the voice key).
    if ! xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle" \
        -- ${extra[@]+"${extra[@]}"} >/dev/null 2>&1; then
      extra=()
      echo "launch failed (output hidden because it can contain the voice key)" >&2
      exit 1
    fi
    extra=()
    echo "launched (no pairing) with the streaming voice"
  else
    xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle" \
      -- ${extra[@]+"${extra[@]}"} >/dev/null
    echo "launched (no pairing)"
  fi
  exit 0
fi

# Last line only: `openclaw qr` may print an update-notice box first.
code="$(openclaw qr --limited --setup-code-only --url "$url" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
[ -n "$code" ] || { echo "could not mint a setup code (openclaw qr)" >&2; exit 1; }
# `--` ends devicectl's own options; stderr is dropped because devicectl
# echoes rejected argument values, which would print the one-time code.
if ! xcrun devicectl device process launch --terminate-existing --device "$device" "$bundle" \
    -- -AWLSetupCode "$code" ${extra[@]+"${extra[@]}"} >/dev/null 2>&1; then
  unset code
  extra=()
  echo "launch failed (output hidden because it can contain the setup code); open the app and use QR or paste" >&2
  exit 1
fi
unset code
extra=()
echo "launched with a one-time setup code${voice_url:+ and the streaming voice}; check the fingerprint in the app, then run: openclaw devices list"
