# Turn Log and Prelude Derivation — Plan

**Status:** agreed direction with sequenced phases, distilled from a design
discussion (2026-06-11) around a real analysis session. Phases P1–P3 are
implementation-ready in shape; P4 is **gated** behind two measured
milestones (M1/M2, below) to avoid overfitting automation to one observed
session; P5's methodology is piloted manually in M2. Companion docs:
[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
(the broader exploratory control surface — most of it stays deferred),
[`capability-prelude-discovery.md`](capability-prelude-discovery.md)
(authority model),
[`capability-kernel-runtime.md`](capability-kernel-runtime.md)
(closed-context guard / RunEnv boundary),
[`future-directions.md`](future-directions.md) (idea backlog).

## Motivation: evidence from a real session

A filesystem-less Claude Code agent (`--tools ""`) solved a production
debugging task using only the `ptc_runner_mcp` session tools against a remote
OpenAPI upstream (the org-acme spend-spike investigation; transcript in the
`tilda-observatory` repo, `docs/ptc-sandbox-spend-spike-report.md`). The
session worked — ~$0.26 / 105K agent tokens to diagnose an $11.76 incident —
and exposed exactly where the loop wastes effort:

- **3 of 9 LLM turns were setup/discovery.** Session start, a `(doc ...)`
  call whose result was truncated to uselessness at 512 chars, and a re-fetch
  via `println`.
- **One duplicate upstream fetch.** `list-traces` called once to inspect the
  shape, again to bind the data.
- **Envelope redundancy.** The same data appeared up to 4× per envelope
  (result preview + `memory.changed` echoes); the largest single context
  ingest of the session was a memory echo.
- **The analysis code was generic.** Normalize rows, parse cost strings,
  sort, outlier ratio, per-step tabulation — reusable in any investigation
  against the same upstream, rewritten from scratch every session.

Caveats, stated honestly: this is n=1; the planted anomaly was easy (1,089×
outlier with the root cause written in a data note); and turn count is not
dollars (output tokens dominated cost). The phases below include the
benchmark that turns these observations into measurements.

### Why this and not something else

Major code-mode tools (Anthropic code-execution-with-MCP, Cloudflare Code
Mode, CodeAct-style agents) can bridge MCP/HTTP into a sandbox and would have
solved this *task*. What they do not have, and what this plan invests in:

1. **Zero-ambient-authority sandbox at process cost.** Granting a container
   network egress to a production API means rebuilding the allowlist
   machinery PTC already has. Here a sandbox is a BEAM process and authority
   is exactly the granted tool closures.
2. **REPL sessions as durable, inspectable working memory** with named
   bindings, memory-diff feedback, and bounded budgets — not scratch files.
3. **Sessions as replayable data artifacts** that the runtime itself can
   analyze.
4. **The closed loop this plan builds:** session traces are data → PTC-Lisp
   (or a SubAgent) analyzes them → the output is a *prelude* — executable,
   compiler-validated, host-bound, discoverable via `doc`/`apropos` in the
   next session. Other tools throw generated code away; nothing in their
   loop turns yesterday's session into tomorrow's standing library.

## Architecture decisions

These were settled in discussion and constrain all phases.

### D1. One turn substrate, two drivers

A `PtcRunner.Session` turn (external LLM drives, via MCP client or
`mix ptc.repl`) and a SubAgent loop turn (internal loop drives the LLM) are
the same machinery with inverted control. The code already leans this way:
both run on `PtcRunner.Lisp.run/2`, and the MCP session envelope reuses the
SubAgent loop's feedback rendering
(`mcp_server/lib/ptc_runner_mcp/sessions/projection.ex` →
`PtcRunner.SubAgent.Loop.TurnFeedback`).

The cut line:

- **Substrate (shared):** Lisp env, memory, turn history, feedback
  rendering, limits, and the (new) turn-log event **schema + builder**.
- **Driver-specific (never merged):** LLM message history, prompt assembly,
  turn-limit policy on the SubAgent side; transport and envelope shaping on
  the MCP side. Drivers also own **emitting** turn events at their own turn
  boundaries: a SubAgent turn includes prompt assembly, LLM calls, no-code /
  parse-failure turns, and budget stops that never reach `Lisp.run`
  (`lib/ptc_runner/sub_agent/loop.ex`), so the eval path cannot be the sole
  emission point.

Do not make SubAgent "a kind of session" or vice versa. Invest in the
substrate; keep two thin drivers.

### D2. Core-first; the MCP server stays a thin projection

Every capability in this plan lands in core `ptc_runner` so that
`mix ptc.repl` and embedding applications get it directly. `ptc_runner_mcp`
only wraps core features as MCP tools and adds transport-specific config.
The session registry (`mcp_server/lib/ptc_runner_mcp/sessions/registry.ex`,
ownership/TTL/eviction) stays host-side for now; core `PtcRunner.Session`
remains a pure value. Lift a shared session-store behaviour only when a
second host demonstrably duplicates the registry logic.

### D3. Preludes are the sole opt-in mechanism (eventually)

The Capability Prelude V1 artifact (`PtcRunner.Lisp.Prelude`: protected
namespaces, exports with `:prompt` + `:discoverable`, `private_env`,
`source_hash`) becomes the single way to extend what a session or agent can
see and call. Two ingredient kinds, kept explicit:

1. **Pure functions** (e.g. `grep`/`grep-n`, today unconditional `Runtime`
   defdelegates): implementation stays in Elixir core; the prelude controls
   namespace, visibility, and curated docs. Packaging change only.
2. **Authority-bearing capabilities** (turn-log queries, upstream calls,
   LLM aliases): the prelude *references* a capability by name (`requires`);
   the **host binds it at attach time**; attach fails closed when a required
   capability is not granted. A prelude wraps authority — it never mints it.

The existing optional-tools surface is replaced by utility preludes once the
pattern is proven (see migration order in P3). 0.x rules apply: delete the
old mechanism, no compatibility shim.

### D4. Two-grant rule for agents touching sessions

- **Grant now:** read-only introspection over recorded sessions (list,
  turns, programs, envelopes, metrics) as host-bound capabilities.
- **Defer:** live session control from agent code (eval-into, fork, drive).
  That is the full control plane with its escape-hatch risks (nested limit
  inheritance, authority laundering). The derivation loop does not need it:
  the agent *proposes*, the *host* verifies in a fresh scratch session and
  feeds results back.

Recorded sessions are **untrusted data** — they may contain adversarial or
junk programs. Introspection consumers treat them as evidence, not
instructions (the `untrusted_ptc_output` framing already exists for this).

### D5. Naming: this is the turn log, not the journal

"Journal" is taken: the LLM-facing `(task "id" expr)` / `(step-done ...)`
capability (`lib/ptc_runner/prompts.ex`, LanguageSpec `:journal`), which is
slated for replacement independently. The durable record introduced here is
the **turn log** (an extension of `PtcRunner.TraceLog`). When the journal is
eventually rebuilt, it should become a *projection* over turn-log events
(filter to semantic progress, render for the LLM) rather than bespoke loop
state — but journal replacement is not part of this plan.

## Phases

### P1 — Doc ergonomics (smallest, immediate win)

**Status: shipped** (`88ac00e7`). User docs: `docs/guides/subagent-observability.md`.

**Problem.** PTC-Lisp `doc` returns a string
(`PtcRunner.Lisp.Discovery.doc/1` → `{:ok, String.t()}`), so doc text lands
in the result channel, which has the harshest budget
(`validated_preview_chars: 512` in the `:slim` profile,
`mcp_server/lib/ptc_runner_mcp/output_limits.ex`). Prints get 8–64KB. The
observed session burned a full turn on this.

**Change.**

- Make **`doc` only** print and return `nil`, matching `clojure.repl/doc`
  semantics (restores conformance — returning a string is the current
  divergence) and routing doc text through the print budget.
- **`dir`, `apropos`, and `meta` keep returning structured data.** Existing
  code and tests consume their `step.return` programmatically
  (`test/repl_discovery_test.exs`), and discovery-as-data is a design goal
  of this plan (P3/P4 consume discovery results in programs). Record
  dir-prints-vs-returns as a deliberate divergence in
  `docs/clojure-conformance-gaps.md`.
- **Print-cap interplay, specified:** prints have a Lisp-level per-entry cap
  *before* any MCP budget applies — `:max_print_length`, default 2000
  (`lib/ptc_runner/lisp/eval/context.ex`). `doc` output goes through the
  normal print path subject to that cap; no special bypass. Hosts that
  attach preludes with long docstrings configure `:max_print_length`
  accordingly (the MCP server should align it with its response-profile
  print budgets), and curated prelude docstrings should be written to fit.
- Update `docs/function-reference.md` and prompt templates that show `doc`
  usage (`priv/prompts/` — recompile after editing).
- Prelude exports carry curated docstrings (already in the Export record);
  operators tune what the model reads via the prelude, not via upstream
  schemas.

**Verify.** Session-driver tests with explicit fixture bounds:
(1) a doc text **longer than 512 chars and shorter than the 2000-char
default print cap** arrives complete through the print channel of a `:slim`
profile envelope — the case the old result-channel path truncated;
(2) a doc text longer than the default cap arrives complete when the host
raises `:max_print_length` (the configured-override path);
(3) existing `repl_discovery` tests for `dir`/`apropos` pass unchanged.

### P2 — Turn log: substrate telemetry + in-memory sink

**Status: shipped** (`1ab6e641`; provenance hardened in `78d4b8f2`, tool-call
hashing in `23deca22`). User docs: `docs/guides/subagent-observability.md`.

**Problem.** Telemetry exists at two layers already, but neither yields a
session-correlated record:

- `Lisp.run/2` is wrapped in `:telemetry.span/3` and emits
  `[:ptc_runner, :lisp, :execute, :start|:stop|:exception]` with `caller` /
  `profile` tags (`lib/ptc_runner/lisp.ex`). Implementers must **not**
  duplicate or bypass these events.
- The SubAgent loop emits turn-level events including program, result
  preview, prints, and tokens (`lib/ptc_runner/sub_agent/loop/metrics.ex`).

The actual gaps: (a) `TraceLog.Handler` subscribes only to
`[:ptc_runner, :sub_agent, ...]` events
(`lib/ptc_runner/trace_log/handler.ex`), so session/REPL activity never
reaches `TraceLog`; (b) core `PtcRunner.Session` carries no session identity
or turn counter (`lib/ptc_runner/session.ex`), so lisp execute events cannot
be correlated into a session record; (c) there is no shared turn-event
schema across the two drivers. (The MCP server's per-request trace files,
`trace_file.ex`, are an envelope debug log with hashed request IDs and FIFO
eviction — not a session-keyed record; the spend-spike report had to be
reconstructed from a client-side capture.)

**Change.**

- Define a **shared turn-event schema + builder** in core (substrate, D1):
  program source, result/status, memory diff (keys + bounded values),
  upstream/tool calls with metrics, duration, limits hit, and correlation
  IDs (session/run ID, turn number). Include **attached prelude names +
  `source_hash`es** per session — this single field makes A/B benchmarking
  and derivation provenance trivial.
- **Emit at driver turn boundaries**, not from the eval path:
  `Session.eval` emits session turn events; the SubAgent loop's existing
  turn telemetry migrates to (or is augmented with) the shared schema. The
  existing `[:ptc_runner, :lisp, :execute]` span remains the nested
  execution event, referenced by correlation ID. This is required because
  SubAgent turns include prompt assembly, LLM calls, parse failures, and
  budget stops that never reach `Lisp.run`.
- Give core `PtcRunner.Session` optional `session_id` (autogenerated,
  host-overridable) and a monotonic `turn` counter. Correlation identity is
  substrate-level: every host needs it, and host-by-host metadata threading
  would guarantee inconsistency. The struct stays a pure value.
- Reuse the event taxonomy style of `TraceLog.Event`; SubAgent-driven and
  session-driven turns must produce the same turn-event shape (D1).
- Add an **in-memory handler** (ETS ring buffer with byte budget) alongside
  the existing JSONL file handler. Hosts choose sinks; redaction and
  retention are host policy (D2).
- Extend `TraceLog.Analyzer` to query across sessions: list sessions, get
  turns, programs, envelopes, aggregate metrics (turns-to-first-upstream-
  call, duplicate-fetch count, payload ratios).
- `mix ptc.repl` enables the in-memory sink by default so "analyze my last
  session" works without filesystem setup.
- Leave `mcp_server` trace files untouched; they can become another handler
  later.

**Verify.** Integration test: run a multi-turn `PtcRunner.Session` and a
SubAgent run under `TraceLog.with_trace`; assert both produce turn events of
the same shape, queryable through the same Analyzer calls.

### P3 — Introspection prelude (no MCP first)

**Status: shipped** (`04eac9ab`). User docs:
`docs/guides/capability-prelude.md` (`tool:` requires) and
`docs/guides/subagent-observability.md` (the `log/` prelude).

**Prerequisite: generalize the `requires` resolver.** Prelude attach today
recognizes exactly one requirement shape — `"upstream:<server>/<tool>"` —
and fails attachment on any other id
(`lib/ptc_runner/lisp/prelude/attach.ex`). Host-bound turn-log capabilities
cannot be declared via `requires` until the grammar grows a second shape.
Scope it minimally: a `tool:<name>` requirement resolved against the run's
granted `tools:` map, fail-closed like the upstream shape. A full capability
grant registry / distinct binding surface is **not** built here — that waits
for the `RunEnv` work ([`capability-kernel-runtime.md`](capability-kernel-runtime.md))
to give it a committed reason to exist.

Two mechanics that must be specified up front, not discovered mid-PR:

- **Attach context (API change).** Attach validation today sees only the
  upstream runtime: `Lisp.run/2` threads `Keyword.get(opts, :runtime)` into
  `Prelude.Attach.attach/2` (`lib/ptc_runner/lisp.ex`,
  `lib/ptc_runner/lisp/prelude/attach.ex`). Validating `tool:<name>`
  requires threading the granted `tools:` map into attach as well — as an
  **attach context** (a map/struct holding `runtime`, `tools`, and room for
  future grant kinds), not a third positional argument.
- **Declaration semantics: inferred, extended by explicit.** The compiler
  already computes each export's tool refs and upstream requires
  **transitively** — own body plus the same-namespace private helpers it
  (transitively) calls, without absorbing sibling exports' requirements
  (`namespace_backing`/`transitive_backing`,
  `lib/ptc_runner/lisp/prelude/compiler.ex`). `tool:<name>` promotion uses
  exactly that set: the compiler **promotes the export's transitive
  `tool_refs` into `tool:` requires** — not only direct calls — except the
  synthetic `"call"` name used by `(tool/call ...)`, which is covered by
  precise `upstream:` requirements for literal upstream calls. Dynamic
  dispatch that inference cannot see must be declared explicitly.
- **Merge semantics change for `requires`: union, not override.** Today
  explicit metadata *replaces* inferred ids
  (`requires = explicit_requires || transitive_ids`,
  `lib/ptc_runner/lisp/prelude/compiler.ex`). Keeping that would let one
  explicit declaration silently drop inferred fail-closed requirements.
  The change: `requires` becomes the **union** of inferred and explicit ids
  (explicit can add, never remove) — applying to the existing
  `upstream:` shape as well, as a deliberate semantic change.
  `provider-ref` and `effect` keep their explicit-override semantics.
  Second deliberate breaking change alongside: existing tool-calling
  preludes that attach today without any tool check will fail closed when
  the host does not grant the tool — intended semantics (0.x, no shim).

Required tests: missing grant (attach fails closed with a recoverable
error), granted closure (export callable), unrecognized requirement shape
(attach fails closed), inferred+explicit union (inferred ids survive the
presence of explicit metadata), a helper-backed tool (an export reaching a
tool only through a same-namespace private helper still carries the
`tool:` requirement), and a dynamic dispatch case that attaches only with
the explicit declaration.

**Change.**

- Host-bound capability closures over the turn-log store (in-memory or
  file): `list sessions`, `turns`, `program`, `result`, `metrics`,
  `upstream-calls`. Read-only (D4). Bounded outputs (sample limits,
  truncation consistent with envelope policy). First implementation grants
  these as ordinary `tools:` closures — no new binding mechanism.
- **Keep the Elixir surface boring: data access only.** Analysis (dedup
  detection, pattern mining, cost aggregation) lives in PTC-Lisp programs —
  the analysis layer is the thing being dogfooded, and the spend-spike
  session showed the model writes good analysis code when given plain data
  access. Elixir-side analysis helpers only where tests need them.
- Package as a prelude: a protected namespace (e.g. `log/` — name open)
  whose exports wrap the granted closures with curated docstrings;
  `requires` declares the `tool:<name>` capability; attach fails closed
  without the grant (D3).
- Test as plain Elixir tool closures with `mix test` (StubPlanner /
  `eval!`-style harnesses) — no MCP transport involved.
- MCP exposure afterwards is a thin wrap and doubles as the proof of D2.
- Migration starts here: this is the proving consumer for
  preludes-as-sole-mechanism. Follow-up (separate PRs): migrate grep-style
  optional surface into a utility prelude, then delete the optional-tools
  mechanism.

**Verify.** A session (REPL-driven) can answer "what did my previous session
do, and where did it waste turns?" using only prelude exports.

### Gate between P3 and P4 — measure before automating (M1, M2)

P4 is the most interesting phase and the easiest place to overfit to the
spend-spike example. It does not start until two cheap, falsifiable
milestones pass, in order:

- **M1 — dogfood introspection.** A session, using only the P3 prelude
  exports, inspects previously recorded sessions and identifies duplicated
  work (re-fetches, repeated normalization, discovery overhead). This tests
  the turn log and introspection surface end-to-end and is itself the demo.
  Prerequisite: a handful of real sessions against a stable fixture
  upstream (the observatory sandbox), with retention configured to keep
  them — in-memory ring-buffer defaults matter here.
- **M2 — a human-written prelude pays for itself.** From M1's observations
  a *human* writes a prelude, and an A/B run on fresh task instances shows
  it reduces turns/tokens. The P5 leakage rules apply even though this is
  manual — a human can encode answers into a prelude as easily as an agent
  — so: fresh fixtures, varied planted answers. M2 is the manual pilot of
  the P5 methodology, and its prelude becomes the **gold standard** that
  P4's automation is later judged against ("did the agent find what the
  human found?").

Failure handling: if M1 fails, the introspection surface or turn-log data
is wrong — fix that, not the derivation. If M2 fails, preludes do not pay
for themselves on this workload and P4 has no value hypothesis — stop, or
pick a different workload. Either way P1–P3 remain useful on their own
(observability, benchmark instrumentation, replay/debugging hooks).

### P4 — Derivation loop (dogfood; gated on M1 + M2)

**Change.**

- A SubAgent granted the P3 introspection prelude reads N recorded sessions
  and proposes (a) prelude functions (recurring fetch/normalize/analyze
  patterns) and (b) loop config (response profile, docs-at-start, truncation
  sizes).
- **Host verifies** each candidate in a fresh scratch session against the
  live upstream before it becomes attachable; verification results feed back
  into the agent's next turn. The agent never gets live session control
  (D4).
- Output is a standard Prelude V1 artifact: compiler-validated, host-bound
  requires, `source_hash` recorded in the turn log of every session that
  attaches it.
- The derivation pipeline itself is **domain-blind** (repo prompt rules): it
  learns from the operator's own sessions; nothing domain-specific ships in
  ptc_runner prompts.
- Because the derivation agent's own run is turn-logged by the same
  substrate, the loop is self-applicable: the analyzer can be analyzed.

**Verify.** End-to-end: record sessions against a fixture upstream → derive
→ host-verify → attach → a fresh session solves a *new task instance* with
measurably fewer turns (formal measurement in P5).

### P5 — Benchmark: prove the prelude pays for itself

M2 (above) is the manual pilot of this methodology; full P5 rigor applies
when evaluating P4's automated derivation, with M2's human-written prelude
as the reference baseline.

A/B ablation on the existing `demo/` harness, leakage-aware:

- **Conditions:** A = bare sessions (today), B = sessions + derived prelude
  + P1/P2 config.
- **Metrics:** turns to completion, client tokens, upstream call count,
  duplicate fetches, payload reduction ratio, hard pass/fail oracle.
  Most are already emitted (`ptc_metrics`) or land in the P2 turn log.
- **Leakage rules** (non-negotiable, per repo testing rules): derive the
  prelude from *training* sessions on different task instances than the
  eval set; vary the planted answer (e.g. which trace is the anomaly) per
  run so a prelude cannot memorize answers; oracle is a planted fact in
  synthetic fixtures (answer = trace_id), non-shortcuttable; honest pass
  rates over repeated runs for any stochastic claim.
- **Questions, in order:** (1) does the derived prelude cut turns/tokens on
  unseen instances of the same task family? (2) only then: does it transfer
  to unseen task *types* against the same upstream, and does iterating
  prelude versions keep improving or plateau/overfit? Question 2 is where
  surveying existing continual-learning evals becomes worthwhile — the
  field is thin and mostly not agent-shaped; do not block on it.

## Explicitly deferred

- Live session control from agent code (`session/eval-in`, fork, drive) and
  the broader `chat/*` / `agent/*` Lisp control plane — see the
  control-plane doc and its dependency note on the closed-context guard.
- Lifting session ownership/TTL/registry into core (wait for a second host
  to duplicate it).
- Journal replacement (becomes a projection over the turn log when it
  happens; out of scope here).
- Rewriting `mcp_server` trace files as a turn-log handler.
- Cross-conversation session resume as a headline demo — worth doing after
  P2/P3 make sessions durable and inspectable, since "an investigation too
  big for one context window" is the demo no plain code-mode tool can
  replicate.

## Implementation notes appendix

These notes are not new design constraints; they are the source-level map for
P1-P3 so implementation does not rediscover settled boundaries.

### P1 implementation notes

- Reuse the existing `:repl_discovery` path in `lib/ptc_runner/lisp/eval.ex`.
  `doc` should be the only discovery operation that changes result semantics:
  append the rendered doc text to `EvalContext.prints` and return `nil`.
  `dir`, `apropos`, `meta`, `ns-publics`, `all-ns`, and `ns-name` stay
  structured-returning forms.
- Route through `PtcRunner.Lisp.Eval.Context.append_print/2` rather than a
  bespoke print accumulator. That preserves the documented `:max_print_length`
  behavior and keeps MCP output shaping responsible only for envelope-level
  budgets.
- Update tests that currently assert `(doc ...)` returns a string; keep the
  existing `dir`/`apropos` assertions as regression guards. Add MCP/session
  envelope coverage for the `>512 && <2000` doc case and for the configured
  `:max_print_length` override. Known return-value assertion sites include
  `test/repl_discovery_test.exs`,
  `test/mix/tasks/ptc_repl_prelude_test.exs`,
  `test/ptc_runner/upstream_runtime_test.exs`,
  `test/ptc_runner/lisp/prelude/full_path_integration_test.exs`, and
  `test/ptc_runner/lisp/prelude/discovery_test.exs`; the prelude discovery
  tests are useful regression coverage that prelude-exported docs use the same
  `:repl_discovery` path.
- Update prompt examples and `docs/function-reference.md` to show `(doc ...)`
  as a print-producing REPL form. Record the deliberate `dir` divergence in
  `docs/clojure-conformance-gaps.md`.

### P2 implementation notes

- Add a small core builder module (for example
  `PtcRunner.TraceLog.TurnEvent`) for the shared turn-event map. Do not build
  similar maps independently in `PtcRunner.Session` and SubAgent loop code.
- Reuse the existing `PtcRunner.TraceLog.Event`, `Collector`, `Handler`, and
  `Analyzer` conventions instead of introducing a parallel log format. When a
  turn event is already a complete map, prefer `TraceLog.write_to_active/1`
  for JSONL emission so sequence assignment and active-collector routing stay
  centralized.
- Treat the existing `[:ptc_runner, :lisp, :execute]` telemetry span as a
  nested execution record. Add correlation metadata rather than replacing or
  duplicating the span.
- Extend `PtcRunner.Session` as a pure value with `session_id` and `turn`.
  Failed eval attempts are mandatory turn-log records: parse errors, failed
  programs, and retry/setup churn are exactly the wasted work M1 needs to see.
  Keep `turn` as the committed-state counter (it advances only when
  `Session.eval` returns an updated session on success), and add/log a
  monotonic attempt counter for every eval attempt. Turn events should carry
  both committed `turn` and `attempt` (plus a committed/status flag) so failed
  attempts are visible without mutating the returned session.
- SubAgent has multiple turn paths. Use the existing
  `Metrics.emit_turn_stop_immediate/4` call sites in `Loop` and `TextMode` as
  anchors for shared turn-event emission so content mode, text/tool-call mode,
  parse failures, budget stops, and LLM errors remain observable.
- Implement the in-memory sink as a TraceLog sink/collector variant or closely
  adjacent module, not as a separate observability system. Pick a conservative
  default byte budget that can retain the handful of real observatory sandbox
  sessions needed for M1, while keeping retention host-configurable.
- Drive the first schema with tests before wiring every emitter: one
  `Session.eval` multi-turn trace and one SubAgent trace should assert the same
  top-level turn-event shape through `TraceLog.Analyzer`.

### P3 implementation notes

- Introduce an attach context for prelude validation, e.g. a map/struct with
  `runtime`, `tools`, and reserved space for later grant kinds. Thread it from
  `Lisp.run/2` after run options are assembled enough for granted tools to be
  visible to attach validation.
- Choose the decoupled `tool/call` rule explicitly: do **not** promote the
  synthetic `"call"` tool into a `tool:call` requirement when it is used as
  `(tool/call ...)`. Literal upstream calls are already covered precisely by
  inferred `upstream:<server>/<tool>` requirements, so `tool:call` would
  double-cover the same static fact and couple attach-context assembly to the
  `Upstream.Eval.eval_options/1` tool-merge order. Dynamic upstream dispatch
  remains the stated dynamic-dispatch case: inference cannot see the concrete
  upstream operation, so the prelude author must declare an explicit
  requirement.
- Change `PtcRunner.Lisp.Prelude.Compiler` requires construction from
  replacement semantics to union semantics. Inferred upstream ids and inferred
  `tool:` ids must survive explicit metadata. `provider-ref` and `effect`
  keep their current explicit-override behavior.
- Reuse `namespace_backing` / `transitive_backing` and the existing
  `tool_refs` field for `tool:` inference. Do not add a second AST walk with
  subtly different reachability rules.
- Extend `Prelude.Attach.validate_requires` to dispatch by requirement shape:
  existing `upstream:<server>/<tool>`, new `tool:<name>`, and fail-closed for
  unknown shapes. Missing tool grants should be recoverable
  `:prelude_attach_failed` errors, not runtime unknown-tool crashes.
- Keep introspection tools boring and data-oriented: list sessions, list
  turns, fetch program/result/envelope/metrics/upstream-call records with
  bounded outputs. Higher-level analysis belongs in PTC-Lisp programs and in
  tests that exercise those programs.
- Tests should cover missing grant, granted closure, unknown requirement
  shape, inferred+explicit union, helper-backed transitive tools, dynamic
  dispatch requiring explicit metadata, literal upstream `(tool/call ...)`
  preludes that carry only the precise `upstream:` requirements (not
  `tool:call`), and dynamic upstream dispatch that attaches only with explicit
  metadata.

## Open questions

- Prelude composition: collision policy and deterministic attach order when
  a session attaches multiple preludes (base + utility + derived).
- Turn-log retention and redaction policy boundaries between core defaults
  and host config; what the in-memory ring buffer's default byte budget
  should be.
- Exact turn-log event schema (field names, memory-diff value bounds) and
  whether `Tracer` per-run records should be unified with it or stay
  separate. Related: does the SubAgent loop's existing turn telemetry
  (`loop/metrics.ex`) migrate to the shared schema outright, or emit both
  shapes during a transition?
- The scratch-session verification API the host uses in P4 (shape of
  "candidate in, evidence out").
- Which loop-config knobs are worth deriving beyond response profile and
  docs-at-start (e.g. per-upstream sample limits, feedback verbosity).
- Namespace name for the introspection prelude (`log/`, `session/`,
  `runs/`) and how its exports merge into `apropos`/`dir` discovery.
