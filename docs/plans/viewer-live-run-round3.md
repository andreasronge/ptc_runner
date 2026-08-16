# Round 3 brief: run lifecycle + project details (+ missions if #1445 merged)

Audience: the scheduled cloud agent continuing this branch
(`feat/issue-1444-viewer-live-run`, issue #1444) — and any human reviewer.
This file is the authoritative spec for round 3; the scheduled prompt only
points here. Prior context: `docs/plans/viewer-live-run-spike.md` (rounds 1–2)
and the two comments on issue #1444.

## State of the branch (so you don't rediscover it)

- **Run side**: `lib/ptc_runner/live_status.ex` + `live_status/reporter.ex` —
  opt-in via `PTC_VIEWER_URL`; posts self-contained JSON frames (~3/s) to the
  Viewer. Telemetry emits live in `sandbox.ex` (rebaseline), `lisp.ex`
  (ParallelBudget), `dispatcher.ex` (capability start/stop). Hooked in
  `runner.ex` `run_claimed/3`. Best-effort by contract — pinned by
  `test/ptc_runner/live_status_test.exs`.
- **Viewer side** (`ptc_viewer/`, has NO ptc_runner dependency — kernel access
  is always host-injected adapters):
  - `lib/ptc_viewer/live_store.ex` — Server-owned (monitor-bound) store +
    SSE fan-out + single-flight launch gate.
  - `lib/ptc_viewer/live_launch.ex` — fixed operator-configured launch target;
    browser edits only the input object; input written **beside the manifest**
    (`--input` is a logical name confined to the manifest directory —
    absolute paths fail with `application/reference_missing`).
  - `lib/ptc_viewer/router.ex` — `POST/GET /api/live/runs*`,
    `GET /api/live/stream` (SSE), `GET/POST /api/live/launch`; helpers
    `live_store/1`, `live_launch/1`, `live_port/1`, `send_live_json/3`.
  - `lib/ptc_viewer/server.ex` — starts LiveStore, validates `launch:` opt,
    threads config via `router_config/5`.
  - Frontend: `priv/static/js/live.js` (`createLiveController`, `initLaunch`,
    `createCard`/`updateCard` with `data-role` field maps — cards are built
    once and updated in place), `index.html` (Live tab + panels),
    `css/styles.css` (Live + launch sections at the bottom; dark token set;
    categorical colors `--live-eval #2f86d2` / `--live-cap #c97b2e`, both
    validated).
  - Tests: `test/ptc_viewer/live_store_test.exs`, `live_router_test.exs`.
- Demo target: `docs/plans/viewer-live-run-demo/` (manifest + demo.clj +
  media). Repo rule: **no `Process.sleep` in tests**; format viewer files from
  `ptc_viewer/`.

## Step 0 — Rebase onto origin/main

PR #1445 (`feat(repl): add manifest mission sessions` — `mix ptc repl
--mission NAME`, project-first selection) is expected to be merged. Verify.

Conflict rules (repo policy):
- `priv/semantic_build_projection.json`: take main's version verbatim; never
  hand-merge or regenerate on a feature branch.
- Generated artifacts (`docs/function-reference.md`,
  `docs/kernel-limits-reference.md`, `priv/schemas/`, `docs/conformance/`):
  take main's side; re-run `mix ptc.gen_docs` only if your own changes
  require it.
- After rebase: `mix compile` clean, then
  `mix test test/ptc_runner/live_status_test.exs` and
  `cd ptc_viewer && mix test test/ptc_viewer/live_store_test.exs
  test/ptc_viewer/live_router_test.exs`.

## Phase A1 — Run lifecycle in the Live tab

Goal: old runs must be closable and must stop dominating the page.

1. **Delete**: `LiveStore.delete_run(store, run_id)` (+ handle_call), router
   `DELETE /api/live/runs/:run_id` → 200 `{"status":"ok"}` (404 JSON when
   unknown; 503 pattern as the other live endpoints). Client: ✕ button on
   every card (top-right of `live-card-head`) → DELETE + remove card from the
   `cards` map and DOM.
2. **Auto-collapse ended runs**: when a frame arrives with `phase != running`,
   the card gains a collapsed presentation — one line: outcome badge, label,
   elapsed, tool-call count, run id — with an expand/collapse toggle
   (chevron). Only the **most recently ended** run stays expanded; ending a
   new run collapses the previous one. Running cards are never collapsible.
   Implement as a `collapsed` class on `live-card` hiding everything but a
   `live-card-summary` row (build the summary row into `createCard`, update it
   in `updateCard`; keep the update-in-place pattern — do not re-render
   innerHTML per frame).
3. **Clear ended**: a small "clear ended" control in a new runs section header
   (visible only when ≥1 ended run) → DELETE each ended run.
4. Tests: `delete_run` in the store test; DELETE endpoint (present + unknown
   id) in the router test.

## Phase A2 — Project details panel

Goal: see the project — environments, limits, tools, components/preludes with
source — without changing the default view at all.

### Adapter contract (host → viewer)

New `project_adapter` option on `PtcViewer.start/1` (validate like `launch`:
zero-arity fun or module exporting `describe/0`; invalid → startup error).
Thread through `server.ex` params → `router_config` → router. It returns:

```elixir
%{
  name: "live-dashboard-demo",          # display name (label or manifest name)
  manifest: "docs/plans/.../ptc.json",  # path as configured
  entry: "demo.live/run",
  environments: [
    %{
      name: "workflow",                  # or the mission name
      kind: "workflow",                  # "workflow" | "mission"
      components: [
        %{id: "demo.live", path: "demo.clj", source: "(ns demo.live ...)"},
        %{id: "llm", library: true, source: "(ns llm ...)"}
      ],
      providers: [%{name: "deepseek", source: "llm"}],
      tools: [%{name: "llm-request", effect: nil}]   # effect "read"|"write"|nil
    }
  ],
  limits: [
    %{name: "run_duration_ms", effective: 120_000, default: 30_000},
    ...all catalog rows, effective == default when unchanged...
  ]
}
```

The viewer treats this as opaque data: `GET /api/live/project` returns it
JSON-encoded (or `{"enabled": false}` without an adapter). Errors from the
adapter fun must not crash the request — rescue → `{"enabled": false}`.

### Host-side builder (root project)

New `lib/ptc_runner/kernel/viewer_project_adapter.ex` (or a sensibly named
module near the other viewer adapters): builds the map above from a manifest
path (+ optional host-config path). Spike-honest sourcing:

- Manifest JSON: parse directly (`Jason`); environments = `workflow` +
  `missions` map; providers from `providers.workflow` / per-mission.
- Limits: `PtcRunner.Kernel.Limits.new(manifest_limits)` vs
  `Limits.defaults()`; emit every catalog row with effective + default
  (`PtcRunner.Kernel.LimitCatalog` has names/defaults).
- Component source: file components read relative to the manifest dir;
  shipped libraries (`{"library" => name}`) via
  `PtcRunner.Kernel.Library.component(name)` — inspect its struct for source;
  fallback `File.read(Path.join(:code.priv_dir(:ptc_runner),
  "priv/preludes/kernel/#{name}.clj"))`-style (verify actual path — priv dir
  already IS priv).
- Tools: best-effort — from the host config JSON's `install` entries when a
  host-config path is supplied (tool names + `effect`), else provider names
  only with `tools: []`. Do not guess effects.
- Root-side test with the demo manifest in
  `docs/plans/viewer-live-run-demo/ptc.json`.

### UI

One-line **project strip** above the launch panel (only when the endpoint says
enabled): `name · manifest · entry  [Details ▸]`. The disclosure expands a
panel with three sections, counts-first, all collapsed by default:

```
ENVIRONMENTS
  workflow    2 components · 1 provider          (row expands: tools with
  <mission>   ...                                 effect badges, components;
                                                  component click → source)
LIMITS      3 narrowed from defaults   [show all]
  run_duration_ms   120 000   (default 30 000)   (deltas listed; full table
                                                  behind the toggle)
COMPONENTS & PRELUDES
  demo.live · llm (shipped)                      (click → source pane)
```

Source pane: monospace `<pre>`, **HTML-escape the source before inserting**
(`textContent`, never innerHTML with raw source). Syntax highlighting is
optional polish; correctness first. Styles: extend the Live CSS section with
the existing tokens; no new colors needed.

Router/JS tests: `GET /api/live/project` with a stub adapter in
`router_opts`, and the disabled case.

## Phase B (ONLY if #1445 is merged AND Phase A is green)

Mission chips on the launch card. Environments come from
`/api/live/project`. Selecting a mission:

- swaps the input-JSON editor for an **expression** field (seeded
  `(<entry-ns>/<fn> data/input)`-style is fine to leave empty with a
  placeholder),
- Run launches the mission one-shot through the existing `LiveLaunch`
  single-flight gate with a different command shape — read the **merged**
  `docs/guides/kernel-repl.md` for the exact invocation (`mix ptc repl
  --mission NAME` is project-first per the PR; check whether
  `--manifest`/`--host-config` or `--project` is required and use whatever
  the guide documents, with `-e '<expr>'`).
- Mission sessions do NOT go through `Runner`, so no live frames yet — the
  launch status line (exit code + output tail) is the result surface for now;
  note "reporter coverage for REPL/mission sessions" stays on the backlog.

If time, confidence, or the merge is missing: write your Phase B findings into
this file instead of shipping half of it.

## Constraints (unchanged from the spike)

- No OpenRouter credentials, no browser in this environment: verification is
  compile + tests only — say so in commit messages. Do not use
  `--env-file .env`; do not attempt live-model runs.
- No `mix precommit`. `mix format` what you touch (viewer files from
  `ptc_viewer/`). Stage files explicitly — never `git add -A`.
- Conventional commits; when done:
  `git push --no-verify --force-with-lease origin feat/issue-1444-viewer-live-run`.
- If rebase conflicts exceed confidence: do NOT force-push — push your work to
  `feat/issue-1444-viewer-live-run-phase-a` and say so.
- Update this file and the spike plan's backlog with what landed; comment
  briefly on #1444 if `gh` is authenticated, else skip silently.

## Acceptance checklist

- [ ] Rebased on origin/main; compile + existing live tests green
- [ ] ✕ removes a run (client + server); reload does not resurrect it
- [ ] Ended runs collapse; newest ended stays expanded; "clear ended" works
- [ ] `GET /api/live/project` serves the adapter payload; `enabled: false`
      without an adapter; adapter errors never 500
- [ ] Project strip + Details panel render; limits show deltas first;
      component source is escaped text
- [ ] New/updated tests pass in both projects; no `Process.sleep`
- [ ] Plan files updated; branch pushed with `--force-with-lease`
