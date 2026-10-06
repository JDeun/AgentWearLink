# Testing strategy

AgentWearLink has three distinct test layers.

## 1. Core deterministic tests

No vendor SDK and no network.

Use `MockDeviceAdapter` and `MockAgentAdapter` to validate:

- session lifecycle
- duplicate suppression
- cancellation
- event/request mapping
- deterministic shutdown
- failure propagation

These tests should run in CI.

## 2. Vendor/runtime integration tests

Examples:

- Meta Mock Device Kit ↔ MetaDATAdapter
- test HTTP/SSE/WebSocket server ↔ agent transport
- OpenClaw development gateway ↔ OpenClawAdapter

These validate protocol mappings but do not replace physical-device tests.

## 3. Physical E2E tests

Ray-Ban Meta + iPhone + target agent runtime.

Required for:

- Bluetooth/device lifecycle
- microphone/audio routing
- camera behavior
- Hey Meta invocation
- lock-screen/background behavior
- latency and interruption UX

A feature that depends on physical hardware must not be declared fully validated from layer 1 or 2 alone.
