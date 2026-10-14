# OpenClaw protocol-v4 contract pin

AgentWearLink intentionally supports a narrow subset of the OpenClaw Gateway
protocol rather than importing the whole upstream implementation.

## Pinned upstream source

- Repository: `openclaw/openclaw`
- Commit: `172a5d6202214eea253234c3b04c8184df9fea70`
- Gateway protocol: `4`

The CI verifier reads the relevant source files directly from that immutable
commit. This keeps pull requests reproducible while ensuring AWL's local model
is checked against upstream-owned schemas/client logic rather than only
self-authored fixtures.

## Covered contract surface

`scripts/verify-openclaw-protocol-contract.py` checks only the wire surface
AWL ships:

- `connect.challenge`
- connect parameters and canonical client id/mode registries
- `hello-ok`, authentication placement, policy limits, and bootstrap handoff
  grants
- request/response/event envelopes
- `agent` and `agent.wait`
- `chat.abort`
- device-auth V3 tuple ordering and metadata normalization

Swift tests in `OpenClawUpstreamContractTests` then prove AWL can encode or
decode the corresponding supported subset and independently reconstruct the
bytes covered by the V3 device signature.

## Checking the release you run

CI always checks the pin. To check the OpenClaw release an operator actually
runs, pass that release's full commit SHA:

```bash
python3 scripts/verify-openclaw-protocol-contract.py --commit <full 40-hex sha>
```

The `chat.abort` check covers only the fields AWL encodes
(`sessionKey`, `agentId`, `runId` in `OpenClawChatAbortParams`). Upstream's
schema is a closed object, so those fields must exist; fields AWL never sends
(`preserveSideRuns`, `discardPendingInput`) are not part of AWL's contract.

Releases checked on 2026-10-13 (source-level wire subset only; this is not a
live Gateway test):

| OpenClaw release | Commit | Wire subset |
| --- | --- | --- |
| 2026.9.6 | `eb377ac5` | verified |
| 2026.9.9 | `bcfc8881` | verified |
| 2026.10.1 | `e178c39e` | verified |
| 2026.10.2 | `b8952d47` | verified |
| 2026.10.5-beta.3 | `1808b57b` | verified |

2026.9.6 previously failed only because the verifier also demanded
`discardPendingInput`, a field AWL does not send.

## Updating the contract

Do not change the upstream commit as a mechanical dependency bump.

1. Select the new audited OpenClaw commit.
2. Review the upstream files referenced by
   `scripts/verify-openclaw-protocol-contract.py`.
3. Update the verifier pin and assertions only for intentional protocol changes.
4. Update AWL wire models and `OpenClawUpstreamContractTests` in the same PR.
5. Run the full Swift suite and the contract verifier.
6. Record any compatibility boundary or migration in the PR description.

A protocol version remaining at `4` is not sufficient evidence that these
semantics are unchanged.
