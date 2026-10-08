#!/usr/bin/env bash
# Development-only REAL Gateway proof; never connects to Mac mini/Tailnet.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/dev_gateway_preflight.py
export AWL_OPENCLAW_EXPOSURE=loopback

if [[ "${AWL_DEV_GATEWAY_EXPECT_PAIRING:-0}" == "1" ]]; then
  # Exactly one freshly generated, unapproved identity. No permission grant
  # or follow-up health probe is attempted in this negative contract.
  echo "Checking that the real Gateway refuses an unapproved read-only identity"
  python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe
  exit $?
fi

echo "Running production read-only OpenClaw connection and health RPC"
python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe

# A new Swift process is forbidden from reusing the shared Gateway
# bearer token. Only the server-approved, endpoint-scoped Keychain device
# token (persisted from the first successful hello-ok) may authenticate.
# Missing/readonly-grant-drift/revoked credentials must fail closed.
echo "Reconnecting via server-approved read-only device token (no shared bearer)"
AWL_DEV_GATEWAY_RECONNECT_STORED_ONLY=1 python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe

if [[ "${AWL_DEV_GATEWAY_HEALTH_ONLY:-0}" == "1" ]]; then
  echo "Authenticated real Gateway health and fresh-process reconnect passed."
  echo "Mutating agent, cancellation, pairing/revocation and physical evidence remain separate."
  exit 0
fi

echo "Running production native adapter with explicit harmless agent turn"
export AWL_ALLOW_MUTATING_PROBE=1
export AWL_DEV_GATEWAY_ASSERT=1
# The marker is synthetic and contains no user/private data. No tools requested.
export AWL_OPENCLAW_CHAT_MESSAGE="AWL isolated integration check: reply with one short sentence."
python3 scripts/dev_gateway_probe_runner.py awl-openclaw-chat-probe

# Explicit additional real-Gateway proof. A slow, isolated development model
# must keep the run active until chat.abort; an already-completed run cannot
# count as confirmed remote cancellation. Never re-use production sessions.
if [[ "${AWL_DEV_GATEWAY_PROVE_ABORT:-0}" == "1" ]]; then
  echo "Running isolated development Gateway accepted-run abort proof"
  AWL_DEV_GATEWAY_ABORT_ASSERT=1 python3 scripts/dev_gateway_probe_runner.py awl-openclaw-chat-probe
  echo "Real development Gateway chat.abort accepted-run confirmation passed."
fi

echo "Real development Gateway health, reconnect, agent delta and terminal checks passed."
echo "Still required for #331: native-adapter cancellation, tokenless credential reuse, pairing and persistent identity proof."
