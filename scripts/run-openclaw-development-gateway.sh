#!/usr/bin/env bash
# Development-only REAL Gateway proof; never connects to Mac mini/Tailnet.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

python3 scripts/dev_gateway_preflight.py
export AWL_OPENCLAW_EXPOSURE=loopback

if [[ "${AWL_DEV_GATEWAY_EXPECT_AGENT_ABORT:-0}" == "1" ]]; then
  # Held Responses provider. An already-accepted run MUST enter the actual
  # pinned model before chat.abort is considered remotely confirmed.
  export AWL_ALLOW_MUTATING_PROBE=1
  export AWL_DEV_GATEWAY_ASSERT=1
  export AWL_DEV_GATEWAY_ABORT_ASSERT=1
  export AWL_OPENCLAW_CHAT_MESSAGE="AWL isolated integration check: reply with one short sentence."
  echo "Checking confirmed abort of already-executing real Gateway agent"
  python3 scripts/dev_gateway_probe_runner.py awl-openclaw-chat-probe
  exit $?
fi

if [[ "${AWL_DEV_GATEWAY_EXPECT_AGENT_STREAM:-0}" == "1" ]]; then
  # A real upstream Gateway handles the production native-agent adapter,
  # backed ONLY by its synthetic localhost OpenAI Responses test server.
  # CI must use the separately verified prebuilt Swift chat executable.
  export AWL_ALLOW_MUTATING_PROBE=1
  export AWL_DEV_GATEWAY_ASSERT=1
  export AWL_OPENCLAW_CHAT_MESSAGE="AWL isolated integration check: reply with one short sentence."
  echo "Checking real native-agent deltas and terminal completion with synthetic model"
  python3 scripts/dev_gateway_probe_runner.py awl-openclaw-chat-probe
  exit $?
fi

if [[ "${AWL_DEV_GATEWAY_EXPECT_PAIRING:-0}" == "1" ]]; then
  # Exactly one freshly generated, unapproved identity. No permission grant
  # or follow-up health probe is attempted in this negative contract.
  echo "Checking that the real Gateway refuses an unapproved read-only identity"
  python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe
  exit $?
fi

if [[ "${AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT:-0}" == "1" ]]; then
  # The Python parent runs this branch TWICE with a fresh Swift process.
  # It removes AWL_OPENCLAW_TOKEN entirely from the second environment.
  echo "Checking disposable server-issued grant through real Gateway"
  python3 scripts/dev_gateway_probe_runner.py awl-openclaw-probe
  exit $?
fi

if [[ "${AWL_DEV_GATEWAY_EXPECT_HEALTH_OK:-0}" == "1" ]]; then
  # Separate synthetic auto-approved localhost Gateway only. A passing probe
  # proves hello-ok + health, not Keychain grant persistence or reconnect.
  echo "Checking isolated real Gateway authenticated read-only health"
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
