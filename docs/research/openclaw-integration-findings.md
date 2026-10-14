# OpenClaw integration findings

**Gateway behaviour learned on a real private deployment (OpenClaw 2026.9.6, protocol v4, reached over Tailscale Serve).**

[Research notes](README.md) · [OpenClaw adapter](../openclaw.md)

## Turn lifecycle

| Finding | Label |
| --- | --- |
| `agent.wait` asks the gateway to hold for `timeoutMs`. If the client's RPC deadline equals that hold, replies that arrive at the boundary lose the race on a real network. An iPhone over Tailnet failed with `deadlineExceeded` at exactly t+30 s, while 34 s and 50 s turns succeeded over loopback. Fixed by giving `agent.wait` a client deadline of `timeoutMs` + 15 s. | Observed here; fix in #622 |
| The `agent` request accepts `deliver`, `channel`, `to`, `accountId`, `extraSystemPrompt`, `promptMode`, `bootstrapContextMode` and `inputProvenance`. Of these, only the `/reset` path needs `operator.admin`. Delivery, `extraSystemPrompt` and `external_user` provenance work with `operator.write`. | Verified: gateway 2026.9.6 schema and handler source; #623 |
| A turn sent into an existing channel session shares that session's context but does **not** post to the channel. Set `deliver: true` with a channel target for the reply to appear there. | Observed here |
| `inputProvenance: {kind: "external_user", sourceChannel: "<host>"}` reaches plugin hooks as `ctx.inputProvenance`. A plugin can then tell a spoken turn from a typed one, for example to mirror the user's words into their chat. | Verified: gateway source (hook context); #623 |
| `agent.identity.get` (`operator.read`) returns the agent's display name and avatar (for example an emoji), resolved from config or the workspace identity file. | Verified: live gateway call; #625 |

## Pairing and reconnect

| Finding | Label |
| --- | --- |
| The first connect with the shared token creates a pending pairing request. After `openclaw devices approve <requestId>`, a device grant stored in the Keychain allows tokenless reconnects. | Observed here (iPhone over Tailnet) |
| Gateway 2026.9.6 is wire-compatible with the pinned contract, as long as the verifier doesn't require `discardPendingInput` on `chat.abort`. | Verified; #616 |

## Latency (generic observations)

| Finding | Label |
| --- | --- |
| On a Codex-backed agent, each channel turn started a new model thread. That meant no prompt-cache reuse plus 2–5 s of thread startup, which dominated over prompt size (about 27k input tokens). A trivial one-call turn took about 3.5 s. A three-call turn took about 12.5 s end to end. | Observed here (one deployment, read-only analysis) |
| Activity recaps run **after** the reply and don't delay it. | Observed here |
| The voice path benefits from a per-turn `extraSystemPrompt` that asks for 2–3 spoken sentences with no markdown or links. | Design choice; #624 |
