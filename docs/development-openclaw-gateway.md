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
2. A second **independent Swift process** connects with the same read-only
   Keychain namespace and repeats `health`. This exercises a fresh handshake,
   but does **not** prove persistent device-grant reuse: the configured
   token may still authenticate both connections.
3. The mutating production adapter submits one harmless agent request.
4. At least one incremental assistant text delta arrives and exactly one
   terminal completion is observed before stream close.
5. The harness exits nonzero for missing deltas or terminal events.

Every Swift command, including the optional abort probe below, has a
300-second **process deadline** (including first-time Swift compilation).
On timeout/interruption, the wrapper terminates the Swift process group;
probe stdout/stderr is suppressed so untrusted Gateway replies, credentials
and SDK error strings never enter shell or CI logs. Only stable result codes
and redacted diagnostics are surfaced. Pairing approval must be inspected
on the **isolated development Gateway**, not copied from probe output.
CI tests only the wrapper and shell syntax without a live Gateway.

The read-only and mutating validation identities are separate and may need
separate local pairing. Their Keychain services remain distinct; the Gateway
endpoint credential namespace also isolates local and Tailnet endpoints.
No token, response text or private media is collected as an artifact.

## Optional accepted-run abort proof (isolated dev Gateway only)

The default smoke test above deliberately does not issue remote aborts. For a
separate explicit cancellation check, configure the isolated development
Gateway with a **harmless, deliberately slow** test model/agent that keeps an
accepted run alive long enough to abort. Then run:

```bash
export AWL_DEV_GATEWAY_PROVE_ABORT=1
bash scripts/run-openclaw-development-gateway.sh
```

The runner first repeats the existing health and assistant delta/terminal
checks. It then uses the **production** OpenClaw agent run client and RPC
dispatcher to submit a second harmless message under the dedicated
`agent:<id>:awl-dev-<name>` session, verifies the Gateway-accepted session
identity, sends `chat.abort` against that specific accepted run ID, and
requires the Gateway's positive abort confirmation. A model that finishes too
quickly for abort produces a **failed proof**, not an invented success. The
command only emits static success/failure diagnostics, never model output,
credentials, run IDs or session contents.

This covers a real Gateway cancellation RPC, **not** a complete end-to-end
`OpenClawNativeAgentAdapter.cancellationOutcome()`/reconnect/credential reuse
matrix. The latter still requires isolated evidence under #331. The feature
must not be run against the owner's personal Mac mini Gateway or Tailnet.

## Still required before #331 is complete

A passing harness invocation with sanitized evidence and exact actual Gateway
revision, plus automated or repeatable isolated tests for pairing/reconnect
**credential reuse rather than token-backed reconnection**,
full native adapter cancellation, event ordering, terminal reconciliation
and cleanup. Until then this is the first **real Gateway smoke-test path**, not
full integration acceptance. CI runs only preflight/process-runner unit tests and shell syntax
checks without needing a live Gateway.
