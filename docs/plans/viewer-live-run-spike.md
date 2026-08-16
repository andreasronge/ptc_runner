# Spike: Live run status in the Viewer (#1444)

Status: spike — end-to-end working demo first, refinement later.
Branch: `feat/issue-1444-viewer-live-run`.

## Goal

A run today is invisible while it happens. This spike makes a `mix ptc run`
observable live in the Viewer: budgets, heap high-water, parallel workers,
capability calls, and an activity feed — streaming into a new **Live** tab
while the run executes, verified against a real model (deepseek via
OpenRouter, credentials from `.env`) in a real browser.

Out of scope for the spike (refinement backlog at the bottom): tests,
CLI flag plumbing, REPL/analysis-session coverage, docs, precommit gates.

## Why a live channel at all

Measured earlier (recorded on #1444): the trace file does not exist until the
session closes — 8 s into a live run with two evaluations done there is no
file at all; on close every event appears at once. The Viewer is
directory-scoped, so polling buys nothing. One push channel unblocks both the
Viewer view and any future CLI progress line.

## Architecture

```
┌—————————————— run VM (mix ptc run) ——————————————————┐
│  Runner ──────── RunState (usage/1, limits)          │
│    │                    ▲ poll ~300 ms               │
│    └─ LiveStatus.Reporter                            │
│         ▲ telemetry:                                 │
│         │  [:ptc_runner,:sandbox,:armed]  pid+ceiling│
│         │  [:ptc_runner,:parallel,:budget] atomics   │
│         │  [:ptc_runner,:capability,:start|:stop]    │
│         │  [:ptc_runner,:lisp,:execute,:start|:stop] │
│         └─ POST frame JSON ──► PTC_VIEWER_URL        │
└———————————————————│——————————————————————————————————┘
                    ▼  POST /api/live/runs/:run_id
┌—————————————— viewer VM (PtcViewer) —————————————————┐
│  LiveStore (latest frame + ring, subscriber fan-out) │
│  GET /api/live/runs          snapshot                │
│  GET /api/live/stream        SSE (send_chunked)      │
└———————————————————│——————————————————————————————————┘
                    ▼  EventSource (auto-reconnect)
              Browser — "Live" tab
```

Transport decisions (from #1444 discussion):
- **Viewer → browser: SSE.** One-directional status; zero new deps on
  Plug/Bandit; `EventSource` reconnects for free.
- **Run VM → viewer VM: HTTP push.** Opt-in via `PTC_VIEWER_URL` env var
  (spike; a `--viewer-url` flag is refinement). No change to the authority
  model — runs are still launched from the CLI.
- **No second accounting.** Every number is read from `RunState.usage/1`,
  `ParallelBudget.held/available`, or a `Process.info` sample. The canonical
  event sink and its budgets are untouched; telemetry rides alongside.

## Frame schema (run → viewer, one JSON object per POST)

```jsonc
{
  "run_id": "run-9b29...",         // from EventSink.identity/1
  "seq": 12,
  "phase": "running",              // running | ok | error
  "outcome_reason": null,          // set on error frames
  "elapsed_ms": 8100,
  "remaining_ms": 21900,           // RunState.remaining_ms
  "limits": {                      // static, sent on every frame (stateless)
    "run_duration_ms": 30000,
    "subordinate_evaluations": 16,
    "workflow_capability_calls": 64,
    "workflow_capability_calls_per_name": 16,
    "evaluation_memory_bytes": 2000000,
    "evaluation_history_bytes": 1000000,
    "live_provider_tasks": 8
  },
  "usage": {                       // straight from RunState.usage/1
    "subordinate_evaluations": 3,
    "capability_calls": {"workflow": {"llm.generate": 4}, "mission": {}},
    "evaluation_memory_bytes": 1234,
    "evaluation_history_bytes": 456,
    "protocol_errors": 0
  },
  "heap": {                        // null until a sandbox arms
    "observed_words": 41850,       // latest Process.info sample
    "peak_words": 60210,           // high-water across samples
    "baseline_words": 233,
    "ceiling_words": 1250233,
    "samples": [420, 900, ...]     // recent observed deltas for sparkline
  },
  "parallel": {"held": 2, "capacity": 8},   // null until a budget exists
  "activity": [                    // ring of recent events, newest first
    {"t": 8050, "kind": "capability", "name": "llm.generate",
     "status": "ok", "duration_ms": 2210},
    {"t": 5100, "kind": "evaluation", "status": "start"}
  ]
}
```

Honesty rules baked into the schema:
- Heap is **observed/high-water**, never a fill fraction. Measured behavior:
  BEAM heaps grow in generations (7% → 19% → 49% → killed in testing), so the
  last sample before a kill can sit at half the ceiling. The UI must render a
  readout + sparkline, not a fuel gauge.
- `remaining_ms` and budget counters are real enforced ceilings — bounded
  meters are honest for those.

## Runtime changes (`lib/ptc_runner/`)

1. **`PtcRunner.LiveStatus.Reporter`** (new) — GenServer started by
   `Runner.run_claimed_attempt/2` when `PTC_VIEWER_URL` is set, stopped in the
   existing `after` cleanup. Owns: poll timer (~300 ms), telemetry handlers
   (attached with unique id, detached in terminate; handlers only
   `send/2` to the reporter — never work in the emitting process), sandbox pid
   monitor, heap peak tracking, activity ring, `Req.post` of frames
   (short timeouts, failures logged once then silent — the run must never be
   harmed by a dead viewer).
2. **Telemetry emits** (tiny, no behavior change):
   - `sandbox.ex` `rebaseline/1`: `[:ptc_runner, :sandbox, :armed]` with
     baseline/ceiling words and `pid: self()`.
   - `lisp.ex` at `ParallelBudget.new`: `[:ptc_runner, :parallel, :budget]`
     with the budget struct (atomics ref is cross-process readable).
   - `dispatcher.ex` beside the existing `capability-started` /
     `capability-stopped` canonical emits: `[:ptc_runner, :capability, :start]`
     / `:stop` carrying `name`, `environment`, `status`, `duration_ms`.
3. **`runner.ex`**: start/stop reporter; pass final outcome (`ok`/`error` +
   reason) so the last frame closes the story.

## Viewer changes (`ptc_viewer/`)

1. **`PtcViewer.LiveStore`** (new) — per-run latest frame + bounded history
   ring; subscriber pids (monitored); fan-out on every accepted frame; cap on
   retained runs (drop oldest ended runs).
2. **`router.ex`**:
   - `POST /api/live/runs/:run_id` — accept frame (size-capped), store+fan-out.
   - `GET  /api/live/runs` — snapshot for initial paint.
   - `GET  /api/live/stream` — SSE via `send_chunked`; snapshot first, then
     live frames; heartbeat comment every 15 s.
3. **`server.ex`**: start LiveStore, hand it to the router config.

## UI design — the Live tab

Design language: the Viewer's existing dark token set (`--bg #1e1e1e`,
`--accent #569cd6`, `--success #4ec9b0`, `--warning #dcdcaa`,
`--error #f44747`, `--string #ce9178`, `--keyword #c586c0`). Categorical
assignment for activity kinds is **fixed order, never cycled**:
LLM/provider = `--keyword` (purple), tool/capability = `--string` (orange),
evaluation = `--accent` (blue), lifecycle = `--muted`. Palette to be checked
with the dataviz validator against `#1e1e1e` before shipping.

```
┌ PTC Kernel Viewer   [Runs] [REPL] [● Live]                       ┐
│                                                                  │
│  ┌─ run-9b29ebf8 ───────────────────────────── ● RUNNING ──────┐ │
│  │  tutorial-deepseek-multi-turn-agent          elapsed 0:08   │ │
│  │                                                             │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────┐      │ │
│  │  │ LLM     │ │ Evals   │ │ Tools   │ │ Workers      │      │ │
│  │  │ calls   │ │  3 /16  │ │  4 /64  │ │ ●●○○○○○○ 2/8 │      │ │
│  │  │   4     │ │         │ │         │ │              │      │ │
│  │  └─────────┘ └─────────┘ └─────────┘ └──────────────┘      │ │
│  │                                                             │ │
│  │  Time to deadline      ▓▓▓▓▓▓▓▓▓▓▓░░░░░  21.9s left        │ │
│  │  Evaluations           ▓▓▓░░░░░░░░░░░░░   3 / 16           │ │
│  │  Capability calls      ▓░░░░░░░░░░░░░░░   4 / 64           │ │
│  │  Retained memory       ▓░░░░░░░░░░░░░░░   1.2 KB / 2 MB    │ │
│  │                                                             │ │
│  │  Heap (workflow eval)          ╭─╮   peak 480 KB           │ │
│  │     ~ observed, high-water  ──╯  ╰──  ceiling 10 MB        │ │
│  │     kills can occur below ceiling — this is not a gauge    │ │
│  │                                                             │ │
│  │  Activity                                                   │ │
│  │  ┃ 0:08  llm.generate        ok       2.2s                 │ │
│  │  ┃ 0:05  evaluation started                                │ │
│  │  ┃ 0:03  llm.generate        ok       1.9s                 │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  (ended runs stay, badge → ✓ COMPLETED / ✗ FAILED, muted)        │
└──────────────────────────────────────────────────────────────────┘
```

Component decisions (per dataviz method):
- **KPI row**: four stat tiles — a headline number is the right form for
  single values; text wears text tokens, never series color.
- **Budget meters**: bounded horizontal meters (these are true enforced
  fractions). Fill = `--accent`; ≥75% switches to `--warning`, ≥90% to
  `--error` — status palette used for state, always with the numeric label
  beside it (never color alone). 4px rounded ends, 2px gap to track.
- **Workers**: slot dots (filled = held), plus `n/m` text. Discrete capacity
  is better shown as discrete slots than a continuous bar.
- **Heap**: readout (peak + ceiling) + inline SVG sparkline of observed
  samples, 2px line, no axes, with the explicit non-gauge caption. No fill
  fraction anywhere.
- **Activity feed**: newest-first, 3px left border in the kind's categorical
  color, monospace timestamps, auto-capped length.
- **Live badge**: pulsing dot (CSS animation) while `phase == running`;
  outcome badge afterwards. Empty state explains how to attach a run
  (`PTC_VIEWER_URL=... mix ptc run ...`).
- Tab label shows a dot when ≥1 run is live so users notice from other tabs.

## Demo script

```sh
# terminal 1 — viewer (worktree root)
iex -S mix
iex> PtcViewer.start(trace_dir: "traces", open: false, port: 4123)

# terminal 2 — real deepseek run (credentials from .env)
cp ../ptc_runner/.env .
PTC_VIEWER_URL=http://127.0.0.1:4123 mix ptc run \
  examples/kernel-tutorial/04-multi-turn-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --env-file .env --trace-dir traces
```

Model: `openrouter:deepseek/deepseek-v4-flash` (already declared in the
tutorial host config; key from `.env` `OPENROUTER_API_KEY`). Verify in a real
Chrome tab; capture screenshots + a GIF of the dashboard updating. If the
2-call tutorial is too brief to look at, the scratch manifest lives in docs/plans/viewer-live-run-demo/ with a pmap
fan-out of LLM calls (exercises the worker dots + heap movement).

## Refinement round 1 (done)

- **LiveStore lifecycle**: no longer a lazy singleton — started by
  `PtcViewer.Server` and bound to it by monitor (any server exit stops the
  store); router reads it from config and answers 503 when absent.
- **Tests**: `live_store_test.exs` (frames, fan-out, eviction, owner-down,
  launch gate), `live_router_test.exs` (frame POST/GET, disabled paths,
  launch describe), root `live_status_test.exs` (a run succeeds unchanged
  when the configured viewer is unreachable).
- **Decision — no `--viewer-url` CLI flag yet**: run options flow through the
  command declaration/parser/contract with generated schemas; plumbing a flag
  cascades into `mix ptc.gen_docs` artifacts. The env var stays for the spike;
  the flag is proper-PR work.

## Launch a run from the Viewer (done)

Fixed target, editable input: the launch target (manifest, extra CLI args,
cwd, label) is configured by the operator at `PtcViewer.start(launch: %{...})`
and never taken from the browser. The browser edits exactly one thing — the
input object.

- `PtcViewer.LiveLaunch` validates the spec, describes it (`GET
  /api/live/launch` returns the manifest's current `input.value` to seed the
  editor), and prepares the run command.
- `POST /api/live/launch` writes the edited input **beside the manifest**
  under a fixed name and passes it as `--input live-input.json` — learned the
  hard way: `--input` is a *logical name resolved inside the manifest's
  confined application directory*; an absolute path or any path outside it
  fails with `application/reference_missing`. The file is removed when the
  run exits.
- The run is an ordinary `mix ptc run` child process pointed back at the
  Viewer with `PTC_VIEWER_URL`, so Viewer-launched runs use the exact same
  live channel as CLI-launched ones. `LiveStore` enforces single-flight; the
  launch result (exit code + output tail) is captured from the monitor DOWN
  reason and surfaced in the panel (verified for both the failure and the
  success path in the browser).

## Refinement backlog (still open)

Round 3 (run lifecycle, project details panel, missions) is specified in
[viewer-live-run-round3.md](viewer-live-run-round3.md).

- `--viewer-url` CLI flag + project-config field (see decision above)
- REPL / manifest-REPL / analysis-session reporter coverage
- Frame + launch authentication (share the `x-ptc-viewer-session` pattern)
  before the Viewer ever binds beyond loopback
- Provider-task in-flight count + admission queue depth accessors (#1444 table)
- Heap sampling for pmap workers (spike samples the main sandbox only)
- Multiple launch targets / project-config-driven target discovery
- Docs + `mix precommit` clean-up, duplication gate, dialyzer
- Delete this plan file before any final PR (repo rule)
