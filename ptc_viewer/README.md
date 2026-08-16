# PTC Kernel Viewer

A local web UI for canonical PtcRunner Kernel traces. Its Runs tab is read-only
and uses the same validated trace projections as the semantic analysis layer, so
run metadata, turns, filters, counters, pagination, and validation have one
implementation. When launched from the PtcRunner root, it also enables a
bounded run-analysis REPL backed by Core.

The Viewer accepts only the canonical Kernel event model. Trace loading,
validation, run derivation, filtering, and pagination remain owned by
`PtcRunner.Kernel.TraceLog` through the configured host adapter.

## Quick start

From the PtcRunner root:

```bash
mix ptc viewer ptc-project.json
```

The root `viewer` command reads the explicitly named operator-owned project
configuration, captures its trace and authorized inspection directories,
starts the server, and optionally opens the browser. Port, opening, REPL, and
private-data choices live in the project file. The old independent Viewer
path-switch grammar has been removed; see the root
[project configuration guide](../docs/guides/project-configuration.md).

The server binds `127.0.0.1` unless the caller supplies `ip: {0, 0, 0, 0}` —
`--listen 0.0.0.0` on the command. There is no authentication, so the wildcard
serves whatever trace and inspection data the instance was granted to every
host that can reach the port.

This project is a companion of the root `ptc_runner` project rather than a
separately published package. It ships inside the standalone release and the
container image; the published Hex package does not carry it.

The REPL evaluates PTC-Lisp against an immutable capture of the selected trace
directory. The server fixes the `run-analysis-v1` profile: normal bounded
PTC-Lisp built-ins, the three `analysis/*` navigation functions, their shared
`cap` helpers, three read-only analysis capabilities, and the ordinary
runtime/capability introspection routes. It does not grant filesystem, network,
LLM, MCP, workflow-event, or arbitrary prelude authority.

Forms such as `(analysis/runs {})`, `(analysis/open "run-id")`, and
`(analysis/read "run-id" {"collection" "activity" "limit" 100})` return bounded values,
prints, errors, continuation effects, duration, and remaining usage. The
server-owned transcript survives a page reload. Reset first closes and persists
the analysis run, then captures a new snapshot and starts with fresh
definitions; Close persists the analysis trace and ends further evaluation.

Entered human-REPL source and returned private values are not copied into the
canonical analysis trace. The human REPL transcript is separate presentation
state.

The UI first lists bounded canonical run summaries, identified by run ID and
filterable by ID, status, or bundle hash. Selecting a run loads its metadata
and canonical activity, plus one semantic `conversation` result when the Viewer
was started with an authorized inspection artifact. The URL carries
`#/run/<run-id>`, so a run view can be bookmarked and reloaded.

The canonical transcript keeps canonical events as its execution spine. With
an authorized inspection artifact, it also shows each evaluation's exact
generated program from the semantic conversation projection and the feedback
reconstructed on the following turn. Ambiguous program-to-turn associations
are not guessed into result blocks. Private model requests and responses also
appear in the separate **Model conversation** panel produced by `RunAnalysis`;
ambiguous exchanges are omitted from streams and reported by the semantic
result rather than guessed into a turn.

The browser cannot choose a server path or discover inspection files. Startup
pins the operator-selected artifact, validates it against the captured
canonical trace, and compiles the immutable inspection projection once, so
replacing the original path cannot change later responses. Symlinks, changed
files, oversized or malformed records, correlation failures, and mismatched
run IDs fail closed.

The prelude cards list effective workflow and mission components in frozen
load order (dependencies before dependants) with the bundle hash. When run
metadata carries a compact dependency projection — `component_ids` plus
positionally aligned `dependency_indices` whose entries are unique,
ascending, and strictly earlier than their own position — the cards render
per-component dependency lists. The complete graph must validate; missing or
malformed projections fall back to the ordered chips without partially
rendered edges, reordered IDs, or inferred dependencies. Current canonical
metadata records only ordered component IDs and the bundle hash.

When inspection capture includes effective prelude sources, component entries
open the exact captured source. Generated-source records carry statically
analyzed `prelude_calls`; those facts alone produce the clickable call badges
that navigate to the matching scoped component. Source highlighting may place
an anchor on a matching definition, with the component source as the fallback;
highlighted program text is never parsed to infer that a call occurred.

Authenticated remote access and prelude editing remain outside this local
development mode.

## Frontend

`priv/static` is served verbatim; there is no build step and no
`node_modules`. Views are Preact components written with `htm` tagged
templates, from a vendored ESM copy of `preact`, `preact/hooks`, `htm` and
`preact-render-to-string` under `priv/static/js/vendor/preact/` (see
`VERSIONS.txt` there for versions and the one edit applied). The browser mounts
the components with `render`, so re-rendering a run — loading a further event
page — diffs into the existing tree and keeps open disclosures and the reading
position; `renderKernelTranscriptMarkup` renders the same components to a
string for the test harness, which therefore runs under plain node with no DOM
stub. Interpolated values are escaped by the `html` tag.

The REPL panel keeps its imperative controller. Its authoritative-read poll is
a GET that never changes `mutation_nonce`, so it does not gate the controls;
the remaining-budget clock ticks from a locally held deadline, and the session
projection is fingerprinted. An idle session therefore performs no DOM writes
between polls.

## Programmatic use

The standalone viewer deliberately has no dependency on the PtcRunner host.
The host supplies a module or three-argument function implementing
`PtcViewer.KernelTraceAdapter`:

```elixir
{:ok, pid} =
  PtcViewer.start(
    port: 4123,
    trace_dir: "traces",
    kernel_trace_adapter: PtcRunner.Kernel.ViewerAdapter,
    inspection_file: "traces/run.inspection.jsonl",
    inspection_adapter: PtcRunner.Kernel.ViewerAdapter,
    open: false
  )

PtcViewer.stop(pid)
```

Configuration is scoped to the individual server instance; starting another
viewer does not mutate application-global adapter or trace-directory state.
Standalone hosts may additionally supply a module implementing
`PtcViewer.ReplAdapter` plus opaque `:repl_config`; omitting it preserves the
Runs-only UI.

## HTTP API

| Endpoint | Shared Kernel operation |
| --- | --- |
| `GET /api/kernel/runs` | `list_runs` with bounded filters and pagination |
| `GET /api/kernel/runs/:run_id` | `get_run` |
| `GET /api/kernel/runs/:run_id/turns` | `list_turns` with bounded filters and pagination |
| `GET /api/kernel/counters` | `counters` |
| `GET /api/analysis/runs/:run_id/conversation` | Presentation over the bounded `turns` collection |
| `GET /api/analysis/runs/:run_id/preludes` | Bounded effective prelude sources from the pinned inspection projection |
| `GET /api/repl` | Bootstrap or refresh the server-owned analysis session |
| `POST /api/repl/evaluations` | Evaluate one bounded PTC-Lisp form |
| `POST /api/repl/templates` | Format an inert `analysis/open` or `analysis/read` editor template |
| `POST /api/repl/reset` | Persist the current session and capture a replacement |
| `DELETE /api/repl` | Close and persist the current analysis session |

Query parameters are passed to `Kernel.TraceLog`; `limit` is decoded as an
integer and `tags` as a JSON object. The routes preserve not-found, invalid
query, unavailable-adapter, and adapter-failure classifications.

## Architecture

The root-owned adapter constructs immutable Kernel snapshots from the
configured sources. The Viewer owns only HTTP argument decoding and rendering;
it does not duplicate trace validation, run derivation, conversation joins, or
ambiguity policy. Adapter configuration is passed through the Bandit/Plug
instance rather than global application environment. No browser route reads an
arbitrary trace filename or returns raw inspection records. Private records are
held in a dedicated process; Bandit plug options and request Logger/Telemetry
metadata contain only that process PID. The frontend contains no parser or
renderer for raw inspection record families.
