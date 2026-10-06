# Contributing

AgentWearLink is pre-alpha. Contributions should preserve the device/agent boundary and avoid speculative abstraction.

## Development principles

- Keep vendor-specific types inside device adapters.
- Keep runtime-specific types inside agent adapters.
- Add capabilities only when backed by a concrete integration or test.
- Prefer small PRs tied to an issue.
- Add tests for core behavior.
- Never commit credentials or private media.

## Pull requests

A PR should explain:

1. the problem,
2. the boundary it changes,
3. how it was tested,
4. hardware/runtime dependencies,
5. security/privacy implications.

Hardware-dependent changes should clearly distinguish automated tests from physical-device validation.
