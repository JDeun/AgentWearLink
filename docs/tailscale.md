# Tailscale deployment profile

Tailscale is a deployment option, not an AgentWearLink core dependency.

## Recommended personal topology

```text
Ray-Ban Meta
    │
    ▼
iPhone / AgentWearLink
    │
    │ Tailscale tailnet
    ▼
Tailscale Serve (HTTPS/WSS)
    │
    ▼
Mac mini loopback
    │
    ▼
OpenClaw Gateway :18789
```

## Preferred profile: Tailscale Serve

Keep the OpenClaw Gateway bound to loopback and let OpenClaw/Tailscale Serve expose a private tailnet-only HTTPS/WSS endpoint.

Conceptual OpenClaw configuration:

```json5
{
  gateway: {
    bind: "loopback",
    tailscale: { mode: "serve" }
  }
}
```

The iPhone client then uses the stable MagicDNS HTTPS/WSS hostname instead of a raw LAN address.

Advantages:

- Gateway port is not exposed on the LAN.
- TLS is terminated by Tailscale Serve.
- Stable MagicDNS hostname survives ordinary network changes.
- The phone can move between Wi-Fi and cellular while remaining on the tailnet.
- No public Funnel is required.

## Alternative: direct Tailnet bind

OpenClaw can bind directly to the Tailnet interface and accept a connection such as:

```text
ws://<tailscale-ip>:18789
```

This is private to the tailnet but is a plain WebSocket transport. AWL supports this as an explicit deployment mode, but Serve/WSS is preferred when practical.

## Authentication

Tailnet reachability is not a replacement for application authorization.

AWL must support the OpenClaw authentication required by the selected Gateway path. Reusable secrets belong in iOS Keychain, never repository configuration.

Tailscale Serve identity-header authentication has path-specific semantics in OpenClaw. Do not assume it authenticates every HTTP API, node connection, or arbitrary reverse-proxy request.

## Reconnect behavior

Mobile network transitions are normal:

- Wi-Fi → cellular
- cellular → Wi-Fi
- Tailscale tunnel re-establishment
- Mac mini sleep/restart
- OpenClaw Gateway restart

The client must distinguish:

1. transport disconnected,
2. transport reconnecting,
3. Gateway connected but not authenticated,
4. authenticated and ready.

A request whose delivery/completion is uncertain must not be silently replayed after reconnect.

## Endpoint abstraction

AWL treats Tailscale as an endpoint/exposure profile. Core code does not import or depend on a Tailscale SDK.

Supported deployment categories:

- loopback/development
- direct Tailnet bind
- Tailscale Serve
- private reverse proxy

This keeps the OpenClaw adapter reusable for users who do not use Tailscale.
