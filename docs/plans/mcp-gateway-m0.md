# MCP gateway M0: implementation slicing

**Status:** active; written 2026-08-17 for issue
[#1465](https://github.com/andreasronge/ptc_runner/issues/1465). This plan
activates mode M0 and scope tier 2 (HTTP, single shared authority) of
[`future/mcp-compose-gateway.md`](future/mcp-compose-gateway.md) and slices
them into four pull requests. The future document remains the product and
design reference; nothing here overrides its decisions or non-goals. The
trigger is satisfied by this repository's operator: real manifests exist that
are worth consuming over MCP from other agents on a private network.

**Claimed scope:** a single-authority, read-only gateway serving a fixed
tool list, one manifest per tool, stdio first, bearer-authenticated
streamable HTTP second. Protocol revision `2026-07-28` only. A fixed tool
list is product policy (stable authority, cacheable surface); the protocol
itself offers `listChanged`/`subscriptions/listen`, which we deliberately do
not use.

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
- `RunCoordinator.prepare/2` recompiles bundles on every run; there is no
  compile-once serving template yet. `effective_application_digest`
  (`effective_application.ex:24-56`) is the ready identity/cache key.
- `Runner.execute_workflow/4` starts the workflow sandbox without
  `link: true` (`runner.ex:202-217`; contrast `evaluation.ex:386`), so a dead
  caller releases resources while the workflow keeps a scheduler until its
  deadline. Documented in `run_coordinator_execution_test.exs:461-482`.
- All runs share one `ReqLLM.Finch` pool with default geometry
  `count: 8, size: 1`; the sizing fix applies only in `:command_vm` mode,
  which admits exactly one LLM-backed run per VM
  (`provider_application_gate.ex:159-172`). Open issue #1290. Per-run limits
  (`live_provider_tasks` 8) do not aggregate across runs.
- The stable public JSON success/error/usage projection lives in command
  internals (`CommandOutcome`), not in a public module a frontend can call.
- Attestation keys are per-VM (`attestation.ex:26-46`): serving templates
  cannot cross nodes or restarts. Each gateway node compiles its own
  templates at boot; the stateless profile makes that sufficient.

## PR 1 — cancellation: link the workflow sandbox

Root project; small; independent value.

- Failing test first: caller death mid-workflow must terminate the sandbox
  promptly (extend the documented gap at
  `run_coordinator_execution_test.exs:461-482`; monitors, no
  `Process.sleep`).
- Add `link: true` to the `Lisp.run_native/2` call in
  `Runner.execute_workflow/4`, mirroring the linked evaluation paths.
- Verify the owner's existing kill-and-drain contract
  (`ExecutionSessionOwner` monitors its caller) now reaches the sandbox on
  both caller-death and deadline paths; provider drain remains bounded.

Acceptance: the new test passes; the full suite is green; no behavior change
for normally completing runs.

## PR 2 — public hosting facade: serving template, host runtime, outcome

Root project; the largest PR; split into 2a/2b if review size demands.

- `PtcRunner.Kernel.ServingTemplate` — `compile(package, catalog, opts)`
  validates and compiles once into an immutable, reusable value: bundle
  compilation, entry validation, compiled contracts, captured
  `application_content_digest` and `effective_application_digest`. For
  serving use it **requires both input and result contracts** and, with
  `effects: :read_only`, refuses an application whose grant includes a
  write-effect tool (the M0 rule). Per-run state never lives here.
- `PtcRunner.Kernel.HostRuntime` — a supervised, host-owned runtime for
  frontends: owns provider-application lifecycle (`:req_llm`/`:llm_db`
  started once, dotenv disabled), owns pool geometry sized for aggregate
  demand, and enforces **aggregate provider-task admission across all
  concurrent runs** — the runtime half of #1290, which per-run
  `live_provider_tasks` cannot express. `call(runtime, template, input,
  opts)` builds a fresh `ExecutionInput`, policy, limits, and sinks, executes
  one ordinary bounded Kernel run, and releases everything on any exit.
  Provider acquisition is per-call in this PR; pooled warm services are
  deferred (see below).
- A public run outcome: a stable, JSON-safe success/error/usage projection
  promoted out of the command internals, suitable for mapping to MCP
  `structuredContent`/`content`/`isError` and namespaced usage `_meta`.
- The `@doc false` chain (`RunCoordinator.execute/4`, `ProviderExecution`)
  is absorbed behind the facade or promoted with documented contracts —
  no gateway code may touch an undocumented module.
- `docs/maintainers/embedding.md` gains the serving section; module docs
  carry the exact contracts.

Acceptance: two concurrent `HostRuntime.call`s with replay LLM providers
share sized pools without starvation; a third call beyond the aggregate
admission ceiling is rejected with a closed diagnostic, not a pool timeout;
existing CLI behavior is unchanged.

## PR 3 — `ptc_gateway/` sibling application: stdio M0

New nested Mix project (the `ptc_viewer`/`ptc_runner_launcher` pattern); no
web dependencies at this stage; root touched only for release assembly,
command declaration, and precommit wiring.

- Static gateway configuration document: a `tools` map from tool name to
  application source (directory or memory), approved description, and
  expected digests, plus the host document reference and admission limits.
  Boot compiles every entry into a `ServingTemplate` via the PR 2 facade and
  **refuses startup** on digest mismatch, missing contracts, or write-effect
  grants.
- Server-side protocol module: `2026-07-28` framing for
  `server/discover` → `tools/list` → `tools/call` plus inbound
  `notifications/cancelled`. `MCPProtocol` stays the client-side validator;
  the server module may share only its transport-independent envelope
  helpers. `inputSchema`/`outputSchema` are the compiled contracts emitted
  verbatim; template digests are reported through a namespaced `_meta`
  extension.
- Bounded in-flight call admission with explicit rejection — no hidden
  queue. Each call runs in its own supervised process so transport
  disconnect kills the request owner and, via PR 1, the run.
- Closed Kernel diagnostics map to MCP tool errors; a private run's result
  stays private.
- Conformance loop in tests: drive the gateway with ptc_runner's **own MCP
  client** (`MCPSource` over the stdio transport pins the same profile),
  the strongest in-repo compatibility check available.
- Release: ship in the standalone release as `ptc serve` following the
  Viewer precedent (probe with `apply/3` so an absent module survives
  Elixir 1.20 compilation; do not prove release content by reading
  `_build`).

Acceptance: a real MCP client (Claude Code or the in-repo client) lists and
calls two tools backed by two manifests over stdio; write-effect
configuration refuses startup; concurrent calls beyond the limit are
rejected; killing the client mid-call frees the run within the drain bound.

## PR 4 — streamable HTTP, single shared authority

`ptc_gateway/` only; this is where Bandit/Plug enter, and they stay out of
the root application.

- Streamable HTTP per the `2026-07-28` transport specification: POST with
  JSON and SSE responses; strict origin/host validation; **response-stream
  closure is cancellation** and must kill the per-request owner.
- Bearer authentication with a file-sourced token (`env`-sourced secrets are
  VM-global and stay out of the gateway's vocabulary).
- `/health` and `/ready` endpoints; readiness covers compiled templates and
  provider-application state.
- Container packaging: artifact-free operation as the default image
  (no `sh`/`mkdir`/`flock`/hard-link requirements); the artifact-enabled
  variant documents its platform needs. Loopback binding by default;
  private-network binding is an explicit operator choice.
- External conformance: exercise the endpoint with an official MCP SDK
  client as a test harness (the SDK is a conformance tool here, not a
  product dependency).

Acceptance: the stdio M0 journeys pass unchanged over HTTP; an
unauthenticated request is rejected; closing the response stream mid-call
frees the run; the container image passes the release verification gate.

## Deferred, separately triggered

Recorded here so the PRs above stay narrow:

- **Pooled provider services** (warm upstream MCP connections across calls)
  — the future plan names defining their ownership/cleanup/drift-recheck
  contract as its largest genuinely new engineering item; per-call
  acquisition is correct first.
- **M1 `eval` and M2 `handles`** — unchanged triggers in the future plan.
- **Config-store and trace-store adapters** (database-backed sources feeding
  `request_memory/3`; run events persisted from `ExecutionOutcome.open/2`;
  on-demand `.jsonl` export for the Viewer).
- **Multi-tenant hosted service** — the future plan's scope tier 3; likely
  the point where the gateway leaves this repository.
- **Outbound OAuth durable store**
  ([`future/mcp-oauth-durable-store.md`](future/mcp-oauth-durable-store.md))
  — a long-running gateway with OAuth-protected upstreams will trigger it.

## Decisions taken (with the review of 2026-08-17)

- Sibling application in this repository, not a new repository and not root
  dependencies — atomic changes while 0.x; extraction later if cadence
  diverges.
- The gateway is Elixir: per-VM attestation means an external-language
  gateway would still need a full BEAM-side facade behind an RPC boundary;
  official SDKs serve as conformance clients instead.
- One manifest per exposed tool; no `ReplSession`-backed serving; multiple
  callable entries would be a future manifest-exports feature with
  per-export contracts.
- Two admission layers (gateway in-flight limit + runtime aggregate provider
  admission); fixing only one does not resolve #1290.
- Contracts are required for served manifests in both directions.
