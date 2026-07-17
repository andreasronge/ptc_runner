# PTC Kernel Viewer

A local, read-only web UI for canonical PtcRunner Kernel traces. It uses the
same source-scoped `Kernel.TraceLog` projections as `log.core`, so run metadata,
turns, filters, counters, pagination, and validation have one implementation.

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

The UI first lists bounded canonical run summaries. Selecting a run loads its
metadata and turn events through the shared Kernel query layer. The run view
pairs canonical evaluation and capability start/stop events into an expandable
execution transcript, with run metrics, prelude component fingerprints,
mission inventory and connector fingerprints, workflow annotations, limit
failures, and raw event metadata available on demand. Sanitized traces do not
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
UI keeps a sensitive-data warning visible whenever it renders these records.

When the artifact is pinned, the run view joins its records to canonical IDs
and renders five private additions alongside the sanitized transcript:

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
  program), the generated PTC-Lisp program from each response, and the
  canonical outcome of the mission evaluation whose captured source exactly
  matches that response's generated program. A window without an exact match
  renders as unpaired rather than positionally inferred;
- a **program source** panel inside each subordinate evaluation, verifying the
  captured source hash against the canonical `evaluation-started`
  `source_hash` and flagging any mismatch;
- **arguments/result** panels inside each captured capability call;
- expandable **component source** inside each prelude card, joining
  `prelude-source` records to the frozen component IDs of the matching
  environment.

Every joined panel carries a `private` marker; runs without a pinned artifact
render the sanitized transcript unchanged. The viewer eagerly loads all
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

## HTTP API

| Endpoint | Shared Kernel operation |
| --- | --- |
| `GET /api/kernel/runs` | `list_runs` with bounded filters and pagination |
| `GET /api/kernel/runs/:run_id` | `get_run` |
| `GET /api/kernel/runs/:run_id/turns` | `list_turns` with bounded filters and pagination |
| `GET /api/kernel/counters` | `counters` |
| `GET /api/inspection/runs/:run_id` | Fixed private artifact records for the exact run |

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
