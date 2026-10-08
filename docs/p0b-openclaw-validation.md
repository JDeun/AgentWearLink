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

## CLI output privacy boundary

The read-only health probe emits only a fixed `{"ok":true}` success marker;
upstream health JSON is deliberately not echoed to stdout because its fields
may expand to include local configuration. Probe error messages do not print
arbitrary upstream error/reason strings. The mutating chat probe intentionally
prints generated model text when explicitly invoked; treat its stdout as private
session content and avoid storing it in CI logs or shared artifacts. The
development-Gateway smoke harness redirects chat output to `/dev/null`.

## iPhone-only private Gateway health preflight

The reference iOS host exposes **Check Gateway health (read-only, no glasses)**
to verify an actual iPhone → Tailscale Serve HTTPS/WSS path before preparing
Meta registration or connecting physical eyewear. Enter the private
`<mac-mini>.ts.net` hostname and a development Gateway token, and tap the
read-only button. The token input is cleared immediately and is not exported.

This path composes the real production `URLSessionOpenClawWebSocket`,
`OpenClawGatewayConnection`, `OpenClawRPCDispatcher` and
`OpenClawGatewaySupervisor`, with `operator.read` only, a separate Keychain
identity and `OpenClawGatewayClientIdentity.probe`. It sends just the
`health` RPC, checks the boolean `ok`, then tears down the Gateway
transport. It never opens a Meta `DeviceSession`, sends an agent turn,
or prints upstream health content.

States: `gateway-health-ok` means the read-only health RPC succeeded;
`gateway-health-pairing-required` means the new iPhone-only validation
identity needs explicit administrative approval before retry;
`gateway-health-invalid-private-endpoint` means the private endpoint
policy rejected the hostname; other failures remain redacted.

This validates only private transport, authentication and health. A
write-authorized, separately paired native reference runtime and existing
OpenClaw session still require the next P0-B text/agent checks. Neither a
health check nor simulator success proves real glasses audio or camera.
