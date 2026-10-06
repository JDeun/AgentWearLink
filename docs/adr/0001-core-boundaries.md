# ADR-0001: Device-agnostic and agent-agnostic core

- **Status:** Accepted
- **Date:** 2026-10-06

## Context

The first concrete use case is Ray-Ban Meta + Meta Wearables DAT + iOS connected to OpenClaw. Binding the core directly to either side would make future device or agent integrations expensive.

## Decision

AgentWearLink defines two primary boundaries:

- `DeviceAdapter`
- `AgentAdapter`

Vendor SDK types and agent-runtime protocol types remain inside their respective adapters.

The first implementation is allowed to be concrete and narrow. Generic contracts must remain minimal and are expanded only from tested requirements.

## Consequences

### Positive

- Ray-Ban/OpenClaw are replaceable.
- Core behavior can be tested without hardware.
- Future adapters do not require redesigning the opposite side.

### Trade-offs

- Adapter mapping code is required.
- Premature abstraction remains a risk, so speculative capabilities are prohibited.
