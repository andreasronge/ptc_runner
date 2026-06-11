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

Keep harness scripts out of ptc_runner (domain-blindness: core repo stays
generic). Extend `~/ptc-mcp-sandbox/`.

1. **Runner:** for each seed: generate variant (WP-B), start fixture server,
   launch headless Claude Code (`claude -p --allowedTools` pattern,
   `--tools ""` + ptc MCP config with `--sessions --turn-log-dir`), task
   prompt from a template parameterized by org/environment (spend-spike
   style), capture client `stream-json` + server turn-log JSONL, teardown.
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

## Suggested session split

- Session 1 (ptc_runner): WP-A. Read this doc +
  `turn-log-and-prelude-derivation.md` (D1/D2, P2/P3 sections) first.
- Session 2 (tilda-observatory): WP-B. Needs the running real stack once
  (golden capture), then never again.
- Session 3 (sandbox): WP-C steps 1–3 (M1). M2 after the WP-A prelude-flag
  follow-up.
