# MCP gateway M0: implementation slicing

**Status:** active; written 2026-08-17 for issue
[#1465](https://github.com/andreasronge/ptc_runner/issues/1465); revised the
same day after independent review. This plan activates mode M0 and scope
tier 2 (HTTP, single shared authority) of
[`future/mcp-compose-gateway.md`](future/mcp-compose-gateway.md) and slices
them into four pull requests. The future document remains the product and
design reference; the two deliberate deviations below are recorded there,
not silently overridden.

**Claimed scope:** a single-authority, read-only gateway serving a fixed
tool list, one manifest per tool, stdio first, bearer-authenticated
streamable HTTP second. Protocol revision `2026-07-28` only. A fixed tool
list is product policy (stable authority, cacheable surface); the protocol
itself offers `listChanged`/`subscriptions/listen`, which we deliberately do
not use.

**Deviations from the future plan, recorded there:**

1. **Several tools per gateway.** The future plan's M0 reads "one compiled
   application exposed as one MCP tool". This activation widens the static
   configuration to several entries; each entry remains exactly one
   application exposed as exactly one tool, so the authority model — "what
   this tool can reach" equals "what this application was granted" — is
   unchanged.
2. **Staged provider services.** The future plan holds gateway-scoped pooled
   provider services (warm upstream connections) as part of the serving
   architecture and names their ownership/cleanup/drift-recheck contract its
   largest new engineering item. This activation stages that: boot performs
   a **validation acquisition** per template (proving digests and
   configuration at startup, then closing), and every call's own acquisition
   **revalidates digests**, so upstream drift fails closed at call time.
   Pooled *retention* of provider services keeps its own trigger and is not
   part of these four PRs.

**Out of scope** (unchanged from the future plan's non-goals): per-principal
authority, tenant isolation, quotas, inbound OAuth, write-effect compound
tools, dynamic tool lists, sessions, M1 `eval`, M2 `handles`, and any
restoration of the code removed in `ec5806d1`.

## Constraints this slicing is built around

Verified against `main` (2026-08-17):

- The provider-bearing execution path crosses internal APIs:
  `RunCoordinator.execute/2` refuses prepared runs with providers
  (`run_coordinator.ex:200`), `execute/4` is `@doc false`
  (`run_coordinator.ex:180`), and `ProviderExecution` is `@moduledoc false`.
  The gateway must consume only documented public APIs, so the facade lands
  first.
- `RunCoordinator.prepare/2` recompiles bundles on every run, and
  `PreparedRun` is single-use by design (owned provider-activity marker,
  one-way consumption). The serving template must be a **new** immutable
  type; nothing existing can be reused across calls.
- `Runner.execute_workflow/4` starts the workflow sandbox without
  `link: true` (`runner.ex:202-217`; contrast the watchdog-monitored
  evaluation paths), so a dead caller releases resources while the workflow
  keeps a scheduler until its deadline. Documented in
  `run_coordinator_execution_test.exs` caller-death coverage.
- All runs share one `ReqLLM.Finch` pool with default geometry
  `count: 8, size: 1`; the sizing fix applies only in `:command_vm` mode,
  whose gate refuses a run when the required provider application is
  already running (`provider_application_gate.ex:159-172`) — a
  check-then-act refusal, not an atomic admission mechanism. Open issue
  #1290. Per-run limits (`live_provider_tasks` 8) do not aggregate across
  runs.
- `CommandOutcome` and `to_map/1` are already public; what is internal is
  the `ExecutionOutcome` → `CommandOutcome` conversion
  (`CommandRunOutcome`) and the run constructors. The facade promotes
  **that seam** rather than adding a second projection (the duplication
  gate would flag one anyway).
- Attestation keys are per-VM (`attestation.ex:26-46`): serving templates
  cannot cross nodes or restarts. Each gateway node compiles its own
  templates at boot; the stateless profile makes that sufficient.

## PR 1 — cancellation: link the workflow sandbox

**Status:** implemented in this worktree; not yet submitted.

Root project; small; independent value.

- Failing test first: caller death mid-workflow must terminate the sandbox
  promptly (extend the documented gap at
  `run_coordinator_execution_test.exs` caller-death coverage; monitors, no
  `Process.sleep`).
- Kernel-owned Lisp runs go through `Lisp.run_owned/2` /
  `Lisp.check_owned/2`, which force Sandbox `link: true` (a watchdog, not
  a BEAM link). Direct `run_native/2` stays unlinked.
- Verify the owner's existing kill-and-drain contract
  (`ExecutionSessionOwner` monitors its caller) now reaches the sandbox on
  both caller-death and deadline paths; provider drain remains bounded.

Acceptance: the new test passes; the full suite is green; no behavior change
for normally completing runs.

## PR 2 — public hosting facade: serving template, host runtime, outcome

Root project; the largest PR; split into 2a (template + outcome, no
providers) and 2b (host runtime + admission) if review size demands.

**2a status (this branch):** package-only `ApplicationPackage.package_memory/3`
and `package_directory/2`; `PtcRunner.Kernel.ServingTemplate` compile/call for
provider-free apps; `CommandRunOutcome` promoted as the public outcome seam.
HostRuntime, aggregate admission, and provider-backed serving remain 2b.

- `PtcRunner.Kernel.ServingTemplate` — a **new immutable struct** caching
  everything reusable about an application: the compiled workflow **and
  mission** bundles, validated entry, compiled input **and** result
  contracts (both required for serving), the validated provider
  declarations/plan bound to the installation catalog, and the captured
  `application_content_digest` and `effective_application_digest`. Per-call
  construction reuses all of it and creates only genuinely per-run state —
  the provider-activity owner, selection contexts, sinks, and deadline —
  with **no recompilation and no provider reselection**; defining that
  reconstruction (what today lives inside single-use `PreparedRun`) is the
  heart of this PR. Decisively, the template carries the **frozen execution
  policy**: result projection, event policy, inspection capture, limits,
  **and the input authority class** (`:normal`/`:private`) are fixed at
  template compile time and stamped onto every `ExecutionInput`. A call
  supplies only the input value, which the effective digest deliberately
  excludes, so the digest captured at compile time describes every run made
  from the template. With `effects: :read_only` the compile **fails
  closed**: any effect not provably `:read` — including unknown or
  unclassifiable effects — refuses the template.
- **Package-only acquisition seam.** Today acquisition couples package
  construction to input selection. `ServingTemplate.compile` needs a
  documented package-only path that **skips input acquisition entirely** —
  not one that selects and discards, which can still fail on the manifest's
  input before compilation. Defining it is part of this PR, not assumed.
- `PtcRunner.Kernel.HostRuntime` — a supervised, **registered singleton
  per VM** owning what is VM-global: provider-application lifecycle
  (`:req_llm`/`:llm_db` started once, dotenv disabled) and pool geometry.
  Startup fails closed when `:req_llm` is already running with conflicting
  configuration, and **validates everything reversible first** — pool
  geometry, the admission-ceiling invariant, credentials configuration —
  before starting any VM-lifetime application, so a refused startup never
  leaves `:req_llm`/`:llm_db` running as a side effect of the failure.
  Applications the runtime starts are **VM-lifetime**: it
  never stops them (its own restart re-verifies configuration and adopts
  them), and it never stops applications it did not start — so a runtime
  crash or supervisor restart cannot yank a dependency from under another
  embedder or an in-flight run. `call(runtime, template, input, opts)`
  builds a fresh `ExecutionInput` and per-run sinks, executes one ordinary
  bounded Kernel run under the template's frozen policy, and releases
  everything on any exit. Provider acquisition is per-call (deviation 2
  above).
- **Aggregate provider admission sits at provider-task dispatch, not at
  call admission.** A run uses zero to `live_provider_tasks` workers
  dynamically, so bounding whole calls cannot bound aggregate tasks. The
  counting semaphore is checked where provider tasks are dispatched;
  acquisition is **non-blocking** (saturation yields a closed diagnostic,
  not a pool timeout or a queue), and release is **exactly-once across
  every exit path** — normal completion, provider failure, task crash,
  deadline, caller death, and owner termination — enforced by the
  semaphore owner **monitoring each leaseholder**. That owner is a
  dedicated VM-lifetime process supervised **above** `HostRuntime` with
  `restart: :temporary` — deliberately **fail-stop**: restarting it would
  recreate the capacity-reset bug one level higher, since its monitors and
  lease state die with it. `:temporary` alone is not the guarantee — a
  restarted *parent* supervisor would start the child anew with empty
  lease state while old leaseholders survive — and writing a tombstone
  *on death* is unreliable (`terminate/2` never runs on `:kill`; an
  external watcher races the restart). The claim is therefore made **at
  birth**: before admitting any work, the first owner atomically writes a
  VM-persistent identity (a `:persistent_term` claimed exactly once and
  never erased), and any later owner creation **refuses** while that
  claim exists. Owner death then naturally leaves the VM poisoned —
  every dispatch refuses with a closed diagnostic and readiness reports
  unhealthy — until VM restart. The test matrix covers owner death
  followed by subtree/application restart. A runtime crash or restart
  beneath a living owner neither resets capacity while old leaseholders
  still run nor strands their leases, because monitors release them as
  they exit.
- **Pool geometry and the admission ceiling are one invariant, not two
  settings.** `HostRuntime` startup validates that the aggregate admission
  ceiling does not exceed the configured Finch capacity
  (`count × size`) of any provider endpoint's pool, and refuses a
  configuration that admits more concurrent ReqLLM tasks than connections
  exist to carry — otherwise the runtime can legally recreate #1290.
  Per-call in-flight limits remain the gateway's separate layer (PR 3).
- The public run outcome DTO is promoted at the
  `ExecutionOutcome` → `CommandOutcome` conversion seam; the `@doc false`
  chain (`RunCoordinator.execute/4`, `ProviderExecution`) is absorbed
  behind the facade with documented contracts.
- `docs/maintainers/embedding.md` gains the serving section; module docs
  carry the exact contracts.

Acceptance: concurrent `HostRuntime.call`s against a **local HTTP stub
provider endpoint** (exercising the real ReqLLM/Finch path — replay
providers never touch the pool and prove nothing about #1290) complete
without starvation under sized pools; dispatch-level admission enforces the
aggregate ceiling with a closed diagnostic **and provably recovers full
capacity after cancellation and after a crashed provider task**, not merely
rejects at saturation; existing CLI behavior is unchanged.

## PR 3 — `ptc_gateway/` sibling application: stdio M0

New nested Mix project (the `ptc_viewer`/`ptc_runner_launcher` pattern); no
web dependencies at this stage; root touched only for release assembly,
command declaration, and precommit/CI wiring.

- Static gateway configuration document: a `tools` map from tool name to
  application source (directory or memory), approved description, and
  **named expected digests** — `application_content_digest`,
  `effective_application_digest`, and one expected snapshot digest per
  provider **occurrence**, keyed by provider name, destination, and
  selection index (the same alias can be selected per destination with
  different configuration, yielding different snapshots; keying by
  installation alone would be ambiguous) — plus the host document
  reference and admission limits. These exact fields are what boot and
  call-time revalidation compare, key by key.
  Boot compiles every entry into a `ServingTemplate` and performs one
  **bounded validation acquisition** per template; startup **refuses** on
  digest mismatch, missing contracts, or non-read effects. Validation
  acquisitions carry full failure semantics: a digest mismatch closes the
  acquired resources before refusing, a cleanup failure itself refuses
  startup, and a failure on entry N closes the acquisitions of entries
  1..N-1 before the process exits. Call-time acquisition revalidates the
  same digests, so boot-to-call upstream drift refuses the call rather than
  serving a surface the digests no longer describe.
- **Explicit stdio ownership topology.** Supervision alone does not tie a
  call to its transport: a dynamically supervised call process outlives the
  connection. Each request owner **monitors the stdio connection process**;
  connection death (client exit, closed pipes) kills every request owner it
  spawned, which kills the runs via PR 1. The topology — connection process
  → request owners → runs — is documented in the gateway, mirroring what
  PR 4 defines for HTTP.
- Server-side protocol module: `2026-07-28` framing for
  `server/discover` → `tools/list` → `tools/call` plus inbound
  `notifications/cancelled`. `MCPProtocol` stays the client-side validator;
  the server module may share only its transport-independent envelope
  helpers. `inputSchema`/`outputSchema` are the compiled contracts emitted
  verbatim; template digests are reported through a namespaced `_meta`
  extension.
- **Error taxonomy is a deliverable, not a sentence.** The PR ships a
  closed mapping table distinguishing protocol-level JSON-RPC errors from
  successful `tools/call` results carrying `isError: true`, covering at
  minimum: malformed envelope, unknown tool, input-contract rejection,
  result-contract rejection, admission rejection, cancellation, execution
  failure, provider-cleanup failure, and private outcomes (whose result
  values never appear in either shape).
- Bounded in-flight call admission with explicit rejection — no hidden
  queue. Each call runs in its own supervised process so transport
  disconnect kills the request owner and, via PR 1, the run.
- Conformance in tests is **two-layered** because the in-repo client shares
  ancestry with the server: hand-authored wire fixtures are the independent
  layer, and driving the gateway with ptc_runner's own `MCPSource` over
  stdio is the integration layer. Envelope fixtures compare **decoded
  values** (JSON object order is not semantic); separate raw framing tests
  assert the byte layout only where bytes matter — for the pinned stdio
  transport that is **newline-delimited JSON**: one document per line, no
  HTTP-style `Content-Length` headers (the tests assert their absence).
  Shared-helper defects cannot hide from fixtures authored without the
  helpers.
- Release: ship in the standalone release as `ptc serve` following the
  Viewer precedent (probe with `apply/3` so an absent module survives
  Elixir 1.20 compilation; do not prove release content by reading
  `_build`).

Acceptance: a real MCP client lists and calls two tools backed by two
manifests over stdio; write-effect or unknown-effect configuration refuses
startup; concurrent calls beyond the limit are rejected; killing the client
mid-call frees the run within the drain bound; the wire fixtures pass
without the in-repo client.

## PR 4 — streamable HTTP, single shared authority

Centered on `ptc_gateway/` — Bandit/Plug enter there and stay out of the
root application — but this PR also touches root release assembly,
container packaging, CI classification, and documentation; scoping it
"gateway-only" would be false.

- Streamable HTTP per the `2026-07-28` transport specification: POST with
  JSON and SSE responses.
- **Origin/host validation is specified, not gestured at:** an absent
  `Origin` header is allowed (non-browser SDK clients send none); a present
  `Origin` must exactly match the configured allowlist or the request is
  rejected — private-network origins get no implicit trust. The `Host`
  header carries `host[:port]`, never a scheme: it must match the
  configured authority's canonical host and effective port, rejecting
  DNS-rebinding and host-header variants; the scheme is validated
  separately by the listener/TLS configuration. Forwarded headers
  (`X-Forwarded-*`, `Forwarded`) are **ignored** in this tier — proxy
  deployment means the operator terminates TLS and authenticates the hop;
  the gateway trusts only its own socket.
- **Disconnect detection is a design item, not an assertion.** A
  synchronous Plug handler may not observe client closure until it writes.
  The PR must choose and document the mechanism, knowing that SSE-first
  alone is insufficient — headers followed by silence detects nothing —
  so the SSE option requires **bounded heartbeat/comment writes with
  cancellation on the first failed write**, and the alternative is a
  proven transport-level socket monitor. Either way the PR defines the
  ownership topology from connection process to request owner to run.
  `notifications/cancelled` is honored on **stdio only**. Over HTTP it is
  **unsupported in both response modes**: the sessionless shared-authority
  model gives a later POST no collision-proof identity to correlate
  against (two clients may reuse the same JSON-RPC request id). HTTP
  cancellation is stream closure in SSE mode; a plain-JSON call runs to
  completion or deadline. These restrictions are documented in the served
  capability surface.
- **Bearer authentication with an explicit hardening checklist:**
  file-sourced token (`env` secrets are VM-global and excluded); defined
  token size/encoding and trailing-newline handling; the token file must
  be a regular file owned by the serving user with **no group and no
  other permissions**, reached through ancestors not writable by others
  (the `PrivateDirectory` discipline), symlinks resolved and re-validated
  — anything else refuses startup, empty files included; comparison uses
  a constant-time primitive; documented rotation (reload or restart);
  tokens never logged; an explicit decision whether `/health` and
  `/ready` are authenticated (default: `/health` open, `/ready`
  authenticated, revisit with the operator).
- `/health` and `/ready` endpoints; readiness covers compiled templates,
  provider-application state, and admission-owner health (a dead semaphore
  owner reports unready).
- Container packaging: artifact-free operation as the default image; the
  artifact-enabled variant documents its platform needs. Loopback binding
  by default; private-network binding is an explicit operator choice.
- External conformance: a **named, version-pinned** official MCP SDK client
  as a test harness, chosen in this PR for verified `2026-07-28` support,
  isolated as a test-only dependency (its package manager never enters the
  release), and wired into CI alongside the PR 3 fixtures.

Acceptance: the stdio M0 journeys pass unchanged over HTTP; an
unauthenticated request is rejected, with the secret comparison asserted to
use a constant-time primitive (whole-request constant time is not a
testable property); closing the response stream mid-call frees the run; the
container image passes the release verification gate.

## Deferred, separately triggered

Recorded here so the PRs above stay narrow:

- **Pooled provider services** (warm upstream connections retained across
  calls) — the future plan's largest genuinely new engineering item;
  deviation 2 above stages it behind boot validation plus call-time
  revalidation until its own trigger.
- **M1 `eval` and M2 `handles`** — unchanged triggers in the future plan.
- **Config-store and trace-store adapters** (database-backed sources feeding
  `request_memory/3`; run events persisted from `ExecutionOutcome.open/2`;
  on-demand `.jsonl` export for the Viewer).
- **Multi-tenant hosted service** — the future plan's scope tier 3; likely
  the point where the gateway leaves this repository.
- **Outbound OAuth durable store**
  ([`future/mcp-oauth-durable-store.md`](future/mcp-oauth-durable-store.md))
  — a long-running gateway with OAuth-protected upstreams will trigger it.

## Decisions taken (with the reviews of 2026-08-17)

- Sibling application in this repository, not a new repository and not root
  dependencies — atomic changes while 0.x; extraction later if cadence
  diverges.
- The gateway is Elixir: per-VM attestation means an external-language
  gateway would still need a full BEAM-side facade behind an RPC boundary;
  official SDKs serve as conformance clients instead.
- One manifest per exposed tool; no `ReplSession`-backed serving; multiple
  callable entries would be a future manifest-exports feature with
  per-export contracts.
- Two admission layers: the gateway bounds in-flight calls; the runtime
  bounds aggregate provider-task dispatch. Fixing only one does not resolve
  #1290.
- Contracts are required for served manifests in both directions.
- Read-only is fail-closed: anything not provably `:read` refuses the
  template.
