# Root Upstream Runtime

High-level architecture for moving transport-neutral upstream tools into the
root `ptc_runner` library while keeping `mcp_server` as a thin MCP
presentation/runtime wrapper.

Status: extraction direction approved; much of the upstream subsystem now lives
in root. Treat this document as an upstream-provider extraction record and
remaining-contracts note. The active architecture source is
[`capability-kernel-runtime.md`](capability-kernel-runtime.md), whose current
path is `PtcRunner.Lisp.RunEnv` first, upstream projection next, and a generic
runtime later.

The older provider-owned Lisp convenience shape in this document should be read
as superseded. Upstream should project `PtcRunner.Upstream.RunContext` into a
`PtcRunner.Lisp.RunEnv`; `PtcRunner.Lisp` remains the owner of evaluation.

The blocking contracts are:

- runtime handle lifecycle;
- per-run budget/context ownership and teardown;
- separate catalog exposure and snapshot semantics;
- explicit naming for MCP client transports in root;
- transport-owned result normalization so root does not depend on MCP envelopes;
- config, dependency, redaction, and REPL precedence decisions.

## Motivation

Upstream tools are useful outside the MCP server. A local `mix ptc.repl`,
in-process `PtcRunner.Lisp.run/2`, subagents, and future non-MCP runtimes should
be able to call curated external tools such as OpenAPI endpoints without going
through an MCP server process.

Today, most upstream machinery lives under `mcp_server`:

- upstream JSON config parsing;
- credentials and redaction;
- upstream supervision and registry;
- catalog/discovery rendering;
- OpenAPI schema loading and execution;
- `tool/call` wiring used by MCP tool execution.

That makes `mcp_server` heavier than it needs to be and makes OpenAPI tools feel
MCP-specific even though the concept is transport-neutral.

The target split is:

- `ptc_runner` owns PTC-Lisp, tool execution, upstream config, upstream
  transports, discovery, catalog metadata, credentials, limits, and reusable
  runtime services.
- `mcp_server` owns only the MCP presentation/runtime surface needed to expose
  `ptc_runner` over MCP: stdio/HTTP JSON-RPC, MCP envelopes, MCP tool
  advertisements, MCP sessions, MCP debug/trace presentation, release packaging,
  and server boot configuration.

## Goals

- Make OpenAPI and MCP upstreams available from root `mix ptc.repl`.
- Let library callers attach upstream capabilities to `PtcRunner.Lisp.run/2`,
  root REPL evaluations, MCP evaluations, and higher-level SubAgent loops
  through a closeable upstream run context projected into a Lisp run
  environment.
- Keep the public PTC-Lisp upstream surface transport-neutral:
  `(tool/call ...)`, `(tool/servers)`, `dir`, `doc`, `meta`, and `apropos`.
- Preserve the already-root-side PTC-Lisp authoring model and remove only dead
  MCP namespace hints.
- Preserve existing sandbox safety: auth material is never visible to PTC-Lisp,
  upstream calls are capped, catalog/discovery has separate caps, and all
  external failures return recoverable tagged values where possible.
- Keep `mcp_server` thin by delegating upstream runtime setup and execution to
  root modules.
- Avoid circular dependencies: root `ptc_runner` must not depend on
  `ptc_runner_mcp`.
- Keep long-lived upstream runtime state separate from per-program evaluation
  state so concurrent `PtcRunner.Lisp.run/2` calls cannot share live counters.

## Non-goals

- Keep backward-compatible MCP-specific Lisp aliases indefinitely. This is a
  0.x library; prefer removal once the replacement is documented and tested.
- Turn root `ptc_runner` into an MCP server.
- Make OpenAPI a general API gateway. The first reusable OpenAPI adapter should
  remain curated, explicitly included, read-only JSON `GET` operations.
- Expose auth headers, credentials, or redaction internals to PTC-Lisp programs.
- Add a pure non-process upstream runtime before there is a concrete embedding
  use case. Caller-managed `start_link/1` plus `stop/1` is the explicit
  lifecycle for now.

## Proposed Module Boundary

Root `ptc_runner` should gain a transport-neutral upstream subsystem, likely
under `PtcRunner.Upstream`.

Candidate root modules:

- `PtcRunner.Upstream.Config` parses upstream JSON and returns normalized
  upstream entries plus credential bindings.
- `PtcRunner.Upstream.Credentials` materializes env/file/literal credentials and
  owns redaction helpers.
- `PtcRunner.Upstream.Runtime` starts/stops a configured upstream runtime and
  exposes a handle for long-lived upstream services.
- `PtcRunner.Upstream.RunContext` creates and tears down per-evaluation
  call/discovery budgets, collectors, and tool closures for a single
  `Lisp.run/2`.
- `PtcRunner.Upstream.Collector` owns each run's call-record buffer.
- `PtcRunner.Upstream.Result` is the transport-neutral result contract returned
  by upstream transports.
- `PtcRunner.Upstream.Registry` stores configured upstreams and cached catalog
  metadata.
- `PtcRunner.Upstream.Catalog` renders structured discovery data and prompt
  snippets without MCP-specific envelope concerns.
- `PtcRunner.Upstream.CallTool` builds the `tools:` map for
  `PtcRunner.Lisp.run/2`, including `(tool/call ...)`, from a fresh run context.
- `PtcRunner.Upstream.OpenAPI` owns schema load/compile/execute for curated
  OpenAPI operations.
- `PtcRunner.Upstream.Transport.McpStdio` and
  `PtcRunner.Upstream.Transport.McpHttp` own MCP upstream client transports.
  These are MCP clients, not the MCP server.

`mcp_server` should keep modules that are specifically about serving MCP:

- JSON-RPC framing and protocol negotiation.
- Stdio and Streamable HTTP MCP server transports.
- MCP `tools/list` and `tools/call` presentation.
- MCP response envelopes and response profiles.
- Stateful MCP session tools and owner/session lifecycle.
- MCP debug tool, trace files, and operator-facing diagnostics.
- Release, Docker, and server CLI packaging.

## Runtime Shape

Root upstream callers should use OTP-backed provider/runtime handles when
upstream transports need lifecycle. There are two ownership styles, but both use
the same OTP implementation:

- caller-managed start/stop for REPLs, scripts, tests, and embedded callers;
- app-supervised children for `mcp_server` and future long-running
  applications.

A pure non-process runtime is intentionally deferred until a concrete embedding
case needs it.

### Caller-Managed Runtime

For REPLs, scripts, tests, and embedded callers:

```elixir
{:ok, runtime} =
  PtcRunner.Upstream.Runtime.start_link(
    config_path: "upstreams.json",
    catalog_exposure_mode: :auto,
    catalog_snapshot_mode: :live
  )

PtcRunner.Upstream.Eval.with_run_context(runtime,
  max_tool_calls: 50,
  max_catalog_ops: 25
}, fn run_context ->
  upstream_opts = PtcRunner.Upstream.Eval.eval_options(run_context)

  PtcRunner.Lisp.run(program,
    Keyword.merge(upstream_opts,
      memory: memory,
      turn_history: history
    )
  )
end)
```

The runtime owns long-lived state: normalized config, credentials, upstream
clients/connections, registry, cached metadata, and default limits. It should be
stoppable with `PtcRunner.Upstream.Runtime.stop/1`.

`with_run_context/3` must mint fresh per-program state for each evaluation:

- call counters;
- discovery counters;
- a short-lived collector process;
- `(tool/call ...)` closures;
- `discovery_exec` closures.

The near-term cleanup should attach upstream by projecting this run context into
`PtcRunner.Lisp.RunEnv`. A future neutral `PtcRunner.Runtime.with_run/3` can
generalize that shape after another lifecycle-bearing provider needs it. Lisp
evaluation remains owned by `PtcRunner.Lisp`, not by `PtcRunner.Upstream`.

Do not expose a reusable `Runtime.tools(runtime)` API for evaluation. Reusing
the same tool closure map across evaluations risks sharing live counters between
independent or concurrent programs.

Avoid `Runtime.eval_options/2` as a bare options-only API. If that function
exists at all, it must return a closeable run context with the options so
callers cannot accidentally leak collectors in long-lived REPL and subagent
processes.

### App-Supervised Runtime

For `mcp_server` and future long-running applications:

```elixir
children = [
  {PtcRunner.Upstream.Runtime, upstream_runtime_opts},
  {PtcRunnerMcp.Server, mcp_opts}
]
```

`mcp_server` should read CLI/env values, build root upstream runtime options,
start the root runtime as a child, and pass the runtime handle to MCP tool and
session handlers.

Each MCP `tools/call` or session evaluation must create a fresh
`PtcRunner.Upstream.RunContext` while reusing the same long-lived runtime
handle. MCP handlers should use the lower-level context API so they can drain
call records before closing the context and rendering MCP envelopes.

## Root `mix ptc.repl`

Root `mix ptc.repl` should grow upstream options without importing MCP server
behavior:

```bash
mix ptc.repl --upstreams-config ./upstreams.json
mix ptc.repl --upstreams-config ./upstreams.json --eval "(tool/servers)"
mix ptc.repl --upstreams-config ./upstreams.json --eval \
  "(tool/call 'observatory/list-traces {:limit 3})"
```

The root REPL should:

- start a root upstream runtime when `--upstreams-config` or
  `PTC_RUNNER_UPSTREAMS` is present;
- create a fresh run context for every `Lisp.run/2`;
- preserve REPL memory and turn history exactly as today;
- print PTC-Lisp values, not MCP envelopes;
- expose upstream-aware discovery commands without breaking existing built-in
  docs.

Existing REPL commands for built-in function docs keep precedence. For example,
`:doc reduce` and `apropos` over local Clojure-style functions must keep working
when a runtime is active. If a ref is not found locally, the REPL may fall back
to upstream discovery. `:tools` should show configured upstream tools plus local
tool namespace information; it must not replace local docs.

Environment variables should use root names such as `PTC_RUNNER_UPSTREAMS`.
`mcp_server` may continue accepting `PTC_RUNNER_MCP_UPSTREAMS` as its server
CLI/env surface, but should translate it into root runtime options internally.

## MCP Server Integration

After extraction, `mcp_server` should stop owning upstream internals.

Boot flow:

1. Parse MCP server CLI/env options.
2. Translate upstream-related options into `PtcRunner.Upstream.Runtime` options.
3. Start the root upstream runtime if upstreams are configured.
4. Start MCP stdio or HTTP server transport.
5. On `tools/list`, ask the root runtime for catalog/discovery metadata using
   the runtime's catalog exposure and snapshot modes, then render MCP-facing
   tool descriptions.
6. On `tools/call`, create a run context, run `PtcRunner.Lisp.run/2` with its
   eval options, drain records, close the context, then wrap the result in MCP
   envelopes.
7. For session tools, store only session state and pass the same root runtime
   handle into each session evaluation while creating new per-run contexts.

The MCP server may still own MCP-specific response shaping:

- slim/structured/debug envelope profiles;
- `structuredContent` choices;
- `isError` mapping;
- MCP debug records;
- MCP request IDs and transport-level telemetry.

It should not own OpenAPI compilation, upstream call semantics, credential
materialization, or catalog source-of-truth data.

MCP envelope normalization is a transport concern. MCP client transports should
unwrap MCP `content`, `isError`, raw-envelope policy, and JSON text content into
`PtcRunner.Upstream.Result` before `CallTool` sees the value. OpenAPI transports
return plain decoded JSON through the same result contract and must not pass
through MCP envelope assumptions.

## Config Ownership

The upstream JSON format should become root-owned documentation. The config
should avoid MCP-specific names unless an upstream transport is explicitly an
MCP client transport.

Example:

```json
{
  "credentials": {
    "observatory_token": {
      "source": "env",
      "var": "OBSERVATORY_TOKEN",
      "scheme_hint": "bearer"
    }
  },
  "upstreams": {
    "observatory": {
      "transport": "openapi",
      "base_url": "https://observatory.example.com",
      "schema_file": "./observatory.openapi.json",
      "include_operations": ["listTraces", "getTrace"],
      "auth": [
        {"scheme": "bearer", "binding": "observatory_token"}
      ]
    }
  }
}
```

MCP client upstreams remain valid transport entries:

```json
{
  "upstreams": {
    "filesystem": {
      "transport": "mcp_stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
    }
  }
}
```

Use explicit MCP-client transport names in root-owned config:

- `"transport": "mcp_stdio"` for MCP clients launched over stdio;
- `"transport": "mcp_http"` for MCP clients reached over Streamable HTTP/SSE;
- `"transport": "openapi"` for curated OpenAPI JSON operations.

Avoid bare names such as `"stdio"` in root docs because they hide that the
transport is an MCP client transport, not generic process stdio and not the MCP
server itself.

This is a breaking 0.x config migration from the current MCP server parser,
which accepts `"stdio"`, `"http"`, and absent transport as implicit stdio. The
root parser should fail loudly on old names after docs and fixtures are updated,
unless a short transitional parser is intentionally added for one release. The
implementation checklist must include fixture, example, and test churn for this
rename.

The actual JSON config parser currently lives mostly in
`PtcRunnerMcp.Application` (`load_aggregator_config/1`,
`parse_upstream_entry/3`, transport validation, credential binding validation,
URL/scheme/static-header/proxy validation). Extraction work should move that
parser to `PtcRunner.Upstream.Config`; `PtcRunnerMcp.AggregatorConfig` is only a
persistent-term store for MCP aggregator flags and is not the parser.

## Dependency Ownership

Moving OpenAPI and MCP HTTP client transports to root changes root dependencies.
The plan must keep those dependencies explicit:

- `Req`/`Finch` are required for OpenAPI schema loading, OpenAPI execution, and
  MCP HTTP client transports. If root keeps `Req` optional, config validation
  must fail closed with a clear error when a configured transport needs it and
  the dependency is unavailable.
- Local HTTP fixture tests currently supplied by `mcp_server` may require
  root test-only dependencies such as `Plug`/`Bandit`, or equivalent lightweight
  fixtures. Keep those as test dependencies unless production root code needs
  them.
- MCP server HTTP transports remain in `mcp_server`; only MCP client transports
  move to root.

Do not silently make `mix ptc.repl --upstreams-config` accept OpenAPI config
that later fails because `Req` is absent.

## Naming Decision

`Upstream` is already used in root audit tooling to mean Clojure/Java reference
runtimes. This plan keeps `PtcRunner.Upstream` for now because the existing MCP
aggregator code, docs, and operator terminology already use "upstream" for
external tool servers. If the project wants to avoid that collision before
implementation, rename the whole proposed namespace consistently to
`PtcRunner.ToolServers` or `PtcRunner.Connectors`; do not mix names inside the
same extraction.

## Runtime Contracts

### Lifecycle

`PtcRunner.Upstream.Runtime` is OTP-backed. Caller-managed usage starts it with
`start_link/1` and stops it with `stop/1`; server usage starts it under a
supervisor. The runtime handle is safe to reuse across evaluations and sessions,
but only for long-lived state.

The root runtime must not require `ptc_runner_mcp` and must not start any MCP
server transport.

### Per-Run State And Teardown

Every `PtcRunner.Lisp.run/2` must receive fresh upstream evaluation options.
The fresh options include `tools:` and `discovery_exec:` closures that capture a
new run context. The run context owns live counters and collectors for one
program only.

Per-run caps must behave like the current MCP aggregator call context:
parallel `pmap` children within one program share the same counters, but two
independent `Lisp.run/2` calls do not.

Each run context must own a short-lived collector process. The collector process
owns:

- the in-process list of sanitized upstream call records;
- the call record drain operation.

Closures running in the main evaluator or in `pmap` children send records to
the collector process, not to the caller's long-lived process. Closing the run
context stops the collector, which discards any undrained record buffer and
prevents `{:upstream_call_recorded, ...}` messages from accumulating in REPL or
subagent mailboxes.

Public APIs must make teardown hard to forget:

- `PtcRunner.Upstream.Eval.with_run_context/3` creates a context, yields it to the supplied
  function, drains records after the function returns, closes in `after`, and
  returns `{fun_result, records}`.
- Lower-level `PtcRunner.Upstream.Eval.run_context/2` is available for MCP
  server code that needs manual drain timing, but callers must close it in
  `after`.

If a Lisp-specific helper is kept, it should be a thin convenience over
`PtcRunner.Lisp.RunEnv` construction and internally use the same closeable
run-context contract.

Drain completeness depends on BEAM message ordering and synchronous evaluator
joins, not on the collector being `self()`. Local `send/2` enqueues the record
before the sending closure returns, and `Lisp.run/2` waits for all tool
closures, including `pmap` children, before returning. A drain performed after
the run must therefore see every record emitted by completed call closures,
whether the collector is the caller process or a separate collector process.

Cancellation or evaluator crashes should still stop the collector and discard
undrained call records. If a collector is linked to the evaluator worker,
document the linking strategy so MCP cancellation keeps the current cleanup
guarantee.

### Result Contract

Root upstream transports return a transport-neutral result:

```elixir
{:ok, json_value}
{:error, reason, message}
```

`reason` uses the existing closed failure set where possible, such as
`:upstream_unavailable`, `:upstream_error`, `:tool_error`, `:auth_failed`,
`:rate_limited`, `:timeout`, and `:response_too_large`.

MCP envelope details are normalized inside MCP client transports:

- `isError` becomes `{:error, :tool_error, message}` or a more specific reason.
- text content and JSON text auto-decode happen before returning to `CallTool`.
- raw envelope retention is a transport option for diagnostics, not the value
  exposed to PTC-Lisp.

OpenAPI transports return decoded response JSON directly. `CallTool` performs
argument validation, budget enforcement, world-fault tagging, and call-record
construction; it does not inspect MCP envelope shapes.

### Redaction Scope

Redaction state must be scoped deliberately before supporting multiple root
runtimes in one VM. The safe default is a redactor handle stored in runtime
state and copied into each run context. All call records, previews, error
details, traces, catalog text, and diagnostics must scrub through that handle.

A single global redaction set is acceptable only if the plan explicitly accepts
cross-runtime over-redaction. Do not accidentally switch to per-runtime redaction
without threading the correct redactor handle into every transport and
`RunContext` path.

### Catalog And Discovery

The runtime separates two catalog axes:

- catalog exposure mode: existing `:auto | :inline | :lazy`, controlling how
  much catalog detail is inlined into advertised tool descriptions;
- catalog snapshot mode: new `:frozen | :live`, controlling whether advertised
  catalog data is fixed at startup or may refresh during runtime.

Do not reuse `--catalog-mode` for snapshot behavior. On the root REPL, use
`--catalog-mode` for exposure mode as well, matching the existing MCP meaning,
or rename it explicitly to `--catalog-exposure-mode` in a breaking CLI cleanup.
Use a separate flag such as `--catalog-snapshot-mode` for `:frozen | :live`.

Snapshot modes:

- `:frozen` snapshot mode renders the advertised catalog once after startup.
  This is the MCP `tools/list` default so clients see stable tool descriptions
  for the lifetime of the server process.
- `:live` snapshot mode lets REPL and embedded callers refresh or populate
  missing cached metadata during discovery forms.

Discovery forms may still attempt live lookup for missing tools when the runtime
is configured for live discovery. In frozen mode, live discovery must not mutate
the advertised catalog snapshot; if it populates internal caches for call
validation, that behavior must be documented and tested separately.

Caller defaults should be explicit: MCP server integration should pass
`catalog_snapshot_mode: :frozen`; root REPL should pass
`catalog_snapshot_mode: :live` unless the user asks otherwise. Avoid hidden
runtime guessing based on caller identity.

## Implementation Solution Outline

Implement this as an extraction and narrowing project, not as a new upstream
system built beside the existing one. The current `mcp_server` implementation
already has the important runtime pieces: config parsing, credentials,
transport behaviours, registry/connection supervision, call contexts,
catalog/discovery rendering, and OpenAPI compile/execute. Move those pieces to
root in small commits, keep their behavior covered by migrated tests, then
delete the MCP-owned duplicates.

### Public Root API

Introduce these root entry points first so later phases have a stable target:

- `PtcRunner.Upstream.Runtime.start_link/1` starts the OTP runtime and returns
  a reusable handle.
- `PtcRunner.Upstream.Runtime.child_spec/1` lets apps supervise the same
  runtime.
- `PtcRunner.Upstream.Runtime.stop/1` stops caller-managed runtimes
  idempotently.
- `PtcRunner.Upstream.Eval.run_context/2` creates one fresh
  `%PtcRunner.Upstream.RunContext{}` for one `Lisp.run/2`.
- `PtcRunner.Upstream.Eval.with_run_context/3` creates a context, yields it,
  drains call records after the callback returns, closes in `after`, and
  returns `{fun_result, records}`.
- `PtcRunner.Upstream.Eval.eval_options/1` returns the `tools:` and
  `discovery_exec:` options to merge into `PtcRunner.Lisp.run/2`.
- `PtcRunner.Upstream.RunContext.drain_calls/1` returns call records after a
  run for MCP envelope rendering, tests, traces, and future diagnostics.
- `PtcRunner.Upstream.RunContext.close/1` stops the collector and is idempotent.
- `PtcRunner.Upstream.Runtime.catalog_snapshot/1` returns structured catalog
  data from the runtime's configured catalog snapshot mode.
- `PtcRunner.Upstream.Runtime.catalog_text/1` renders the prompt-friendly
  catalog string from that snapshot using the configured exposure mode.
- `PtcRunner.Upstream.Runtime.diagnostics/1` returns non-secret runtime facts:
  configured upstream names, selected catalog exposure mode, selected catalog
  snapshot mode, loaded catalog status, transport names, and limit values.

The important upstream-provider API shape is `with_run_context/3` plus a Lisp
projection; this keeps the per-run collector drainable by the MCP server and by
future runtime projections.

### Module Extraction Map

Use the existing MCP modules as the implementation source where possible:

| Current module | Root destination | Notes |
| --- | --- | --- |
| `PtcRunnerMcp.Upstream` | `PtcRunner.Upstream.Transport` | Rename the behaviour so it is not MCP-server-specific. Keep client MCP transports explicit. |
| `PtcRunnerMcp.UpstreamCalls` | `PtcRunner.Upstream.RunContext`, `Collector`, and call-record helpers | Keep atomics counters and call record shapes, but move call-record ownership into a short-lived collector process. |
| `PtcRunnerMcp.McpResult` | `PtcRunner.Upstream.Result` | Rename and remove MCP envelope naming. Transports normalize into this root result contract. |
| `PtcRunnerMcp.RawEnvelopePolicy` | MCP transport config plus diagnostics | Keep raw MCP envelope retention transport-specific; do not make neutral `CallTool` depend on it. |
| `PtcRunnerMcp.AggregatorTools` | `PtcRunner.Upstream.CallTool` | Preserve the existing `tool/call` Lisp surface and programmer-fault versus world-fault split. Move MCP envelope unwrapping into MCP client transports. |
| `PtcRunnerMcp.CatalogBuiltins` | `PtcRunner.Upstream.Discovery` | Keep `tool/servers`, `dir`, `doc`, `meta`, and `apropos` semantics. |
| `PtcRunnerMcp.Upstream.Registry` and `Connection` | `PtcRunner.Upstream.Registry` and `Connection` | Preserve per-upstream connection processes and restart-safe via-registry lookup. |
| `PtcRunnerMcp.Upstream.Supervisor` | `PtcRunner.Upstream.Runtime` | Convert the server-specific supervisor into the root runtime facade. |
| `PtcRunnerMcp.Upstream.Catalog` | `PtcRunner.Upstream.Catalog` | Replace global `:persistent_term` with runtime-owned frozen snapshots unless profiling proves it necessary. |
| `PtcRunnerMcp.Upstream.OpenApi.*` | `PtcRunner.Upstream.OpenAPI.*` | Move mostly unchanged; update aliases to root credentials and transport behaviour. |
| `PtcRunnerMcp.Credentials.*` | `PtcRunner.Upstream.Credentials.*` | Keep materialization, redaction, and denylist behavior; remove MCP envelope assumptions. |
| `PtcRunnerMcp.Application` config parser helpers | `PtcRunner.Upstream.Config` | Move `load_aggregator_config/1`, upstream entry parsing, transport dispatch, credential binding refs, URL/scheme/static-header/proxy validation, and raw-envelope transport options. |
| `PtcRunnerMcp.AggregatorConfig` | stays MCP or becomes small server option adapter | It is not the JSON parser; it stores read-only/raw-envelope aggregator flags. Do not use it as the extraction source for root config parsing. |

MCP-only modules such as `PtcRunnerMcp.Tools`, `Envelope`, `ResponseProfile`,
`Sessions`, stdio/HTTP server transports, debug records, and release packaging
must remain in `mcp_server`.

### Runtime Supervision

`PtcRunner.Upstream.Runtime` should be a small OTP supervisor/facade, not a
large GenServer that performs all work itself. Its child tree should include:

- a root credentials/redactor process or table when credential bindings exist;
- a registry process that owns configured upstream entries and static metadata;
- a dynamic supervisor for per-upstream connection workers;
- any transport-specific registries currently required by stdio, MCP HTTP, or
  OpenAPI clients.

The runtime handle should be either the runtime process pid/name or a small
struct containing that pid/name. Prefer a struct if callers need diagnostics
without guessing process names:

```elixir
%PtcRunner.Upstream.Runtime{
  pid: pid,
  catalog_exposure_mode: :auto,
  catalog_snapshot_mode: :frozen
}
```

Avoid global runtime names in root tests and embedded examples. Named runtime
registration can remain an option for app-supervised use, but the default
caller-managed path should be isolated and parallel-test friendly.

### Runtime Startup

Startup should run in this order:

1. Parse `config_path`, `config_json`, or direct config data through
   `PtcRunner.Upstream.Config`.
2. Materialize credential bindings into root credential state.
3. Normalize upstream entries to `%{name, transport, impl, config, metadata}`.
4. Start the registry and one connection wrapper per configured upstream.
5. Apply catalog exposure mode (`:auto | :inline | :lazy`) for advertised
   prompt rendering.
6. Apply catalog snapshot mode:
   - `:frozen`: eagerly list tools and store a runtime-owned structured
     snapshot, preserving unavailable placeholders for failed upstreams.
   - `:live`: do not eagerly force all upstreams unless explicitly requested;
     discovery may populate caches later.
7. Store default limits in runtime state for later per-run contexts.

Do not fetch OpenAPI schemas or MCP `tools/list` from inside `Lisp.run/2`
except when live discovery explicitly needs to fill a missing cache.

### Per-Run Context

`PtcRunner.Upstream.RunContext` should be a struct wrapping the current
`UpstreamCalls.call_context` data and adding the runtime handle:

```elixir
%PtcRunner.Upstream.RunContext{
  runtime: runtime,
  collector_pid: pid,
  collector_ref: ref,
  call_counter: atomics,
  catalog_op_counter: atomics,
  failure_cache: tid,
  redactor: redactor,
  limits: limits
}
```

`RunContext.new(runtime, opts)` should start a collector process, allocate
per-run atomics, and merge runtime defaults with per-run overrides such as
`max_tool_calls`, `max_catalog_ops`, `call_timeout_ms`, `max_response_bytes`,
and `max_catalog_result_bytes`.

The generated closures must capture the run context. They must not read live
budget counters from runtime state, application env, the process dictionary, or
global ETS. Parallel `pmap` children inside one Lisp program must share the
same atomics; separate `Lisp.run/2` invocations must never do so.

All normal caller paths should use `with_run_context/3`. A future
`PtcRunner.Runtime.with_run/3` projection may delegate to it once a neutral
runtime exists. Manual users of `run_context/2` must close the context in
`after`.

### Tool Call Execution

`PtcRunner.Upstream.CallTool.build/2` should build the root `tools:` map:

```elixir
%{"call" => call_closure}
```

The Lisp surface remains `(tool/call ...)`; the `"call"` key is the tool name
under the existing `tool/` Lisp namespace. The closure should:

1. Accept both the map form and qualified-symbol form once the parser/runtime
   supports symbols there.
2. Validate configured upstream name and known cached tool using the registry.
3. Validate JSON-encodable args and cheap required-key checks from cached input
   schemas.
4. Enforce per-program call caps through the run context.
5. Serialize `ensure_started/1` attempts per upstream within the run context.
6. Dispatch to the root transport implementation.
7. Return tagged PTC-Lisp values for recoverable world faults.
8. Raise `PtcRunner.Lisp.ExecutionError` for programmer faults.
9. Record sanitized call entries through `RunContext`.

The closure must consume `PtcRunner.Upstream.Result` values only. It must not
inspect MCP-specific envelope fields such as `isError`, `content`, or raw
envelope metadata.

The initial extraction may keep the map form as the only implemented call
syntax if qualified-symbol dispatch requires parser/runtime changes. If so,
this must be called out in release notes and tests.

### Discovery Execution

Move discovery into root as `PtcRunner.Upstream.Discovery`. It should expose a
closure compatible with the current `discovery_exec:` option and support:

- `tool/servers`;
- `dir`;
- `doc`;
- `meta`;
- `apropos`;
- internal `apropos_matches` if still needed by agentic summaries.

Discovery should read from the runtime catalog snapshot first. In `:live`
snapshot mode, it may call `ensure_started/1` and update connection caches when
a server has no tools loaded. In `:frozen` snapshot mode, it must not change the
advertised snapshot.

### Catalog Storage

Prefer runtime-owned catalog state over root-level `:persistent_term`.
`:persistent_term` currently works for a single MCP server process, but it is a
poor default for root library callers that may start multiple independent
runtimes in one VM. If a frozen prompt string needs a fast cache, keep it inside
the runtime process state or in an ETS table owned by the runtime supervisor.

### Root REPL Wiring

Extend `mix ptc.repl` after the root runtime exists:

- parse `--upstreams-config`, `--max-tool-calls`, `--max-catalog-ops`,
  `--upstream-call-timeout-ms`, `--max-upstream-response-bytes`, and
  `--catalog-mode` for exposure plus `--catalog-snapshot-mode` for
  frozen/live behavior;
- fall back to `PTC_RUNNER_UPSTREAMS` when no flag is supplied;
- start a caller-managed root runtime only when upstream config is present;
- for every eval, create a new run context and merge its eval options with the
  existing memory and turn-history options;
- keep existing built-in `:doc`, `:find`, and `:apropos` precedence, then fall
  back to upstream discovery when a local ref/query does not resolve;
- route upstream-specific `:tools` and later `:dir` through root discovery when
  an upstream runtime is active;
- stop the runtime on normal REPL exit and after one-shot eval/file/stdin runs.

The REPL should print PTC-Lisp values and local errors only. It should not render
MCP envelopes, response profiles, or MCP debug records.

### MCP Server Rewire

After root OpenAPI and MCP-client transports work from `mix ptc.repl`, change
`mcp_server` to consume the root runtime:

1. Keep MCP CLI/env parsing in `PtcRunnerMcp.Application`.
2. Translate upstream config flags and server env aliases into root runtime
   options.
3. Start `PtcRunner.Upstream.Runtime` as a child when upstreams are configured.
4. Pass the runtime handle to stateless `lisp_eval` and session eval handlers.
5. In every MCP request/session eval, create a root run context, run Lisp with
   its eval options, drain call records for MCP envelopes, then close the
   context in `after`.
6. Render `tools/list` descriptions from root catalog text plus MCP-owned prompt
   cards.
7. Keep MCP response shaping, debug output, trace files, request IDs, sessions,
   and transport telemetry in `mcp_server`.

Once that path is green, delete `PtcRunnerMcp.Upstream.*`,
`PtcRunnerMcp.AggregatorTools`, `PtcRunnerMcp.CatalogBuiltins`, and duplicated
credential/config modules.

### Implementation Checkpoints

Use these checkpoints to keep the migration reviewable:

1. Add empty root namespace, structs, behaviours, and no-op tests.
2. Move result, call-record, and collector contracts.
3. Move credentials, redaction, and redactor-scope tests.
4. Move config parsing out of `PtcRunnerMcp.Application` with breaking
   transport names `openapi`, `mcp_stdio`, and `mcp_http`; update fixtures,
   examples, and docs.
5. Move OpenAPI compiler/loader/executor and prove it works from root tests.
6. Move registry, connection, and MCP-client transports; normalize MCP envelopes
   inside MCP client transports.
7. Add runtime startup, catalog exposure/snapshot modes, and run-context eval
   option generation.
8. Wire root `mix ptc.repl` with built-in doc precedence.
9. Rewire `mcp_server` to root runtime.
10. Delete old MCP-owned upstream modules. Lisp alias cleanup is trivial because
    the live surface is already `tool/call`; only dead `mcp/` namespace hints
    should remain to remove.

## Remaining Implementation Details

The following details remain implementation choices, not contract blockers:

- The exact return shape for `Runtime.start_link/1`: pid/name only versus a
  `%Runtime{}` handle struct. A struct is likely better for diagnostics and
  multi-runtime tests.
- Whether frozen snapshot mode must eagerly start every MCP stdio/http upstream
  at runtime startup. Existing MCP behavior freezes a startup catalog, but root
  embedded callers may prefer faster startup and unavailable placeholders. The
  selected behavior must be visible in diagnostics.
- Whether OpenAPI schema load failures should fail the whole runtime in
  `catalog_snapshot_mode: :frozen` or mark only that upstream unavailable.
  Current behavior tends to stop that upstream; the root runtime should document
  whether partial startup is allowed.
- Whether the qualified-symbol form
  `(tool/call 'observatory/list-traces {:limit 3})` can be implemented without
  parser/runtime changes. The map form should remain the implementation
  fallback until that is confirmed.
- Where root call records should appear outside MCP. They may remain a
  `RunContext.drain_calls/1` side channel, but tracing and subagent loops may
  want a first-class `step.upstream_calls` field later.
- Whether the namespace remains `PtcRunner.Upstream` or is renamed
  consistently before implementation to avoid the audit-upstream terminology
  collision.

## Migration Strategy

1. Introduce root `PtcRunner.Upstream` behaviour, OTP runtime facade,
   closeable collector-backed run context, and result contract while keeping
   existing `mcp_server` modules in place.
2. Move pure, transport-neutral code first: catalog metadata, call result
   contracts, call budget records, OpenAPI schema compiler, and config shape
   validation.
3. Move credentials and redaction next, preserving all current security tests
   and defining redactor scope.
4. Move JSON config parsing out of `PtcRunnerMcp.Application`, including the
   breaking `mcp_stdio`/`mcp_http` transport rename.
5. Move OpenAPI execution into root and wire it into root `mix ptc.repl`.
6. Move MCP upstream client transports into root as client transports only,
   with MCP envelope normalization inside those transports.
7. Change `mcp_server` to start and consume root upstream runtime.
8. Delete duplicated `PtcRunnerMcp.Upstream.*` modules after the MCP server no
   longer owns upstream execution.
9. Update docs so upstream config is documented as a root `ptc_runner` feature;
   MCP docs should reference it rather than define it.

## Testing Requirements

- Root unit tests for upstream config parsing, credentials, redaction, OpenAPI
  compilation, and OpenAPI execution against local fixtures.
- Root unit tests proving `PtcRunner.Upstream.Eval.with_run_context/3` creates fresh per-run
  counters while preserving shared counters across parallel calls inside one
  program.
- Collector lifecycle tests proving collectors stop cleanly and caller mailboxes
  do not retain upstream call records across repeated REPL/subagent evaluations.
- Drain-completeness tests proving a program that performs N `(tool/call ...)`
  invocations inside `pmap` returns all N records from
  `RunContext.drain_calls/1` with the separate collector process.
- Transport result tests proving MCP envelope unwrapping stays inside MCP
  client transports and OpenAPI returns plain decoded JSON through the same
  root result contract.
- Root REPL tests for `--upstreams-config`, `(tool/servers)`, `dir`, `doc`,
  `apropos`, and `(tool/call ...)`.
- Root REPL tests proving built-in `:doc`, `:find`, and `:apropos` precedence
  remains intact when an upstream runtime is active.
- Root `Lisp.run/2` tests proving upstream tools work without `mcp_server`.
- MCP server regression tests proving MCP `tools/list`, `lisp_eval`,
  sessions, response profiles, and debug output still work when backed by the
  root runtime.
- Security tests proving credentials never appear in PTC-Lisp results, traces,
  logs, catalog descriptions, or MCP envelopes.
- Multi-runtime security tests proving redaction uses the intended runtime
  redactor scope, or proving global over-redaction is intentional.
- Failure-mode tests for upstream unavailable, timeout, response too large,
  unknown tool, schema load failure, invalid config, and cap exhaustion.
- Catalog tests for both axes: exposure mode (`:auto | :inline | :lazy`) and
  snapshot mode (`:frozen | :live`).
- Config migration tests proving old `"stdio"`, `"http"`, and absent transport
  behavior is either rejected with clear errors or intentionally accepted by a
  documented transitional parser.
- Dependency tests proving configured `openapi`/`mcp_http` transports fail
  closed with a clear message when required HTTP client dependencies are absent.

## Decisions

- Root runtime env vars use root names only. `PTC_RUNNER_UPSTREAMS` is the root
  config env var; `PTC_RUNNER_MCP_UPSTREAMS` remains an `mcp_server`-only
  compatibility alias that is translated into root runtime options at server
  boot. Root modules should not read or document the MCP alias.
- Expose a small public embedding API, but mark it experimental during 0.x.
  The intended upstream-provider surface is `start_link/1`, `stop/1`,
  `with_run_context/3`, and catalog/diagnostics readers. A Lisp evaluation
  convenience should be a thin `RunEnv` projection, not provider-owned
  evaluation on `PtcRunner.Upstream.Runtime`.
- Keep MCP upstream client transports in root for this migration. They are
  client transports for external tool servers, not MCP server transports, and
  root needs them to keep `(tool/call ...)` transport-neutral across OpenAPI and
  MCP-backed tools. Revisit a separate optional package only after the root
  transport behaviour has stabilized and there is concrete pressure from
  dependencies, release size, or package ownership.
