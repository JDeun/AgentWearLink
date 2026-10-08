#!/usr/bin/env bash
# Development-only REAL Gateway proof; never connects to Mac mini/Tailnet.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/dev_gateway_preflight.py
export AWL_OPENCLAW_EXPOSURE=loopback

echo "Running production read-only OpenClaw connection and health RPC"
swift run --quiet awl-openclaw-probe >/dev/null

echo "Running production native adapter with explicit harmless agent turn"
export AWL_ALLOW_MUTATING_PROBE=1
export AWL_DEV_GATEWAY_ASSERT=1
# The marker is synthetic and contains no user/private data. No tools requested.
export AWL_OPENCLAW_CHAT_MESSAGE="AWL isolated integration check: reply with one short sentence."
swift run --quiet awl-openclaw-chat-probe >/dev/null

# Explicit additional real-Gateway proof. A slow, isolated development model
# must keep the run active until chat.abort; an already-completed run cannot
# count as confirmed remote cancellation. Never re-use production sessions.
if [[ "${AWL_DEV_GATEWAY_PROVE_ABORT:-0}" == "1" ]]; then
  echo "Running isolated development Gateway accepted-run abort proof"
  AWL_DEV_GATEWAY_ABORT_ASSERT=1 swift run --quiet awl-openclaw-chat-probe >/dev/null
  echo "Real development Gateway chat.abort accepted-run confirmation passed."
fi

echo "Real development Gateway health + agent delta + terminal checks passed."
echo "Next: prove abort, recover, pairing and persistent identity in a dedicated integration runner before closing #331."
