# PTC Kernel Viewer

A local web UI for canonical PtcRunner Kernel traces. Its Runs tab is read-only
and uses the same source-scoped `Kernel.TraceLog` projections as `log.core`, so
run metadata, turns, filters, counters, pagination, and validation have one
implementation. When launched from the PtcRunner root, it also enables a
bounded log-analysis REPL backed by Core.

The Viewer accepts only the canonical Kernel event model. Trace loading,
validation, run derivation, filtering, and pagination remain owned by
`PtcRunner.Kernel.TraceLog` through the configured host adapter.

## Quick start

From the PtcRunner root:

```bash
mix ptc.viewer --trace-dir traces
```

The root task installs `PtcRunner.Kernel.ViewerAdapter` automatically, starts a
local server on port 4123, and opens the browser. Use `--port`, `--trace-dir`,
`--inspection-file`, or `--no-open` to override those defaults. The server
always binds to loopback.

The REPL evaluates PTC-Lisp against an immutable capture of the selected trace
directory. The server fixes the `log-analysis-v2` profile: normal bounded
PTC-Lisp built-ins, one-page `log/*` queries, bounded whole-result
`log.analysis/all-runs` and `log.analysis/all-turns` queries, their shared
`cap` helpers, four read-only trace capabilities, and the ordinary
runtime/capability introspection routes. It does not grant filesystem, network,
LLM, MCP, workflow-event, or arbitrary prelude authority.

Forms such as `(log/runs {})`, `(log/run "run-id")`, and
`(log.analysis/all-turns "run-id" {"limit" 100} 20)` return bounded values,
prints, errors, continuation effects, duration, and remaining usage. The
server-owned transcript survives a page reload. Reset first closes and persists
the analysis run, then captures a new snapshot and starts with fresh
definitions; Close persists the analysis trace and ends further evaluation.

Entered human-REPL source and returned inspection payloads are not copied into
the canonical analysis trace. Model-generated PTC-Lisp and the feedback sent
back to a model are visible only when the original run has an explicitly pinned
private inspection artifact, in the Runs tab's model dialogue. The human REPL
transcript is separate presentation state.

The UI first lists bounded canonical run summaries, identified by run ID and
filterable by ID, status or bundle hash. Selecting a run loads its metadata and
turn events through the shared Kernel query layer, and puts the run in the URL
(`#/run/<run-id>`), so a run view can be bookmarked, shared and reloaded and
Back returns to the list. The run view leads with identity, metrics,
provenance, token spend and the model dialogue; preludes, mission inventory and
connector fingerprints, the captured system prompt, and the canonical execution
transcript sit behind labelled disclosures below it. The execution transcript
opens by default only when there is no private overlay, because then it is the
whole run rather than its detail. Sanitized traces do not
contain prompts, provider responses,
capability arguments/results, or private prelude source; the UI identifies
those omissions rather than inferring or reconstructing payloads. Starting the
Viewer without a Kernel adapter leaves canonical queries unavailable; it does
not expose raw files through a second trace format.

Private canonical traces use the reserved `.private.jsonl` suffix. The
standard viewer directory source and raw-file routes omit that suffix;
accessing private data requires a separate host-controlled private source grant
outside this UI.

An explicitly selected `.inspection.jsonl` file is different. It can contain
exact model exchanges, generated source, and capability arguments/results. The
host fixes one exact file when it starts the Viewer; the browser cannot choose
a server path or discover other inspection files. Startup loads the artifact
into an immutable grant and validates its identity and correlations against the
selected canonical trace source, so replacing the path after startup cannot
change what requests inspect. The bounded loader rejects symlinks, changed
files, aggregate input above 16 MB, records above 2,000,000 encoded bytes,
malformed records, and a requested run ID that does not match the artifact. The
UI renders one state-aware provenance notice for the selected run. It
distinguishes canonical-only, complete private-overlay, incomplete/interrupted,
selected-run mismatch, and fetch-failure states instead of showing
contradictory sanitized and sensitive warnings.

When the artifact is pinned, the run view joins its records to canonical IDs
and renders private additions alongside the sanitized transcript:

- a **captured model request** disclosure showing the first exact system
  prompt. Known `PTC_AGENT_PROMPT_V1` text is split into readable sections with
  the exact prompt retained; edited/unknown formats fall back to opaque exact
  text. Each provider-neutral request remains available under **Raw captured
  request** because adapters may transform it before transport. A system prompt
  that changes mid-run is reported as a line diff against the first call with
  unchanged stretches elided, plus that call's exact prompt, rather than as
  another full copy of the prompt;

- an **LLM token spend** panel summarizing the run's provider-reported usage:
  total input/output tokens, cache reads/creation, and reported cost, with a
  per-call table and an input-composition breakdown (base system text,
  embedded frozen mission inventory, tool schemas, and message history by
  role). Providers report only aggregate counts, so section tokens apportion
  each call's reported input tokens by character share and are labeled as
  estimates; runs without input token counts fall back to exact character
  proportions, and calls without reported usage are labeled rather than
  counted as zero;
- a **model dialogue** that replays the agent loop turn by turn — the messages
  sent to the model (highlighting tool-role feedback about the previous
  program), any prose the model wrote alongside its tool call, the generated
  PTC-Lisp program from each response, and the canonical outcome of the mission
  evaluation whose captured source exactly matches that response's generated
  program. Prose is shown both as the model's own response and where that turn
  is replayed as assistant history, always next to the generated source rather
  than instead of it. A window without an exact match renders as unpaired
  rather than positionally inferred;
- a **program source** panel inside each subordinate evaluation, verifying the
  captured source hash against the canonical `evaluation-started`
  `source_hash` and flagging any mismatch;
- **arguments/result** panels inside each captured capability call;
- expandable **component source** inside each prelude card, joining
  `prelude-source` records to the frozen component IDs of the matching
  environment;
- one closed **Advanced/private records** disclosure with counts by record
  type. Exact JSON uses preserved whitespace and horizontal scrolling, so long
  identifiers are not visually split into invented whitespace.

Every joined panel carries a `private` marker; runs without a pinned artifact
render a canonical-only provenance notice. Join counts use canonical
capability starts as their denominator, and input-only stopped calls are
reported as interrupted rather than complete. The viewer eagerly loads all
bounded canonical event pages before deriving run-level projections; a run
exceeding the page budget keeps its cursor and its dialogue and spend panels
are explicitly labeled partial instead of presenting a prefix as the whole
run.

The prelude cards list effective workflow and mission components in frozen
load order (dependencies before dependants) with the bundle hash. When run
metadata carries a compact dependency projection — `component_ids` plus
positionally aligned `dependency_indices` whose entries are unique,
ascending, and strictly earlier than their own position — the cards render
per-component dependency lists. The complete graph must validate; missing or
malformed projections fall back to the ordered chips without partially
rendered edges, reordered IDs, or inferred dependencies. Current canonical
metadata records only ordered component IDs and the bundle hash.

```bash
mix ptc.viewer --trace-dir traces \
  --inspection-file traces/run.inspection.jsonl
```

Authenticated remote access, multiple private artifacts, and prelude editing
remain outside this local development mode.

The checked-in dialogue fixture is generated from the current credential-free
inspection lab. Regenerate its trace-V2/inspection-V5 two-call recovery artifacts from the
repository root with:

```bash
mix run ptc_viewer/scripts/generate_dialogue_fixture.exs
```

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
stub. Interpolated values are escaped by the `html` tag; the only raw markup
embedded is the syntax highlighter's output, which is a pure escaping string
transform.

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
| `GET /api/inspection/runs/:run_id` | Fixed private artifact records for the exact run |
| `GET /api/repl` | Bootstrap or refresh the server-owned analysis session |
| `POST /api/repl/evaluations` | Evaluate one bounded PTC-Lisp form |
| `POST /api/repl/templates` | Format an inert `log/run` or `log/turns` editor template |
| `POST /api/repl/reset` | Persist the current session and capture a replacement |
| `DELETE /api/repl` | Close and persist the current analysis session |

Query parameters are passed to `Kernel.TraceLog`; `limit` is decoded as an
integer and `tags` as a JSON object. The routes preserve not-found, invalid
query, unavailable-adapter, and adapter-failure classifications.

## Architecture

The root-owned adapter constructs a `Kernel.TraceLog` from the configured
directory for every query. The viewer owns only HTTP argument decoding and
rendering; it does not duplicate trace validation or run derivation. Adapter
configuration is passed through the Bandit/Plug instance rather than global
application environment. No browser route reads an arbitrary trace filename,
and the separate inspection adapter receives only the startup-pinned opaque
grant and URL run ID. Private records are held in a dedicated process; Bandit
plug options and request Logger/Telemetry metadata contain only that process
PID. After sending an inspection response, the returned connection is scrubbed
of its response body before Bandit emits stop metadata. The frontend contains
no parser or renderer for the retired raw event format.
