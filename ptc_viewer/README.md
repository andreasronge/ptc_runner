# PTC Trace Viewer

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
or `--no-open` to override those defaults.

The UI first lists bounded canonical run summaries. Selecting a run loads its
metadata and turn events through the shared Kernel query layer. The run view
pairs canonical evaluation and capability start/stop events into an expandable
execution transcript, with run metrics, prelude component fingerprints,
workflow annotations, limit failures, and raw event metadata available on
demand. Sanitized traces do not contain prompts, provider responses,
capability arguments/results, or private prelude source; the UI identifies
those omissions rather than inferring or reconstructing payloads. Starting the
Viewer without a Kernel adapter leaves canonical queries unavailable; it does
not expose raw files through a second trace format.

Private traces use the reserved `.private.jsonl` suffix. The standard viewer
directory source and raw-file routes omit that suffix; accessing private data
requires a separate host-controlled private source grant outside this UI.

The current Viewer does not expose exact model exchanges, generated program
source, connector payloads, or a prelude editor. The
[host access and prelude workspace plan](../docs/plans/lisp-kernel/host-access-and-prelude-workspaces.md)
allows a future explicit loopback-only mode for one host-selected bounded
inspection artifact without putting sensitive payloads into canonical traces.
Authenticated remote access and prelude editing remain deferred. Connector
transport and credentials remain a separate concern covered by the
[capability connector plan](../docs/plans/lisp-kernel/capability-connectors.md).

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

## Architecture

The root-owned adapter constructs a `Kernel.TraceLog` from the configured
directory for every query. The viewer owns only HTTP argument decoding and
rendering; it does not duplicate trace validation or run derivation. Adapter
configuration is passed through the Bandit/Plug instance rather than global
application environment. No browser route reads an arbitrary trace filename,
and the frontend contains no parser or renderer for the retired raw event
format.
