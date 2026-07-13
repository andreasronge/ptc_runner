# PTC Trace Viewer

A local, read-only web UI for canonical PtcRunner Kernel traces. It uses the
same source-scoped `Kernel.TraceLog` projections as `log.core`, so run metadata,
turns, filters, counters, pagination, and validation have one implementation.

The legacy raw JSONL views remain as a temporary fallback during the Kernel
migration. They are not the canonical query path.

## Quick start

From the PtcRunner root:

```bash
mix ptc.viewer --trace-dir traces
```

The root task installs `PtcRunner.Kernel.ViewerAdapter` automatically, starts a
local server on port 4123, and opens the browser. Use `--port`, `--trace-dir`,
or `--no-open` to override those defaults.

The UI first lists bounded canonical run summaries. Selecting a run loads its
metadata and turn events through the shared Kernel query layer. The run view
pairs canonical evaluation and capability start/stop events into an expandable
execution transcript, with run metrics, prelude component fingerprints,
workflow annotations, limit failures, and raw event metadata available on
demand. Sanitized traces do not contain prompts, provider responses,
capability arguments/results, or private prelude source; the UI identifies
those omissions rather than inferring or reconstructing payloads. If the
viewer is embedded without a Kernel adapter, the UI falls back to the legacy
raw-file picker.

Private traces use the reserved `.private.jsonl` suffix. The standard viewer
directory source and raw-file routes omit that suffix; accessing private data
requires a separate host-controlled private source grant outside this UI.

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

Query parameters are passed to `Kernel.TraceLog`; `limit` is decoded as an
integer and `tags` as a JSON object. The routes preserve not-found, invalid
query, unavailable-adapter, and adapter-failure classifications.

Temporary legacy endpoints:

| Endpoint | Description |
| --- | --- |
| `GET /api/traces` | List public `.jsonl` files under the configured directory |
| `GET /api/traces/:filename` | Read one bounded public JSONL file |

Raw reads reject traversal, symbolic links, non-regular files, oversized
files, files that change between inspection and opening, and private-suffixed
traces.

## Architecture

The root-owned adapter constructs a `Kernel.TraceLog` from the configured
directory for every query. The viewer owns only HTTP argument decoding and
rendering; it does not duplicate trace validation or run derivation. Adapter
configuration is passed through the Bandit/Plug instance rather than global
application environment.

The browser assets still contain the old agent/plan renderers for raw-trace
fallback. They can be deleted when the public Kernel cutover removes the last
legacy trace producer.
