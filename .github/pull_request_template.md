## What changes

Describe the concrete problem and the boundary changed.

## Invariants

- [ ] Vendor/runtime-specific types remain outside Core where applicable.
- [ ] Buffers/media are bounded where applicable.
- [ ] Cancellation and terminal semantics are explicit.
- [ ] Uncertain mutating requests are not silently replayed.
- [ ] No credentials, private keys, or private media are included.

## Validation

- [ ] `swift test` (for code changes; explain when not applicable)
- [ ] Deterministic regression coverage added/updated (when applicable)
- [ ] `python3 scripts/check_docs.py` (for documentation changes)
- [ ] Mermaid diagrams reviewed in rendered Markdown (when applicable)
- [ ] Hardware/deployment validation separated and documented where required

## Remaining physical/deployment work

State what this PR cannot prove in CI.
