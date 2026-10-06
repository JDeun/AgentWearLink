# ADR-0002: Agent runtime owns intelligence and conversation semantics

- **Status:** Accepted
- **Date:** 2026-10-06

## Decision

AgentWearLink does not implement model routing, RAG, persistent memory, tool orchestration, or canonical chat history.

Those remain responsibilities of the connected agent runtime.

For the first reference implementation, OpenClaw owns those behaviors. Telegram may be used by that deployment as a canonical visible log, but Telegram is not part of the AWL core contract.

## Rationale

Duplicating agent responsibilities inside the wearable bridge would fragment context and tightly couple AWL to a particular deployment.
