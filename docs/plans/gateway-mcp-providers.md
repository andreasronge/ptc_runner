# Serve workflows that use upstream MCP servers

Status: planned. Tracking issue: #2198. Nothing below is current behavior
unless it is cited as such.

## Goal

A workflow served by the gateway can grant its missions tools from installed
`mcp` providers, so one gateway tool can compose several upstream MCP servers
inside a bounded, traced, pinned program. The design must stay simple (one
sharing model, no new owner hierarchy), flexible (stdio and static-credential
HTTP servers), and fast (no per-call process start).

## Current behavior

- `PtcRunner.Kernel.ProviderRuntime.supported/1`
  (`lib/ptc_runner/kernel/provider_runtime.ex:176`) accepts only `:llm`,
  `:decision`, and `:decision_replay`, in serving and in `pins: :discover`
  mode. A served template that selects an `mcp` installation is refused with
  `:provider_runtime_unsupported`, which the gateway reports as the
  uncatalogued startup code `internal_error` (`PtcGateway.StartupError`).
- The warm-runtime plan (commit `496f056b7`) excluded MCP because "MCP sessions
  are stateful and are not shareable across runs". That premise no longer
  holds at the protocol level: MCP 2026-07-28 has no `initialize` handshake and
  no session; every request carries its own `_meta` protocol version and client
  capabilities (`site/schemas/mcp-2026-07-28.schema.json`, `RequestMetaObject`).
  The client refuses every flow that would bind a connection to one caller:
  server-to-client requests and `input_required` results
  (`mcp_protocol.ex:30-38, 277-306`).
- Stdio multiplexes up to 128 in-flight requests by JSON-RPC id
  (`mcp_stdio_transport.ex:26, 231-245`). HTTP opens one socket per request
  with no pool and no in-flight cap (`mcp_http_adapter.ex:1-11`,
  `mcp_request_context.ex:164-186`).
- Upstream tool invocation is mission-only. A workflow may select an MCP
  provider only with `catalog: true`, which acquires the server and exposes a
  read-only `<provider>.catalog` capability (`mcp_source.ex:558-575, 839-847`).
- Mission MCP snapshots are pinnable: `ProviderSnapshot.build` hashes the tool
  catalog, server info, transport, and stdio executable/launcher digests into
  the acquisition identity that `ProviderRuntime.verify_pins/3` compares. A
  workflow `catalog: true` snapshot omits server info and executable identity
  (`mcp_source.ex:1063`), so its pin is weaker.
- `WarmProviderRuntime` starts one `ProviderRuntime` per provider-bearing tool
  (`warm_provider_runtime.ex:321-333`), so two tools that select the same
  installation acquire it twice. Any unhealthy runtime fences the whole warm
  domain (`:426-435, 465-466`).
- Gateway pins are printed by `ptc gateway CONFIG --print-pins`.
- A read-declared workflow that calls `kernel/eval*` is refused as `unknown`
  (#2201): the early `DeclaredReadEffectValidator` omits implicit workflow
  routes. Every MCP-backed served tool must therefore be declared write, set
  `allow_write`, configure a private audit directory, and report
  `Operation may have changed data; do not retry automatically` on failure.

## Spike evidence

All spikes ran on macOS arm64 against `ptc-fs-mcp@0.3.0` over stdio. The code
changes were local and reverted.

| Measurement | Result |
| --- | --- |
| Raw stdio spawn to first `tools/list` response, `npx` | 1.2–1.5 s |
| Same, absolute `node` path | 0.16–0.20 s |
| 20 pipelined `tools/call` requests on one stdio connection | 40–90 ms |
| `ptc run` baseline, no provider | 1.8–2.1 s |
| `ptc run` with one per-run MCP acquisition, absolute `node` | 2.8–3.1 s (about +1 s) |
| Same with `npx` | 4.1–6.1 s (+2.5–4 s) |
| Gateway with `:mcp` added to `supported/1`: first call / warm call | 0.43 s / 0.02 s |
| 12 concurrent gateway calls with two different arguments, one shared child | all correct, 0.22 s wall |
| Kill the upstream child, then call | readiness stays `ready`; every later call fails permanently |

The one-line allowlist change was enough for discovery, pins, startup, and
correct concurrent calls. Per-run acquisition costs about a second even with a
fast launch: executable hashing (a 77 MB `node`), launcher staging, discovery,
and graceful close. A warm shared connection is about fifty times faster per
call. The kill test shows the gap that sharing must close.

Incidental findings: an MCP provider selected under `providers.workflow`
without `catalog` returns `internal_error` instead of the documented diagnostic
(#2200); `mix ptc.gateway` from `ptc_gateway/` does not recompile an edited
root `ptc_runner`, so run `mix compile` in `ptc_gateway/` first.

## Options considered

| Option | Per-call cost | Isolation | Complexity | Verdict |
| --- | --- | --- | --- | --- |
| A. Acquire per call through the existing cold path (`RunAdmission.activate/5`) | +1 s (`node`) to +4 s (`npx`) | Each call gets a fresh server process | Low: per-call pin check is new | Deferred: too slow for an interactive tool. |
| B. Share one warm acquisition per serving tool | ~20 ms | All calls of one tool share the server process and its in-memory state | Medium: cancellation, loss, inspection | **Recommended.** |
| C. Pool of N exclusive connections | ~20 ms | Concurrent calls separated; sequential calls still share state | High: pool sizing, replacement, fairness | Rejected: the isolation it buys is partial. |
| D. Per-installation choice between A and B | Either | Either | B plus A | Deferred with A. |

Option B fits the gateway's current trust model. Today a gateway has one bearer
credential and one host document, so all its callers share one authority. That
holds per gateway process, not per deployment: roles and tenants (#2206) will
scope each shared acquisition to one tenant, never across tenants. Sharing an
upstream process among one authority's callers adds two exposures, both
documented as trusted-server requirements in the MCP reference:

- a server that keeps caller-sensitive state in memory leaks it between calls;
- a server that ignores `notifications/cancelled` keeps running abandoned work
  after the caller is gone.

Options A and D become a planned slice only when a concrete server needs
isolation from other callers of the same gateway.

## Design (planned)

### 1. Read-only served tools (#2201)

Fix the early validator so implicit routes resolve as they do after assembly:
the workflow `kernel-eval` route is the join of the selectable missions'
grants, the other workflow implicit routes are read, and mission implicit
routes are read as in `MissionInventory.resolved_export_effect/2`. Supplying a
`kernel-eval` value is not enough on its own: a provider-bearing serving entry
must also pass the complete-grant check that `PtcRunner.Kernel.EntryEffect`
performs (every implicit route and every selectable mission export and
capability, referenced or not), which `ServingTemplate` skips today when it
copies the declared effect (`serving_template.ex:563`). Export effect rules and
join precedence do not change. A workflow whose missions hold
only read grants then validates as `:effect :read`, is served with
`readOnlyHint: true`, needs no `allow_write` or audit directory, and keeps the
ordinary failure text. Model calls keep `unknown`.

### 2. Admit `mcp` installations in the warm runtime

- Scope is per serving tool, matching today's ownership: each provider-bearing
  tool's `ProviderRuntime` acquires its own transport, shared by every borrow
  of that tool. Gateway-wide deduplication across tools is not planned.
- `ProviderRuntime.supported/1` accepts `:mcp` installations whose
  `authorization_mode` is not `:oauth`, selected as mission tool grants, in
  serving and discovery modes. A workflow `catalog: true` selection is refused
  like OAuth: catalog reading is an authoring aid, and its weaker snapshot
  would break the uniform pin contract.
- OAuth and workflow catalog selections are refused before any credential
  capture or acquisition: each tool's template stage inspects its selected
  descriptors and refuses them with a new catalogued gateway code,
  `provider_source_unsupported`, reported in the per-tool constructor stage of
  the startup precedence. An unselected OAuth installation in the host
  document is ignored. The `ProviderRuntime` guard stays as defense in depth,
  and `:provider_runtime_unsupported` maps to the same code. OAuth needs a
  durable, principal-scoped store
  (`docs/plans/future/mcp-oauth-durable-store.md`).
- Per-call state (inspection sink, `traceparent`, capability id, mission name)
  already arrives at invocation time (`mcp_source.ex:1188-1203`).

### 3. Bounds and busy refusal

- Stdio keeps its 128 in-flight cap. HTTP gains the same cap in
  `MCPRequestContext`, so both transports have one documented per-acquisition
  bound. Whether the cap becomes a host ceiling is decided in slice 2b.
- A cap refusal is produced before any byte is written, so it carries trusted
  `not_dispatched` provenance and maps to `mcp_transport_busy`, retryable for
  read and write mappings alike. Today it falls through to the generic stdio
  error with `possibly_dispatched` provenance (`mcp_source.ex:1446-1449,
  2209-2228`).
- MCP calls do not join `ProviderCallAdmission`, which counts LLM provider
  slots and drains Finch checkouts. Gateway run admission bounds the number of
  calls; the transport cap bounds requests per acquisition.

### 4. Cancellation and caller death on a shared transport

Today a caller that times out or dies while its frame is awaiting the port
write acknowledgement stops the whole stdio transport
(`mcp_stdio_transport.ex:369-379, 422-432`), failing every other pending
request. Shared, one disconnecting client could take down every concurrent
call. Slice 2a separates the caller's deadline from the transport's:

- **Queued** (admitted, no byte written): the request is discarded. Neither
  the tool request nor a cancellation notification is sent.
- **Writing** (frame handed to the port, acknowledgement pending): the frame
  finishes under a transport write-settlement deadline that is independent of
  the caller and is bounded by the installation's `timeout_ms`. The caller's
  expiry or death does not stop the transport; the request is then treated as
  sent. Exceeding the write-settlement deadline is a transport fault.
- **Sent** (acknowledged): the transport writes `notifications/cancelled` for
  the id and drops any late response.
- A detached request holds its in-flight slot until its cancellation
  notification is acknowledged, so detached work counts against the cap.
- The transport stops only for transport faults: child exit, EOF, port error,
  write-settlement expiry, or protocol corruption. A fault fails every pending
  request on that transport and fences readiness (design 5); this is the only
  case in which one call affects another.

HTTP follows the same rule: a queued request is discarded, and a request whose
socket worker has started is closed by that worker, which holds its slot until
it exits.

Settlement is local, synchronous, and keyed by borrow rather than by caller
pid, because the provider task tracker forgets callers that exit early
(`provider_task_tracker.ex:137, 172`) and HTTP runs each request in a nested
task and socket worker (`mcp_source.ex:1407`, `mcp_http_adapter.ex:186`):

- Every request records its borrow token with the transport at admission. The
  transport keeps a per-borrow ledger of entries that are queued, writing,
  sent and awaiting a response, detached and awaiting a cancellation
  acknowledgement, or held by a socket worker. An attached entry leaves the
  ledger when its matching response (success or error) arrives, which also
  releases its slot. A detached entry leaves only when it is discarded or its
  cancellation is acknowledged, even if a late response arrives first. An HTTP
  entry leaves when its socket worker has exited.
- Borrow return first seals the borrow on every acquired transport (later
  requests carrying that token are refused) and then waits until each ledger
  for the borrow is empty. Callers that timed out earlier, and their HTTP
  workers, are still in the ledger, so they are awaited too.
- If the execution owner dies, `ProviderRuntime` keeps the borrow counted
  (today it removes it at once, `provider_runtime.ex:419`) and performs the
  same seal-and-settle itself. The borrow is released only on positive
  settlement evidence or by the forced close at the drain cutoff.
- Both waits are bounded by the existing `provider_cleanup_timeout_ms`. Expiry
  is a provider cleanup failure with today's precedence; it fences readiness
  and leaves the borrow counted until forced close.

Upstream completion is not observable: a write mapping abandoned after dispatch
keeps `mutation_state: :indeterminate`, and remote work that ignores
cancellation is covered by the trusted-server rule.

Drain keeps today's contract: it waits for borrows until its absolute cutoff,
then closes each acquisition even with borrows outstanding
(`provider_runtime.ex:433`). Closing a stdio transport ends its child process,
which bounds detached work at shutdown.

### 5. Loss fences readiness

- `ProviderRuntime` monitors each acquired MCP transport owner (the stdio
  transport process, the HTTP `MCPRequestContext`). Its exit marks the runtime
  `{:not_ready, :provider_runtime_lost}`, which fences the whole warm domain
  as session or registry loss does today. `/health/ready` reports it and new
  calls get the existing unavailable error. Recovery is a gateway restart.
- An HTTP socket failure, timeout, or upstream error on one request is a
  per-request error and does not fence.
- Fencing one tool while others keep serving, and automatic transport
  replacement with re-verified pins, are follow-ups gated on operational
  evidence.

### 6. Inspection without serializing every caller

Today an inspection sink serializes stdio exchanges so stderr can be attributed
to one request (`mcp_stdio_transport.ex:217-229`). Shared, that would serialize
every call of the tool. In serving mode:

- Request and response bytes stay captured per call, correlated by request id,
  with the existing per-exchange byte limits.
- Exchange requests pass the same in-flight cap, caller monitor, and deadline
  as ordinary requests; a queued exchange keeps its original deadline.
- Server stderr is not attributed to calls. It is kept in a bounded
  per-transport buffer and is never included in a call's inspection record,
  because it can carry other callers' data.

### 7. Print pins from the shipped executable

A `ptc gateway` discovery form reads a gateway document in which the three pin
fields may be absent or stale and prints one JSON object keyed by tool name
with `expected_application_content_digest`, `installation_config_pins`, and
`provider_snapshot_pins`.

- It first validates every tool's template, including the OAuth and catalog
  refusals, before any acquisition.
- It resolves only the credentials of the providers the tools select, from an
  optional `--env-file` anchored at the invocation directory, read once, and
  restored before exit. The inbound bearer binding is neither required nor
  read.
- Provider applications run in command-VM mode. No listener, private audit directory, or artifact root is
  created or touched.
- Tools are acquired in name order. Output is written only after every tool
  succeeds; any failure prints nothing on stdout, exits nonzero, and closes
  every acquisition.

Serving validation is unchanged: pins stay required at startup.
The command is `ptc gateway CONFIG --print-pins`, documented in
`docs/reference/cli.md`.

### 8. Gateway event log

Today a gateway is hard to debug. `/health/ready` returns only
`{"status":"not_ready"}`, a startup failure prints one code such as
`{"error":"internal_error"}`, and the gateway writes no log. Sharing upstream
processes adds new failure kinds (transport loss, busy refusals, detached
requests, settlement timeouts) that need a record.

- A new optional `artifacts.events` object writes an owner-only JSON Lines
  event log under the artifact root:
  `{"max_file_bytes": N, "max_retained_files": M, "stderr": false}`. Files are
  `events/<gateway_start_ref>-<sequence>.jsonl`, rotated and retained like the
  private audit files, with the same private-directory checks. The bounds are
  independent of `private_audit`, so a read-only gateway can log.
- Records carry a closed `kind` and a timestamp: `startup_stage` (stage name
  and outcome), `startup_failed` (the catalogued code plus the internal reason
  class that `PtcGateway.StartupError` normalizes away today), `readiness`
  (transition, tool name, provider name, cause class), `transport` (tool,
  provider, fault kind, exit status), per-interval counters for `busy`,
  `detached`, `settlement_timeout`, and `dropped_events` per tool and
  provider, and, only when `stderr` is true, `stderr_tail`.
- Every record except `stderr_tail` names tools, providers, and closed classes
  only: no call arguments, results, credentials, endpoints, or paths.
  `stderr_tail` is raw upstream output (the bounded per-transport buffer from
  design 6, written on transport loss and at shutdown), may contain anything
  the server printed, and is classified as private upstream evidence. It is
  never exposed through any served tool.
- Logging never fences serving. Records go through a bounded in-memory queue;
  an open or write failure, or a full queue, drops records and counts them in
  the next `dropped_events` record that can be written. A startup failure to
  create the log directory is a startup error, reported as
  `artifact_root_unavailable`.
- Startup writes events only once the artifact root has passed validation; a
  failure before that stage leaves the existing one-code diagnostic only.
- The public surfaces stay unchanged: health bodies, startup stderr, and MCP
  error envelopes still carry only catalogued codes.
- Version 1 reads the log as plain, documented JSON Lines. No served tool,
  REPL profile, or Viewer page reads it.

### 9. Debug tools by configuration

A gateway that records traces can also serve a tool that debugs them. The
runtime adds no special debug endpoint. It makes one shape possible by
configuration, and the example in design 10 ships it as an optional manifest:

- **Analysis eval.** A served workflow takes PTC-Lisp source text and evaluates
  it with `kernel/eval-source` in a mission granted a `ptc_trace_snapshot` of
  the gateway's trace directory. The MCP client's own model writes the
  queries; the gateway runs no model. A second tool returns the mission's
  prompt-visible API so the client knows what it may call. The source is
  bounded by the existing source, evaluation, and run limits, and the entry is
  read when every selectable grant is read (design 1).
- **Binding.** The shipped `analysis` prelude calls `tool/analysis-runs`,
  `analysis-open`, `analysis-read`, and `analysis-counters`, which exist only
  for the REPL's unnamed snapshot (`run_analysis_capability.ex:57-58`). An
  installed snapshot provides `<alias>.runs`, `<alias>.open`, `<alias>.read`,
  and `<alias>.counters`. The example therefore ships a small mission facade
  component over its alias instead of the `analysis` prelude; no runtime
  change is needed.
- The same pattern works for any mission, so it is also a general "code mode"
  endpoint over composed MCP grants once slice 2b lands.

Two runtime changes make it work:

- **Cold tools.** Snapshot sources capture their directory once at
  acquisition (`docs/reference/host-installation.md`, "Trace and inspection
  snapshots"). Acquired once at gateway startup, a debug tool would never see
  later runs. A served tool whose providers are all `ptc_trace_snapshot`
  installations is therefore a cold tool: it gets no warm runtime and each
  call acquires its whole selection through the existing per-run path
  (`RunAdmission.activate/5`), with cleanup owned by that run. No upstream OS
  process is spawned; the cost is one bounded directory capture, measured in
  slice 5. A tool that mixes a snapshot source with any other provider kind is
  refused with `provider_source_unsupported`.
- **Pins for cold tools.** `installation_config_pins` keeps the snapshot
  installation's configuration digest and is checked at startup.
  `provider_snapshot_pins` omits snapshot sites, because their acquisition
  identity includes the capture's content and changes by design; discovery
  (design 7) prints the map without them. Startup still runs the snapshot
  preflight (directory resolution and private-directory checks) before the
  listener binds.
- **Normal data only.** `ptc_trace_snapshot` contributes data class `normal`,
  and ordinary canonical traces exclude exact prompts, responses, and
  capability payloads (`dispatcher.ex:556-580, 697-728`). They show run
  structure, timing, limits, tool-call identities, and failure classes, so a
  version 1 debug tool can say where and how a run failed more often than
  why. `ptc_private_trace_snapshot` and `ptc_inspection_snapshot` (which
  `debug.nav` needs) classify a run as `private_inspection`, which the gateway
  never returns; they stay refused with `provider_source_unsupported` until
  the private-evidence decision (open question 2).

A debug tool should write its own runs to a different artifact root, or
filter them out, so it does not analyse itself.

### 10. Example, documentation, and landing page

- A runnable example under `examples/` serves a tool composing an upstream MCP
  server. The default path needs no model and no key and is declared read; an
  optional step adds a model-backed agent and is verified live with
  OpenRouter.
- `docs/reference/gateway.md` and `docs/reference/mcp.md` document per-tool
  sharing, the trusted-server rules, the in-flight bound, busy refusal, OAuth
  refusal, loss fencing, and pin discovery. `docs/reference/mcp.md` links to
  the gateway. `docs/reference/cli.md` lists `ptc gateway` and its exit status
  78. Conformance-suite internals move from `gateway.md` to
  `docs/maintainers/`.
- The example also ships the analysis-eval debug tool of design 9 as an
  optional manifest that runs offline.
- `docs/reference/gateway.md` documents the event log schema, and
  `docs/reference/debug-navigation.md` gains a section on serving debug tools.
- `docs/guides/serving-a-workflow-over-mcp.md` gains at most a link to the
  example (follow `.claude/skills/write-guide/SKILL.md`).
- A landing-page section contrasts one task-level tool over composed upstream
  servers with aggregators that merge tool lists.

## Slices

| Slice | Content | Depends on | Acceptance |
| --- | --- | --- | --- |
| 1 | Read-only served tools (#2201) | — | Failing test first: a read workflow calling `kernel/eval-source` on a read-only mission validates and serves with `readOnlyHint: true`. A provider-bearing read entry is refused when an unreferenced mission export or capability is write or unknown. A declared-read mission helper calling a mission implicit route (for example `runtime-usage`) validates. |
| 2a | Shared transports: detach on cancel, synchronous settlement, busy provenance, HTTP cap | — | Deterministic stdio tests for each state (queued, writing, sent) under caller cancel, caller death, and caller expiry, with another request in flight: a queued caller sends neither request nor cancellation; the other request succeeds; the transport survives. Write-settlement expiry fails all pending requests. Races: expiry against acknowledgement, and queue delay against deadline. Settlement is per borrow: ordinary stdio and HTTP completion empties the ledger and returns the borrow without fencing; a callback that timed out and left the task tracker is still awaited before the borrow returns; a sealed borrow's later requests are refused. A detached request holds its slot until cancellation is acknowledged; late responses are dropped. HTTP: cap rejection and slot recovery, cancel and caller death during a request. Busy is `not_dispatched` and retryable for read and write mappings. |
| 2b | Warm MCP in `ProviderRuntime` and gateway | 2a | Stdio and static-header HTTP fixtures served warm; concurrent borrows return distinct correct results; OAuth and workflow catalog selections refused with the catalogued code, selected vs unselected, mixed tools, missing OAuth credential, no store or upstream activity; transport-owner exit fences readiness, HTTP request failure does not; settlement timeout fences; killing the execution owner with detached work outstanding and delayed transport `DOWN` keeps the borrow counted until `ProviderRuntime` settles it, so drain cannot complete early; drain cutoff with detached work closes the acquisition; inspection enabled with concurrent calls, reversed responses, distinct sinks and `traceparent`s, overflow, saturation; `gateway_load_test.exs` includes an MCP tool. |
| 2c | Gateway event log (design 8) | 2b | Each record kind is produced by a deterministic trigger: startup success and failure after artifact-root validation (with the internal reason class), transport kill (readiness and transport records naming tool and provider), busy, detached, and settlement-timeout counters. With `stderr` off, a server printing sentinel secrets and paths leaves no trace of them in the log; with it on, they appear only in `stderr_tail`. Rotation and retention bounds enforced; a read-only gateway can log; a write failure or full queue drops records, emits `dropped_events`, and leaves readiness unchanged. Health bodies and startup stderr are unchanged. |
| 3 | Pins from the executable | 2b for MCP pins | Packaged-command tests: no-provider, LLM, decision, and MCP tools match serving startup; stale or missing pins accepted only in discovery; OAuth refused before acquisition; missing bearer credential does not fail discovery; a missing selected credential does; the environment is restored; no listener, audit, or artifact path is created; failure prints nothing and cleans up. |
| 4 | Example, docs, landing page | 1, 2b, 3 | Example runs offline in CI from the binary path; the model step passes a live `:scheduled_e2e` run; ExDoc and `mix ptc.verify_docs` pass. |
| 5 | Debug tools by configuration (design 9) | 1, 3 | A served cold tool selecting `ptc_trace_snapshot` sees a run completed after gateway startup; concurrent calls each get their own capture; capture cost measured on a directory of 1,000 traces and recorded; the facade's functions are called through the served tool; a mixed snapshot and model or MCP tool is refused with `provider_source_unsupported`; private snapshot sources are refused the same way; snapshot sites are absent from `provider_snapshot_pins` in discovery and startup, missing or stale installation pins refuse startup, an invalid trace directory refuses startup before the listener binds, and calls succeed after trace contents change; the analysis-eval tool answers a query offline over the example's traces; a debug tool writing to a separate artifact root does not see its own runs. |

Slices 1 and 2a are independent and may land first. Slice 5 does not need
shared MCP transports and may land before slice 2b.

## Non-goals

- OAuth-protected MCP servers in the gateway.
- Per-call or pooled upstream processes (options A, C, D). Per-call
  acquisition is used only for cold tools whose providers are all trace
  snapshots (design 9), which spawn no upstream OS process.
- A served debugger agent that runs its own model over traces. It needs one
  tool to mix per-call snapshot acquisition with warm model acquisition,
  which is not designed here; the analysis-eval tool covers the case where the
  client's model does the debugging.
- Serving private traces or inspection records over the endpoint.
- A built-in debug endpoint; debug tools are ordinary served workflows.
- Gateway-wide sharing of one installation across tools.
- Automatic transport replacement, re-pinning, or per-tool fencing.
- Changing the `unknown` effect of model calls.
- Direct upstream tool calls from workflow code, and workflow `catalog: true`
  selections in served tools.

## Open questions

1. Whether the in-flight cap becomes an installation ceiling (slice 2b).
2. Whether a served tool may ever return private evidence (private traces,
   inspection records, `debug.nav`). That needs an explicit per-tool opt-in
   that the gateway refuses today; decide before extending slice 5.
