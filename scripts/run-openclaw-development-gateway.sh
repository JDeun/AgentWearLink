#!/usr/bin/env bash
# Development-only REAL Gateway proof; never connects to Mac mini/Tailnet.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/dev_gateway_preflight.py
export AWL_OPENCLAW_EXPOSURE=loopback

# The process runner caps stuck network/Swift child lifetimes, suppresses
# untrusted response and error text, and returns stable exit statuses.
echo "Running production read-only OpenClaw connection and health RPC"
python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe

# A separate process with the same read-only Keychain service exercises a
# fresh handshake. This is a reconnect smoke check, NOT proof that a device
# grant was persisted or accepted without primary token authentication.
echo "Reconnecting production read-only OpenClaw health RPC"
python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe

echo "Running production native adapter with explicit harmless agent turn"
export AWL_ALLOW_MUTATING_PROBE=1
export AWL_DEV_GATEWAY_ASSERT=1
# The marker is synthetic and contains no user/private data. No tools requested.
export AWL_OPENCLAW_CHAT_MESSAGE="AWL isolated integration check: reply with one short sentence."
python3 scripts/dev_gateway_probe_runner.py awl-openclaw-chat-probe

echo "Real development Gateway health, reconnect, agent delta and terminal checks passed."
echo "Next: prove abort, pairing grant reuse and interruption cleanup before closing #331."
