# Real development OpenClaw Gateway integration (Layer 2)

This opt-in harness runs AWL's **production** Gateway connection, RPC
dispatcher, supervisor, run client and native agent adapter against a real
OpenClaw Gateway. It is not a synthetic WebSocket fixture and is not the
physical iPhone/Tailscale deployment gate (#56/#97).

## Isolation and prerequisites

- Launch a **separate development OpenClaw Gateway** on local loopback
  with its own profile/config directory, token, sessions, model/tools and data.
  Do **not** reuse the owner's Mac mini Gateway, credentials, sessions, or Tailnet.
- Pin the actual Gateway checkout/version. Record the 40-character source commit
  and check it against `docs/openclaw-protocol-contract.md`. The harness records
  the declared revision; it cannot attest to the running process's binary.
- Provide a harmless/isolated agent model that can emit assistant text, without
  destructive tools. Configure explicit read-only and mutating device pairing
  on the development Gateway if required.
- A macOS host with Swift, Python 3 and the OpenClaw development Gateway
  already running is needed. This script does **not** install or start OpenClaw.

```bash
export AWL_ALLOW_DEV_GATEWAY_TEST=1
export AWL_OPENCLAW_URL=ws://127.0.0.1:18789
export AWL_OPENCLAW_EXPOSURE=loopback
export AWL_OPENCLAW_TOKEN='<development-only-token>'
export AWL_OPENCLAW_SESSION_KEY='agent:main:awl-dev-isolated'
export AWL_DEV_GATEWAY_REVISION='<exact 40-character source commit>'
bash scripts/run-openclaw-development-gateway.sh
```

The validator rejects non-loopback endpoints (including Tailscale), any
session key outside the dedicated `agent:<id>:awl-dev-<name>` namespace,
embedded URL credentials, bootstrap handoff tokens, missing explicit opt-in
and unpinned revision declarations. This is a guard against accidentally
targeting an existing personal session; a session prefix **cannot attest**
that the Gateway process/configuration itself is isolated. Confirm the
running process, profile directory, token and model/tools are development-only.
Only the script generates the harmless test message.

## What passing means

1. The read-only production probe completes connect/auth + `health` RPC.
2. The mutating production adapter submits one harmless agent request.
3. At least one incremental assistant text delta arrives and exactly one
   terminal completion is observed before stream close.
4. The harness exits nonzero for missing deltas or terminal events.

The read-only and mutating validation identities are separate and may need
separate local pairing. Their Keychain services remain distinct; the Gateway
endpoint credential namespace also isolates local and Tailnet endpoints.
No token, response text or private media is collected as an artifact.

## Still required before #331 is complete

A passing harness invocation with sanitized evidence and exact actual Gateway
revision, plus automated or repeatable isolated tests for pairing/reconnect
credential reuse, abort/cancellation, event ordering, terminal reconciliation
and cleanup. Until then this is the first **real Gateway smoke-test path**, not
full integration acceptance. CI runs only preflight unit tests and shell syntax
checks without needing a live Gateway.
