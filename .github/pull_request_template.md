## What changes

Describe the concrete problem and the boundary changed.

## Invariants

- [ ] Vendor/runtime-specific types remain outside Core where applicable.
- [ ] Buffers/media are bounded where applicable.
- [ ] Cancellation and terminal semantics are explicit.
- [ ] Uncertain mutating requests are not silently replayed.
- [ ] No credentials, private keys, or private media are included.

## Validation

- [ ] `swift test`
- [ ] Deterministic regression coverage added/updated
- [ ] Hardware/deployment validation separated and documented where required

## Remaining physical/deployment work

State what this PR cannot prove in CI.
