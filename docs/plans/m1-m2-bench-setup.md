# M1/M2 Bench Setup — Work Packages

**Status:** implementation-ready handoff spec (2026-06-11). Defines the three
work packages between "P1–P3 shipped" and "run the M1/M2 gates" from
[`turn-log-and-prelude-derivation.md`](turn-log-and-prelude-derivation.md).
Each package is independent and sized for one focused session; WP-A and WP-B
can run in parallel (different repos).

## Context — what already exists (do not rebuild)

Shipped on `main` (commits `88ac00e7` P1, `1ab6e641` P2, `04eac9ab` P3,
`bf99023e` provenance/preview fixes, `be7dcc91` repl `--log-prelude`, plus the
`args_hash` tool-call summary work):

- **Turn log**: `PtcRunner.TraceLog.TurnEvent` (canonical `event: "turn"`
  shape, both drivers), `MemorySink` (byte-budget ring buffer),
  `TraceLog.record_turn_event/1` (fans out to all active collectors + memory
  sinks), `Analyzer` cross-session queries. `Session` has `session_id`,
  committed `turn`, monotonic `attempts`; emits on success AND failure.
- **Duplicate detection**: `TurnEvent.tool_call_summary/1` — shared
  projection with `args_hash` (raw args/results never exposed; equivalent
  args hash identically across drivers). PTC-Lisp can already find duplicate
  calls by grouping on `[tool, args_hash]`.
- **`log/` introspection prelude**: `PtcRunner.TraceLog.Introspection` —
  `prelude_source/0` + `tools/1` over a source (memory-sink pid | JSONL path
  | event list). `tool:<name>` requires fail closed without the grant.
- **`mix ptc.repl`** drives a `PtcRunner.Session` with a default in-memory
  sink, `:turns` command, and `--log-prelude`.

**What is missing** (verified against source): the MCP server records
nothing — `mcp_server/lib/ptc_runner_mcp/sessions/session.ex` keeps its own
`memory`/`turn_history`/`turn` fields, never touches `PtcRunner.Session`, and
no turn-log or prelude config exists in `mcp_server`. Real agent sessions
(headless Claude Code over MCP — the realistic driver) are therefore
invisible to the turn log. That is WP-A.

## WP-A — `ptc_runner_mcp`: record real agent sessions (repo: ptc_runner)

> **Status: DONE** (commit `4f14016f` + `tool_call_summary` upstream-lift fix;
> end-to-end smoke passed 2026-06-11: a real headless Claude Code session
> against the sandbox server produced 3 canonical turn events with lifted
> upstream tool identity and a working `args_hash`, introspected via the
> `log/` prelude). The `--prelude` server flag remains a follow-up for M2.

**Goal:** a headless Claude Code session against `ptc_runner_mcp --sessions`
produces canonical turn events in a JSONL file, correlated by the
client-visible MCP session id (`ptcs_...`).

**Integration point — emit at `commit_eval`, not inside the worker.** The MCP
eval flow is snapshot-based with optimistic commit:
`Sessions.reserve_eval` → worker runs `Sessions.run_snapshot` (calls
`PtcRunner.Lisp.run` directly) → `Sessions.commit_eval` (owner/expiry checks
may REJECT the commit). Do **not** refactor this to call
`PtcRunner.Session.eval` on the worker: value-style emission inside the
worker cannot know whether the commit will be accepted, so its `committed`
flag could lie. Instead the MCP server is a third emission site of the SAME
shared builder (consistent with plan D1: substrate owns schema+builder,
drivers emit at their own boundaries):

1. In the session GenServer at commit time, build the event with
   `TraceLog.TurnEvent.build/1`: `driver: :session`, `session_id` = the MCP
   session id, `turn`/`attempts` from session state (add an `attempts`
   field: advances on every committed eval result incl. `{:error, _}`;
   `turn` advances only on successful commits), `committed`/`status` from
   the result, `program`, `result_preview` via `TurnEvent.preview/1`,
   `memory_diff` via `TurnEvent.memory_diff/2` (pre-commit vs post-commit
   memory), `tool_calls` via `TurnEvent.tool_call_summary/1`, prelude
   provenance when a prelude is attached.

   Outcome taxonomy (decided):
   - eval ok + state applied → `attempts+1`, `turn+1`, `committed: true`,
     `status: "ok"`;
   - eval failed in the sandbox → `attempts+1`, `turn` unchanged,
     `committed: false`, `status: "error"`, `fail` from the Step;
   - eval ran, commit was accepted, but session-state rejected the result
     (return validation failure, session limits: binding/memory budgets, max
     bindings) → `attempts+1`, `turn` unchanged, `committed: false`,
     `status: "error"`, with the session-level reason in `fail` (for example
     `validation_failed` or `session_limit_exceeded`) and/or `limits_hit` so
     M1 can distinguish "program broke" from "limits/validation rejected the
     result"; keep the genuine `result_preview` when the program itself
     succeeded — the work (and its upstream calls/tokens) happened and must be
     visible;
   - commit rejected outright (owner mismatch, expiry, request-id race) →
     emit nothing: transport/ownership races, not LLM work, and the session
     identity is in doubt.
2. **Known integration wrinkle:** `TraceLog.record_turn_event/1` reads
   process-scoped `TraceContext` sinks. The session GenServer won't have
   them. Pick the minimal mechanism: either attach the collector/sink to
   session processes at spawn, or add a small server-global sink registration
   (persistent_term holding the collector pid, set at startup). Prefer
   mcp-side wiring; only extend core `TraceLog` if a global-sink option turns
   out to be the clean cut. Do not break core's process-scoped model.
3. CLI flag `--turn-log-dir <dir>` (mirroring `--trace-dir` conventions):
   when set, start a JSONL collector at startup and emit turn events for all
   session evals. Off by default.
4. Deduplicate against the existing per-request `--trace-dir` files only in
   docs (they coexist; trace files = envelope debug log, turn log = session
   record).

**Defer to a follow-up (needed for M2 condition B, not M1):** `--prelude
<file>` server config attaching a prelude to session evals (thread through
`run_snapshot`'s `Lisp.run` opts; attach-time `tool:`/`upstream:` validation
already works via `AttachContext`).

**Acceptance:**
- Integration test (mcp_server suite): start sessions, eval 3 programs (one
  failing), assert the JSONL contains 3 turn events with the MCP session id,
  correct `turn`/`attempts`/`committed`, `args_hash` in tool_calls, and that
  `Analyzer.session_turns/2` + the `log/` prelude can read them.
- Manual smoke: `claude -p` headless against the server (the
  `~/ptc-mcp-sandbox/run-sessions.sh` setup), then inspect the JSONL with
  `mix ptc.repl --log-prelude`.

**Caveats for the implementing session:** run `mix precommit` before commit
and `codex review` before merge (hard gate). Two `mcp_stdio` tests flake in
this sandbox (subprocess stdio `:epipe`) — pre-existing, push may need
`--no-verify`. CI dialyzer runs `MIX_ENV=test mix dialyzer`.

## WP-B — tilda-observatory: extractable bench upstream (repo: tilda-observatory)

**Goal:** replace the heavy stack (Docker + Postgres + web app) with a
drop-in fixture backend for bench runs, plus a seeded variant generator.
The agent-visible contract is only: `docs/observatory.openapi.json` (served
to ptc_runner as a local `schema_file`) + JSON responses for `list_traces`,
`get_trace`, `list_trace_steps` + bearer auth. `upstreams.json` must keep
working unchanged (same port 3333, same spec file, same token env).

**Order matters — capture goldens first** while the real stack still runs:

1. **Golden contract capture (~1h):** with the seeded dev server up, curl and
   save responses: `list_traces` (plain, org+environment filters, a
   date-window filter (`start-date`/`end-date`), an explicit `limit`, cursor
   pagination page 2, empty result, malformed cursor error), `get_trace` (by
   UUID, by human `trace_id`, not-found error), `list_trace_steps` (by both
   id kinds), plus the 401 unauthorized body. The fixture server must honor
   **every** query param the OpenAPI spec documents (the spec is reused
   verbatim, so the agent may use any of them — silently ignoring a filter
   diverges semantically in a way shape-level contract tests cannot catch).
   Note the cursor format during capture; generated cursors must round-trip
   the same way. Commit the goldens so contract tests run in CI. Store under e.g.
   `tools/bench-upstream/goldens/`. Use the realistic seeded traces from
   `seed-local.ts` (e.g. `prod-acme-runaway-cost-a8d2`) and record the
   captured UUID↔`trace_id` pairing in a small meta file so the by-UUID
   goldens stay interpretable (UUIDs are seed-run-specific; goldens are
   shape contracts, not value contracts).
2. **Variant generator:** params `--seed`, anomaly type (`runaway-loop` |
   `retry-storm` | `expensive-model` | `fanout`), target org, magnitude,
   trace count, decoy noise → emits `traces.json` + per-trace
   `steps/<id>.json` + `manifest.json` recording the planted `trace_id` and
   expected facts (total cost, dominant factor). The manifest is the
   **non-shortcuttable oracle**; trace ids are randomized per seed so no
   prelude (human- or agent-written) can memorize answers.
3. **Fixture server (single file, TS in `tools/bench-upstream/` so it can
   share trace-shape code with `tools/database/src/scripts/seed-local.ts`):**
   serves the 3 OpenAPI operations as plain HTTP routes from a fixture dir,
   bearer-token check, port 3333. **Naming:** implement the OpenAPI
   `operationId`s the agent sees (`list_traces`, `get_trace`,
   `list_trace_steps` — what `upstreams.json` `include_operations` selects),
   i.e. the HTTP routes (`GET /api/v1/traces`, `GET /api/v1/traces/:id`,
   `GET /api/v1/traces/:id/steps`). The app's own MCP endpoint and its
   `get_trace_steps` tool name are NOT in scope — the bench path is
   ptc_runner's OpenAPI transport, never the app's MCP server.
4. **Contract test:** fixture server responses match the goldens at
   shape/field level (not values).

**The non-negotiable design rule — preserve inconvenient realism.** The API's
frictions are what make a prelude valuable; sanitizing them deflates M2's
measurement (false negative on the whole value hypothesis). Replicate
exactly: string-encoded costs (`"0.017600"`), cursor pagination +
`next_cursor: null` on `list_traces`, `has_more` on `list_trace_steps`
(only there — `list_traces` has no `has_more`), UUID `id` vs human
`trace_id` duality, snake_case keys, `data` JSONB bags with free-form notes.
**Error shapes are the HTTP-level REST contract from the goldens** — e.g.
`{ "error": "Unauthorized" }`, `{ "error": "Invalid cursor" }`, empty 404 —
with the real status codes, never 500s. (ptc_runner's upstream layer is what
turns these into `isError` tool results; the fixture itself is plain HTTP.)

**Acceptance:** point `upstreams.json` at the fixture server; the spend-spike
interaction sequence (doc → list filtered → steps) works identically from
`ptc_runner_mcp`; contract test green; two different seeds produce different
planted trace ids with consistent shapes.

## WP-C — bench harness + M1/M2 protocol (repo: sandbox dir, not ptc_runner)

> **Status: steps 1–3 DONE, M1 gate PASSED** (2026-06-11). Harness in
> `~/ptc-mcp-sandbox/bench/` (`bench-run.sh`, `bench-metrics.py`,
> `task-prompt.template`, `m1-introspect.exs`); full findings report in
> `~/ptc-mcp-sandbox/M1-findings.md`, per-run artifacts in
> `bench/runs/seed-*/`. 6 sessions recorded (seeds 11–16, sonnet, all four
> anomaly types); oracle 5/5 on valid runs. **Harness caveat discovered:**
> the variant generator always plants the anomaly in `production` — a prompt
> pointing elsewhere makes the oracle unsatisfiable (seed-15 became an
> accidental control this way). See the M1 findings summary below; M2
> remains blocked on the WP-A `--prelude` follow-up.

Keep harness scripts out of ptc_runner (domain-blindness: core repo stays
generic). Extend `~/ptc-mcp-sandbox/`.

1. **Runner:** for each seed: generate variant (WP-B), start fixture server,
   launch headless Claude Code against the ptc MCP server
   (`--sessions --turn-log-dir`), task prompt from a template parameterized
   by org/environment (spend-spike style), capture client `stream-json` +
   server turn-log JSONL, teardown. **Verified launch pattern (claude CLI
   2.1.173, smoke-tested 2026-06-11; reference: `~/ptc-mcp-sandbox/
   run-turnlog.sh` + `mcp-turnlog.json`):**
   - `MCP_TIMEOUT=60000` env is REQUIRED — the ~2.5 s `mix run` boot exceeds
     the default MCP startup timeout and the server is dropped silently.
   - Do NOT use `--tools ""` — it now strips MCP tools too (the
     spend-spike-era pattern is gone). Restrict with `--allowedTools
     "mcp__<server>__lisp_session_*"` plus a prompt-level instruction.
   - Upstreams config: `"transport"` must be `"mcp_stdio"` (or
     `"openapi"`/`"mcp_http"`); the old bare `"stdio"` fails boot.
   - Each server spawn writes a fresh `<ts>-<rand>-turns.jsonl`; failed
     client connects leave header-only files — resolve the session's file
     per run, don't assume one file per directory.
2. **Metrics:** from the turn log (Analyzer or `log/` prelude): turns,
   attempts, upstream call count, duplicate fetches (group by
   `[tool, args_hash]`), payload metrics; from stream-json: client tokens;
   oracle: planted `trace_id` from `manifest.json` present in the final
   answer.
3. **M1 (gate):** record 3–5 sessions on different seeds. Then one session
   (repl or headless) with the `log/` prelude over the recorded JSONL answers
   "where was work duplicated / wasted?" — write down the findings. Failure
   → fix introspection/turn log, not derivation.
4. **M2 (gate, needs WP-A's `--prelude` follow-up):** a HUMAN writes an
   `obs/` prelude from M1 findings (normalize rows, parse costs, top-by-cost,
   per-step tabulate — whatever M1 showed recurring). A/B on FRESH seeds the
   prelude author never saw: 5–10 runs per condition, same driver both
   conditions. Detecting large effects (e.g. 9→6 turns), not P5 statistics.
   Leakage rules are mandatory even though manual: fresh seeds, randomized
   planted ids, prelude written before eval seeds are generated. M2's prelude
   becomes the gold standard P4 automation is later judged against.

## M1 findings summary (2026-06-11; full report `~/ptc-mcp-sandbox/M1-findings.md`)

Headline numbers across 6 sessions: 63 eval attempts / 56 committed turns;
40 upstream calls of which only 21 unique `(tool, args_hash)` groups — **18
within-session duplicate fetches (45%)** plus 1 cross-session; 24/63 turns
(38%) spent on catalog discovery; 7 failed attempts; client side 86 turns,
~21k output tokens, $1.79.

**Waste patterns (input for the M2 `obs/` prelude author):**

- **W1 fetch-then-reshape without memory** — 0/63 programs used `(def ...)`;
  the same upstream call is repeated 2–3× with identical args (inspect shape
  → project fields → print rows). Accounts for all 18 duplicate fetches.
- **W2 fixed discovery prelude** — every session opens
  `(tool/servers)` → `(dir ...)` → `(doc <first op>)`, re-deriving identical
  information per session.
- **W3 id-vs-trace_id param guess** — 6/6 sessions: for the second operation
  used, guess `{:trace_id ...}`, fail (`missing required args id`), read the
  doc, retry with `{:id ...}` — a 2-turn tax every session. Docs are read
  only *after* the first failure of an op.
- **W4 string-encoded cost arithmetic** — one hard failure (`sort-by`
  negating `"0.018600"`); other sessions avoided computing costs by printing
  and eyeballing rows.
- **W5 println/doseq discards** — committed turns returning `[nil nil ...]`
  with the real data in `prints`: analysis flows through the client
  transcript instead of session memory.

**Introspection-surface gaps (fix/consider before M2):**

- **F1** `log/turns` projection drops `data.fail` — a prelude-only analyst
  sees `status: "error"` but never *why* (W3 was only diagnosable from raw
  JSONL). Cheap fix: add fail reason/message to
  `Introspection.project_turn/1`.
- **F2** catalog ops (`tool/servers`/`dir`/`doc`) are invisible in
  `tool_calls`; discovery overhead (38% of turns) is only recoverable by
  pattern-matching program source. `Step.catalog_ops` exists — consider
  lifting it into the turn event.
- **F3** default ~10MB `max_heap` kills ordinary grouping analyses over just
  40 tool-call rows. **Root cause (measured 2026-06-11):** granting tool
  closures that capture the in-memory event list costs ~9–12MB of *accounted*
  sandbox heap before the program runs an instruction — `(+ 1 2)` under the
  `Introspection.tools(events)` grant needs ~11.6MB. The cost comes from
  `include_shared_binaries: true` accounting of refc binaries (strings >64B:
  programs, previews, hashes) referenced by the grant: ~2.5–5× the binary
  payload, while 2MB of small-string/on-heap captured data costs nothing.
  All "failing idioms" were noise at this cliff edge (the analyses themselves
  need only ~1–3MB). **Fix directions:** (a) handle-based introspection
  sources — a JSONL-path source has zero overhead, already supported;
  (b) core: re-baseline or GC after grant setup so long-lived shared
  binaries the sandbox merely references don't consume the program's budget;
  (c) kill diagnostics should report the heap vs binary-vheap split. Raising
  the default alone just moves the cliff.
- **F4** the documented vector-key flex-access DIV makes
  `(get groups [tool hash])` after composite-key `group-by` silently return
  `nil` — the textbook dedup idiom reports "no duplicates". Workaround:
  iterate `(vals groups)`; prelude grouping helpers should route around it.

## Suggested session split

- Session 1 (ptc_runner): WP-A. Read this doc +
  `turn-log-and-prelude-derivation.md` (D1/D2, P2/P3 sections) first.
- Session 2 (tilda-observatory): WP-B. Needs the running real stack once
  (golden capture), then never again.
- Session 3 (sandbox): WP-C steps 1–3 (M1). M2 after the WP-A prelude-flag
  follow-up.
