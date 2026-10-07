# OpenClaw mutating text probe

`awl-openclaw-chat-probe` is an **explicitly mutating** P0-B validation tool.
Unlike `awl-openclaw-probe`, it submits a real agent run to the configured
OpenClaw session.

It refuses to run unless `AWL_ALLOW_MUTATING_PROBE=1` is set.

Required:

- `AWL_OPENCLAW_URL`
- `AWL_OPENCLAW_CHAT_MESSAGE`
- `AWL_ALLOW_MUTATING_PROBE=1`
- `AWL_OPENCLAW_EXPOSURE` for every non-loopback Gateway URL

Supported exposure values are `tailnet-direct`, `tailnet-serve`, and `private-reverse-proxy`. Loopback URLs may omit the exposure variable.

Optional:

- `AWL_OPENCLAW_SESSION_KEY` to target an existing session
- `AWL_OPENCLAW_TOKEN`
- `AWL_OPENCLAW_BOOTSTRAP_TOKEN`

Example:

    AWL_ALLOW_MUTATING_PROBE=1 \
    AWL_OPENCLAW_URL=wss://<mac-mini>.ts.net \
    AWL_OPENCLAW_EXPOSURE=tailnet-serve \
    AWL_OPENCLAW_SESSION_KEY=<existing-session> \
    AWL_OPENCLAW_CHAT_MESSAGE="Reply with AWL P0-B OK" \
    swift run awl-openclaw-chat-probe

The probe prints incremental assistant text to stdout. It uses a persistent
Keychain-backed device identity/credential store distinct from the read-only
health probe.

## Safety and replay semantics

This tool does not automatically retry a submitted agent interaction after a
transport failure. If the connection becomes uncertain, treat the run as
potentially accepted and inspect OpenClaw before manually submitting again.

Use the read-only `awl-openclaw-probe` first for reachability, pairing, and
health checks.
