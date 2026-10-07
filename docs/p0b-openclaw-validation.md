# P0-B iPhone → Tailnet → OpenClaw validation runbook

This runbook closes issue #56. It validates the intended deployment rather than only localhost behavior.

## Preconditions

- OpenClaw is running on the Mac mini.
- The iPhone and Mac mini are on the same Tailnet.
- The Gateway is exposed through the intended private WSS/Tailscale Serve path.
- `awl-openclaw-probe` succeeds before any mutating test.
- The read-only and mutating probes intentionally use **different validation device identities**.
- Pairing/authorization is approved separately for each validation identity when first used.
- The target OpenClaw session is known if session continuity is part of the test.

## Evidence record

Record:

- AgentWearLink commit
- iOS/macOS versions
- OpenClaw version
- endpoint topology category: Tailscale Serve / private reverse proxy / direct Tailnet
- authentication mode, but never the token itself
- which validation identity produced the evidence: read-only probe or mutating chat probe
- the pairing request/approval record for each identity, kept separate
- target session key in redacted or non-sensitive form if needed
- timestamps and sanitized terminal output

## Sequence

### 1. Read-only health

Run the read-only probe first. Confirm:

- WebSocket reachability
- `connect.challenge`
- persistent **read-only validation** device identity
- authenticated `hello-ok`
- read-only health RPC

This pairing authorizes only the read-only validation profile. It is not evidence
that the mutating chat profile has been paired or approved.

### 2. Real text interaction

Run `awl-openclaw-chat-probe` with explicit mutation opt-in and a unique harmless marker, for example `AWL-P0B-<timestamp>`.

On the first run, expect a **second pairing request** for the distinct mutating
validation identity. Approve that request explicitly before retrying. Do not
treat the read-only probe's approval as authorization for mutation.

Confirm:

- the mutating validation identity is separately paired/authorized
- a fresh reconnect reuses that same mutating identity and persisted grant
- request reaches the intended existing OpenClaw runtime/session
- incremental assistant text is observed
- completion is terminal exactly once
- model/tool/memory ownership remains OpenClaw's
- Telegram is not required for request transport

### 3. Session continuity

When using an existing session, verify that the interaction appears in that session rather than a parallel AWL-owned conversation.

### 4. Uncertain delivery test

Start a harmless interaction and interrupt the network/Gateway after submission.

Confirm:

- AWL does not silently submit the same mutating request again
- recovery establishes a fresh authenticated transport
- the operator can inspect whether the original run was accepted before manually retrying

Do not use a request that invokes destructive tools for this test.

### 5. Tailnet transition

Repeat a harmless interaction around the intended iPhone network transition (for example Wi-Fi to cellular while Tailscale remains the private path). Record whether reconnect and re-authentication behave as expected.

## Exit criteria for #56

- read-only probe succeeds over the intended Tailnet topology
- read-only and mutating validation identities have separate pairing evidence
- the mutating identity demonstrates persisted credential reuse on reconnect
- real text request succeeds through the production OpenClaw adapter
- incremental response is observed
- existing OpenClaw session semantics are preserved
- no Telegram dependency exists
- uncertain requests are not silently replayed
- sanitized evidence and exact versions/topology are attached to #56
