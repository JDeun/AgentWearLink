# Real development OpenClaw Gateway integration (Layer 2)

This opt-in harness runs AWL's **production** Gateway connection, RPC
dispatcher, supervisor, run client and native agent adapter against a real
OpenClaw Gateway. It is not a synthetic WebSocket fixture and is not the
physical iPhone/Tailscale deployment gate (#56/#97).

## Start a disposable real Gateway from a pinned source checkout

The existing harness below can attach to an operator-started isolated Gateway.
For a safer, repeatable path, use the opt-in runner. It does **not** install,
restart or modify a production Gateway service:

```bash
# Build the exact trusted development checkout in its own directory first.
# Use the checkout's actual 40-character HEAD commit, not a guessed version.
python3 scripts/run_hermetic_development_gateway.py \
  --checkout /path/to/isolated/openclaw-checkout \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT
```

The runner rejects mismatched/dirty checked-out sources or a missing built
`dist/entry.js`. It launches **that checkout's Node entrypoint**, not a
globally installed CLI. It creates a fresh temporary Gateway state directory,
config file, workspace, local random port, synthetic auth token and independent
per-run read/write Keychain services. It carries only allowlisted toolchain
environment variables: inherited provider API keys, custom secrets, existing
OpenClaw state/profile paths, production Gateway tokens and Tailnet settings
are deliberately excluded. Gateway stdout/stderr, model output, credentials
and probe errors are suppressed.

The default is the **read-only** acceptance gate: two separate Swift production
health probes, the second explicitly sending **no shared Gateway bearer**.
A pass requires a device grant approved by the real Gateway and persisted in
the same isolated Keychain service after the first `hello-ok`. It does not
prove a model response, production Tailnet credentials, or revocation handling.
If the isolated Gateway requires manual device-pairing approval, the test
fails closed until the operator explicitly approves only that disposable
Gateway's new identity. The runner cannot automatically approve pairings.

If the isolated Gateway returns `pairingRequired`, the default execution
fails closed and removes its temporary Gateway. To make the actual handshake
and device-grant approval test **repeatable within the same isolated Gateway**,
use the explicit terminal-only flag:

```bash
python3 scripts/run_hermetic_development_gateway.py \
  --checkout /path/to/isolated/openclaw-checkout \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --approve-isolated-pairing
```

The runner lists only pending request IDs read from **its own** disposable
loopback Gateway and asks the operator to enter one exact ID after reviewing
the request. Only a matching ID is sent to the official OpenClaw
`devices approve <requestId>` command, with its transient local state and
synthetic auth. No automatic "latest" approval, arbitrary request, personal
service credential or Tailnet access is permitted. Approval input times out
after a bounded interval. A full-chat test may require **separate** read-only
and write-profile approvals; at most two interactive approvals are supported
in one run, and any refused/unknown request fails closed.

This proves a **human-approved disposable** device pairing only when the real
probes pass. It does not prove automatic pairing, a physical iPhone pairing,
or that the remote Mac mini grants credentials.

For the **full real agent** test, supply an intentionally harmless, development-
only model/configuration with tools disabled (or otherwise restricted).
This must not be a personal OpenClaw profile or private conversation.

```bash
AWL_DEV_ISOLATED_MODEL_ACK=1 \
python3 scripts/run_hermetic_development_gateway.py \
  --checkout /path/to/isolated/openclaw-checkout \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --full-chat --config-template /path/to/synthetic-development-openclaw.json
```

Add `--prove-abort` only when the isolated model is deliberately slow enough
for an accepted run to be cancelled remotely. A too-fast completed run
cannot count as abort success. The configuration file is copied to the
temporary state, not modified in place; ensure it contains **no secrets or
destructive tool permissions**. The runner does not supply model credentials
implicitly, and source revision checks are not a binary reproducible-build
attestation. Always verify the local development build is actually from the
chosen checkout.

The runner retires only its own process group and removes its temporary
Gateway config/workspace on exit. macOS Keychain items are segregated under
a fresh synthetic service namespace; their presence alone does not imply
approval of a deployment identity. Do not confuse loopback probe success
with iPhone/Tailnet/Ray-Ban physical evidence.

## Credential-free upstream Gateway negative contract on CI

The dedicated [real Gateway CI workflow](../.github/workflows/real-openclaw-gateway.yml)
uses GitHub-hosted macOS 26 to build the exact audited upstream
OpenClaw revision under an ephemeral home, random loopback port,
and synthetic token. It never accesses the owner's Mac mini, Tailnet,
model credentials or personal sessions. The pinned OpenClaw Gateway
**silently approves local pairing by default** (`gateway.nodes.pairing.autoApproveLocal`
defaults to `true`). For this negative-contract mode only, the runner
writes a minimal private configuration into its fresh disposable
`OPENCLAW_CONFIG_PATH` with `autoApproveLocal: false` and no
trusted-CIDR auto-approval. The normal operator-approved development
workflow and owner's production Gateway configuration remain unchanged.

The automated gate only checks that the **real** OpenClaw Gateway
rejects an unapproved, freshly generated AWL read-only device identity
with a pairing-required response. That is a **negative protocol-contract
test**, not successful authenticated health, persistent device-grant
reuse, chat or abort.

The negative-only CI probe intentionally constructs the production
`OpenClawGatewayConnection` and `OpenClawConnectAssembler` with a **fresh
in-memory identity and empty credential store**, avoiding a potential unattended
macOS Keychain permission prompt. This does **not** exercise Keychain writes,
approved credentials, or persistent tokenless reconnect. A fail-closed policy
enables those stores only for the disposable loopback/read-only negative mode.
The real operator-approved development probe retains the ordinary production
Keychain stores. The CI redacted phase breadcrumb separates challenge receipt,
request assembly and actual WebSocket send; timeouts are failures, not evidence. A rejection is counted as successful evidence
only in explicit `--expect-pairing-required` mode; successful admission
or any unrelated error fails that mode. CI does not automatically
approve, register or trust any device.

Actual positive Layer-2 Gateway acceptance still uses the interactive
`--approve-isolated-pairing` path above, with an operator selecting
an exact pending request ID on the fresh local test Gateway.
Afterward the full chat, cancellation and tokenless reuse proofs
must be collected separately before closing #331.

## Isolation and prerequisites

- Launch a **separate development OpenClaw Gateway** on local loopback
  with its own profile/config directory, token, sessions, model/tools and data.
  Do **not** reuse the owner's Mac mini Gateway, credentials, sessions, or Tailnet.
- Pin the actual Gateway checkout/version. Record the 40-character source commit
  and check it against `docs/openclaw-protocol-contract.md`. The harness records
  the declared revision; it cannot attest to the running process's binary.
- Provide a harmless/isolated agent model that can emit assistant text, without
  destructive tools. Configure explicit read-only and mutating device pairing
  on the development Gateway if required.
- A macOS host with Swift, Python 3 and the OpenClaw development Gateway
  already running is needed. This script does **not** install or start OpenClaw.

```bash
export AWL_ALLOW_DEV_GATEWAY_TEST=1
export AWL_OPENCLAW_URL=ws://127.0.0.1:18789
export AWL_OPENCLAW_EXPOSURE=loopback
export AWL_OPENCLAW_TOKEN='<development-only-token>'
export AWL_OPENCLAW_SESSION_KEY='agent:main:awl-dev-isolated'
export AWL_DEV_GATEWAY_REVISION='<exact 40-character source commit>'
bash scripts/run-openclaw-development-gateway.sh
```

The validator rejects non-loopback endpoints (including Tailscale), any
session key outside the dedicated `agent:<id>:awl-dev-<name>` namespace,
embedded URL credentials, bootstrap handoff tokens, missing explicit opt-in
and unpinned revision declarations. This is a guard against accidentally
targeting an existing personal session; a session prefix **cannot attest**
that the Gateway process/configuration itself is isolated. Confirm the
running process, profile directory, token and model/tools are development-only.
Only the script generates the harmless test message.

## What passing means

1. The read-only production probe completes connect/auth + `health` RPC.
2. A second **independent Swift process** connects with the same
   endpoint-scoped read-only Keychain namespace, but **without the shared
   Gateway bearer or a bootstrap token**. It must load and present the
   server-approved read-only device grant, then pass an actual `health`
   RPC. Missing, revoked, downgraded or over-privileged grants fail closed.
   This distinguishes genuine device-grant reuse from two shared-token
   handshakes.
3. The mutating production adapter submits one harmless agent request.
4. At least one incremental assistant text delta arrives and exactly one
   terminal completion is observed before stream close.
5. The harness exits nonzero for missing deltas or terminal events.

Every Swift command, including the optional abort probe below, has a
300-second **process deadline** (including first-time Swift compilation).
On timeout/interruption, the wrapper terminates the Swift process group;
probe stdout/stderr is suppressed so untrusted Gateway replies, credentials
and SDK error strings never enter shell or CI logs. Only stable result codes
and redacted diagnostics are surfaced. Pairing approval must be inspected
on the **isolated development Gateway**, not copied from probe output.
CI tests only the wrapper and shell syntax without a live Gateway.

The read-only and mutating validation identities are separate and may need
separate local pairing. Their Keychain services remain distinct; the Gateway
endpoint credential namespace also isolates local and Tailnet endpoints.
No token, response text or private media is collected as an artifact.

## Optional accepted-run abort proof (isolated dev Gateway only)

The default smoke test above deliberately does not issue remote aborts. For a
separate explicit cancellation check, configure the isolated development
Gateway with a **harmless, deliberately slow** test model/agent that keeps an
accepted run alive long enough to abort. Then run:

```bash
export AWL_DEV_GATEWAY_PROVE_ABORT=1
bash scripts/run-openclaw-development-gateway.sh
```

The runner first repeats the existing health and assistant delta/terminal
checks. It then uses the **production** OpenClaw agent run client and RPC
dispatcher to submit a second harmless message under the dedicated
`agent:<id>:awl-dev-<name>` session, verifies the Gateway-accepted session
identity, sends `chat.abort` against that specific accepted run ID, and
requires the Gateway's positive abort confirmation. A model that finishes too
quickly for abort produces a **failed proof**, not an invented success. The
command only emits static success/failure diagnostics, never model output,
credentials, run IDs or session contents.

This covers a real Gateway cancellation RPC, **not** a complete end-to-end
`OpenClawNativeAgentAdapter.cancellationOutcome()`/reconnect/credential reuse
matrix. The latter still requires isolated evidence under #331. The feature
must not be run against the owner's personal Mac mini Gateway or Tailnet.

## Still required before #331 is complete

A passing harness invocation with sanitized evidence and exact actual Gateway
revision, plus a first approved handshake followed by a **strictly tokenless**
second independent health probe, then the full native adapter's cancellation,
incremental event ordering, terminal reconciliation, credential revocation
and cleanup. The tokenless second-process path is implemented but still
requires real Gateway execution evidence before it can be called verified. Until then this is the first **real Gateway smoke-test path**, not
full integration acceptance. CI runs only preflight/process-runner unit tests and shell syntax
checks without needing a live Gateway.

## Isolated positive hello-ok / health CI (October 2026)

The real upstream macOS-26 CI workflow now runs **two independent disposable
Gateway instances** from the same pinned checkout. The original rejection
contract configures `autoApproveLocal: false`; the new positive health contract
sets `autoApproveLocal: true` **only on its own synthetic localhost-only
Gateway** and proves the real production AWL Swift connection receives
`hello-ok` and a successful `health` RPC.

```bash
python3 scripts/run_hermetic_development_gateway.py \
  --checkout .awl-hermetic-upstream \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --expect-health-ok
```

The mutually exclusive `--expect-pairing-required` and `--expect-health-ok`
modes reject supplied config templates, mutating chat/abort, and
operator-approval requests. An unattended CI job never approves a device on
the user's installed Gateway; only the freshly created synthetic loopback
Gateway may auto-approve.

The real production Gateway client, assembler, supervisor and dispatcher
perform the transport/auth/health operations, using **ephemeral in-memory
identity/credential stores** instead of a GUI-blocked Keychain on CI. The
contract does not prove that the operator manually approved the device,
that the Keychain persisted an issued grant, that a second independent
process reconnected without shared auth, or that agent text/abort works.
Those are still outstanding, separate #331 acceptance requirements.

## Disposable, actual-Gateway second-process device-grant test

The opt-in CI lane also exercises the real upstream Gateway and production
AWL Swift handshake in **two independent processes**, using the same synthetic,
private loopback identity and a server-issued `operator.read` device grant:

```bash
python3 scripts/run_hermetic_development_gateway.py \
  --checkout .awl-hermetic-upstream \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --expect-grant-reconnect
```

The first process authenticates with a randomly generated, disposable shared
Gateway bearer. Its genuine `hello-ok` device grant and private signing
identity are persisted **only in a 0700 temporary directory, in 0600 test
files**. After that first process has exited, a separate Swift process
loads the scoped grant, rejects any wrong role or missing/over-privileged
scope, and performs a real `health` RPC with **both shared bearer variables
absent from its environment**. The production `OpenClawConnectAssembler`
must assemble a device-token-only handshake, with no bootstrap token.
An absent or invalid server grant fails the second process; passing the first
health RPC alone never satisfies this gate.

This mode is disabled without the exact private `grant-cache` path, dedicated
`AWL_DEV_GATEWAY_EXPECT_GRANT_RECONNECT` marker, read-only loopback profile
and synthetic runner nonce. It cannot combine with negative/pure-positive
contract modes, user configuration, mutation, abort or manual approval.
The Python harness removes the private files along with the disposable
Gateway after every attempt and captures no secret artifacts. The test-only
file store **must never replace production Keychain**.

**Claim boundary:** A passing run proves interoperability and grant reuse
across process boundaries against a pinned *real* Gateway under local
auto-approval. It does **not** prove macOS/iOS Keychain behavior, explicit
human approval, iPhone/Tailnet authenticated reconnection, real agent
execution/terminal text/abort or physical Meta DAT integration. These remain
separate acceptance requirements in #331/#117/#118/#56.

## Merged-main real protocol regression gate

When the actual Gateway protocol adapter/probe, contract runner, Swift package
manifest/resolution, relevant Swift tests, or Gateway workflow changes on
`main`, the same pinned three-contract **real upstream Gateway** workflow
runs after merge as well as on pull requests. This ensures PR-head evidence
cannot silently stand in for an unverified merge commit. It performs real
unapproved rejection, synthetic loopback hello/health and synthetic issued
grant-only second-process reconnect. It never reads private Mac mini secrets
or connects to physical Tailnet. Post-merge green status still does not prove
Keychain, human approval, model-backed agent turns or real eyewear operation.

## Deterministic real Gateway → native agent stream smoke contract

The pinned real upstream OpenClaw checkout already includes its own
`scripts/e2e/mock-openai-server.mjs`. The hermetic CI harness launches that
provider **as a separate owned loopback-only test process**, with a fixed
response marker and no model/API credentials. A temporary Gateway config
uses a single `openai-responses` model mapped exclusively to that local
provider; remote catalog refresh is disabled and the model is denied all
tools. Neither personal provider credentials nor the owner's session/model
are copied into the disposable workspace.

```bash
python3 scripts/run_hermetic_development_gateway.py \
  --checkout .awl-hermetic-upstream \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --expect-agent-stream
```

A **separately compiled production** `awl-openclaw-chat-probe` connects
using its mutating OpenClaw validation profile, with a fresh in-memory
identity/credential store on headless CI. It submits one fixed harmless
prompt through the real `OpenClawNativeAgentAdapter`, requires at least one
incremental assistant text event and exactly one terminal completion, and
then disconnects. The runner also verifies that the pinned mock provider
actually received a Responses request. It emits only fixed diagnostic
categories; generated model text remains suppressed.

The flag fails closed unless it owns a fresh loopback Gateway, runs the
exact built Swift probe and synthetic model, and is mutually exclusive
with all other contract flags, supplied custom configs, interactive pairing,
full-chat and abort options. No Tailnet endpoint, hardware camera/microphone,
user session or external model may be used. Model response simulation
proves **real Gateway/native-adapter protocol interoperability**, not actual
LLM/model quality, iPhone/WSS delivery, Keychain persistence, user-approved
device pairing, native adapter abort or real Meta eyewear E2E.

## Real accepted-run abort with held synthetic provider

For the exact pinned upstream OpenClaw checkout and a locally built native Swift
chat probe, the separate `--expect-agent-abort` lane launches an owned
127.0.0.1 OpenAI Responses mock with a **held response**. There is no provider
credential, uncontrolled model invocation, user workspace, Tailnet or
connected Meta hardware:

```sh
python3 scripts/run_hermetic_development_gateway.py \
  --checkout .awl-hermetic-upstream \
  --revision YOUR_EXACT_PINNED_GATEWAY_COMMIT \
  --expect-agent-abort
```

The production `OpenClawAgentRunClient` submits a harmless real agent RPC,
obtains an accepted `runId`, then verifies that the local mock provider's
read-only aggregate `/health` counter shows at least one actual Responses
ingress. The mock is held at that point: the model cannot successfully
finish by itself. Only then does the same Swift process issue the
real Gateway `chat.abort` RPC for the accepted run and require explicit
`aborted:true` confirmation (including the run ID if returned).
Without actual model ingress, valid isolated session identity or confirmed
abort, the lane fails. All model/Gateway outputs are suppressed, and a
fixed-vocabulary phase file is the only diagnostic signal.

The mode is mutually exclusive with the read-only pairing/health,
grant-reconnect, synthetic stream, human pairing, user-configured model and
manual abort modes. Private temporary state and the held model are removed
at teardown. This proves real upstream **accepted, actively executing
run → confirmed cancellation**, not correct rollback of arbitrary tools,
model/provider quality, real credential Keychain permissions, operator
approval or physical iPhone/Meta/Tailnet recovery.

## Real Gateway same-session two-turn smoke

Run the existing pinned, disposable real Gateway against its own local
synthetic OpenAI Responses server (no real model, tokens or network):

```bash
python3 scripts/run_hermetic_development_gateway.py \
  --checkout .awl-hermetic-upstream \
  --revision YOUR_EXACT_40_CHARACTER_COMMIT \
  --expect-agent-session
```

The exact **production native agent adapter** stays connected to the **same
explicit `agent:main:awl-dev-hermetic` session** and submits two sequential
harmless requests, each with a fresh `InteractionID`. For *each* request the
real Gateway must yield at least one nonempty text delta followed by exactly
one terminal completion, all carrying the corresponding interaction ID.
The owned local model's aggregate ingress counter is sampled **before and after each turn**. It must strictly increase on *both* completed turns (and be at least two overall). The real OpenClaw runtime may perform multiple model calls per user turn; consequently the aggregate is **not** required to equal two. This rejects a second turn that only replays stale output, without incorrectly treating internal provider calls as duplicate agent submissions.

This is a controlled same-session protocol / output attribution and
double-submit smoke test, not evidence that a real model correctly
remembers prior turns, retains tools, or works across network reconnect.
Physical device/Tailnet and real personal session/memory validation stay
open under #118/#97/#56. State, credentials and localhost mock process
are deleted when the test ends.

## Native macOS Keychain contract (separate from the real-Gateway smoke)

GitHub Actions `Swift Core` runs a dedicated opt-in XCTest class on a
disposable `macos-26` runner:

```bash
CI=true AWL_RUN_NATIVE_KEYCHAIN_INTEGRATION=1 \
  swift test --filter AgentWearLinkOpenClawTests.OpenClawNativeKeychainIntegrationTests
```

This exercises the **production** `KeychainOpenClawDeviceIdentityStore` and
`KeychainOpenClawDeviceCredentialStore` through `Security.framework`, not an
in-memory or file-backed substitute. A UUID-isolated service ensures no
production credentials, developer service, or personal OpenClaw identity is
opened. The test checks private signing identity retention across two
independent storage actor instances; server-grant style
`operator.read` insertion, read, and compare-and-swap rotation/removal;
and strict namespace separation for different synthetic Gateways.
A `defer` cleanup deletes only this service. When not explicitly enabled
under CI, the XCTest method skips without touching local Keychain.

**Evidence boundary:** A passing job confirms macOS runner Keychain native
store interoperability for this service, not an explicit operator-approved
pairing, a device grant actually issued by a Gateway, persistence across
process restart, the user's Mac mini or an iOS Keychain access group. Those
still require the corresponding real Gateway/personal macOS and hardware
acceptance stages in #331.

## Real Gateway + native macOS Keychain grant (CI-only)

The dedicated macOS 26 real-Gateway job has a separate
`--expect-native-keychain-grant-reconnect` lane. Unlike the existing
disposable-file-grant test, this uses production
`KeychainOpenClawDeviceIdentityStore` and
`KeychainOpenClawDeviceCredentialStore` through macOS `Security.framework`.
Two independent Swift processes talk to the *same* pinned real disposable
loopback Gateway: the first receives an `operator.read` device grant; the
second receives no shared Gateway bearer or bootstrap token, loads the
persisted identity and endpoint-scoped grant from native Keychain, and
must pass authenticated `health`.

This path requires both `CI=true` and
`AWL_RUN_NATIVE_KEYCHAIN_INTEGRATION=1`, rejects personal/Tailnet endpoints,
uses a random nonce-isolated Keychain service on the temporary CI runner
and executes narrowly scoped cleanup even when the Gateway probe fails.
Cleanup failure makes the job fail rather than silently leave synthetic
credentials behind.

**Evidence boundary:** This establishes native macOS CI Keychain ↔ real
upstream Gateway interoperability across processes if green. It does not
establish explicit human approval, iOS Keychain entitlements, the owner's
Mac mini or Tailnet, real model/tool/memory behavior, or physical Meta/iPhone
acceptance.
