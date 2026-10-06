# OpenClaw Gateway Integration Probe

The repository includes `awl-openclaw-probe`, a minimal read-only smoke test for the native Gateway WebSocket path.

It validates:

1. WebSocket reachability.
2. `connect.challenge`.
3. persistent AWL device identity.
4. challenge-bound device proof.
5. Gateway authentication and pairing state.
6. `hello-ok` protocol/policy negotiation.
7. the long-lived dispatcher path.
8. a read-only `health` RPC.

It does **not** submit an agent run, invoke tools, mutate sessions, or write secrets to source control.

## Recommended Mac mini + iPhone/Tailscale topology

For the owner's reference deployment, prefer:

```text
client
  -> Tailscale
  -> wss://<Mac-mini-MagicDNS>.ts.net
  -> Tailscale Serve
  -> OpenClaw bound to loopback :18789
```

Direct private-tailnet `ws://100.x.y.z:18789` can be useful for diagnostics, but WSS through Tailscale Serve is the preferred reference path.

## Environment

Set the Gateway URL:

```bash
export AWL_OPENCLAW_URL='wss://<mac-mini>.ts.net'
```

If the Gateway uses shared-token auth:

```bash
read -s AWL_OPENCLAW_TOKEN
export AWL_OPENCLAW_TOKEN
```

For bootstrap-token flows, use `AWL_OPENCLAW_BOOTSTRAP_TOKEN` instead.

Do not place either token in shell scripts committed to Git, command-line arguments, screenshots, issue bodies, or test fixtures.

## Run

From the repository root:

```bash
swift run awl-openclaw-probe
```

On success the probe prints the Gateway health JSON.

## First-device pairing

A new device may receive `PAIRING_REQUIRED`. The probe prints the exact request ID and an approval command of the form:

```bash
openclaw devices approve <requestId>
```

Run that command on the Mac mini that owns the Gateway, then run the probe again.

The persistent Ed25519 identity and the issued device credential are stored in the platform Keychain under the probe-specific service namespace. They are not written to repository files.

## Expected failures

- invalid URL: configuration error before connection;
- unreachable Tailnet/Gateway: transport failure;
- pairing required: explicit exit with the pairing request ID;
- terminal authentication failure: no reconnect spin;
- liveness timeout: the connection is retired and reconnected, but an uncertain application RPC is never replayed.

## Before P0-B is declared complete

The probe is only a transport/authentication gate. P0-B additionally requires the real AWL `AgentAdapter` path to submit a text interaction to the owner's existing OpenClaw session and receive incremental output over the intended Tailnet.
