# Security Policy

AgentWearLink handles microphones, cameras, wearable sessions, and authenticated agent endpoints. Treat all media and credentials as sensitive.

## Baseline rules

- Never commit tokens, API keys, certificates, provisioning secrets, or private endpoint credentials.
- Store application secrets in platform secure storage such as iOS Keychain.
- Use authenticated encrypted transports.
- Do not expose an unauthenticated agent gateway to the public Internet.
- Redact secrets from logs.
- Do not persist raw microphone audio or camera images by default.
- Bound media buffers and validate payload sizes.
- Treat device and agent responses as untrusted input at adapter boundaries.

## Reporting

Until a private security reporting channel is configured, avoid posting exploitable credential or privacy vulnerabilities with sensitive reproduction data in a public issue. Contact the repository owner privately through an appropriate GitHub-supported channel.
