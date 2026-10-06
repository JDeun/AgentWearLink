# Security Policy

AgentWearLink is currently pre-alpha and has not reached a stable security-support release.

## Sensitive material

Never include the following in public issues, logs, fixtures, or pull requests:

- OpenClaw tokens or bootstrap tokens
- device private keys or persisted device credentials
- Tailscale authentication material
- private wearable camera images
- raw private audio
- personal conversation/session contents

Use synthetic fixtures when reporting bugs.

## Security model

The reference deployment prefers private WSS connectivity through a Tailnet, persistent device identity stored in platform Keychain facilities, minimum required OpenClaw scopes, bounded media/stream buffers, redacted diagnostic descriptions, no private-media persistence by default, and no silent replay of uncertain mutating requests.

A Tailnet connection establishes network reachability; it does not replace OpenClaw application authentication or device authorization.

## Reporting

For now, avoid publishing exploitable credential, authentication, privacy, or remote-execution details in a public issue. Contact the repository owner privately through the contact mechanism on the GitHub profile. A dedicated security advisory workflow may be added before the first stable release.

## Validation boundary

Deterministic secret-sentinel tests protect known diagnostic/configuration surfaces, but they are not a complete security audit. Deployment validation must still inspect real logs, Keychain behavior, credential reuse/rotation/revocation, scope upgrades, CI artifacts, and application caches. Physical validation must additionally verify that camera/audio data is not retained outside the explicit interaction lifetime.
