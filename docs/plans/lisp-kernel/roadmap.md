# Lisp Kernel — Roadmap

**Status:** active, branch `exp/lisp-kernel`. Working checklist — strike items
as they land, record findings in [`architecture.md`](architecture.md) (facts,
decisions) and [`spikes.md`](spikes.md) (evidence). Keep this doc honest:
a phase is done when its gate passes, not when its code exists.

## Method

Interleave three activities, cheapest-first:

- **Research (R#)** — read the existing code and record file:line facts.
  Never build on an assumed contract; every R item ends with a fact appended
  to architecture.md §Verified substrate facts (or a correction to the design).
- **Spikes (S#)** — throwaway code answering a design-gating question, each
  pre-registered in spikes.md with a pass/fail criterion *before* writing it.
  Spike code lives in `spikes/` (git-ignored or clearly marked), never in
  `lib/`.
- **Milestones (M#)** — real code, gated.

### Standing gates (every milestone)

- `mix precommit` clean.
- Independent `codex review` until clean (expect ~5–6 rounds; stop on first
  clean round).
- **Domain-blind audit:** `agent.*` prelude sources contain no demo-domain
  vocabulary, test-data hints, or expected-answer patterns (CLAUDE.md rule).
  The audit includes rendered prompts/message payloads and model-visible config,
  not just prelude source.
- Testing follows §Testing & Evaluation Strategy: Tier 0 green on every
  commit; live evaluation only through the blessed Tier 1–3 paths defined
  there — never a new ad-hoc harness.
- Honest reporting: pass rates over N runs for stochastic claims, no
  mock-data-presented-as-benchmark.

## Testing & Evaluation Strategy

One blessed path per tier. Future work (human or agent) extends these paths;
inventing a parallel harness is a review-blocking finding. Tier 1 follows the
existing e2e convention in `PtcRunner.TestSupport.LLMSupport`
(`PTC_TEST_MODEL` env var, resolved via `LLM.Registry`,
`ensure_api_key!/1`). Tier 2 is a `lib/` mix task, so R14 promotes the same
env/model/key-check behavior into a library-visible seam before any live
evaluation claim. One model seam, not two.

**Canonical model for this experiment** (owner decision, 2026-07-07):
`openrouter:deepseek/deepseek-v4-flash` — registry alias `deepseek`
(default_registry.ex:89-93) — chosen as capable and cheap. This worktree's
`.env` pins `PTC_TEST_MODEL` accordingly (the main checkout's `.env` still
pins `gemini-3.1-flash-lite` for the pre-existing e2e suites; changing that
repo-wide default is a separate decision). Two consequences to keep honest:

- numbers from this experiment are **not comparable** to the flash-lite
  Treatment-A / demo baselines; every comparison that matters (kernel vs
  incumbent, bundle-A vs bundle-B) runs both cells on deepseek, same-model;
- deepseek-v4-flash has never run this repo's harnesses — R12's shakedown
  must precede any conclusion-bearing run.

### Tier 0 — Deterministic ExUnit (every commit)

`test/ptc_runner/kernel/*_test.exs`, inline mock `llm:` lambdas only — no API
key, no network, no OTP app config (testability invariant from
capability-kernel-runtime.md). Must cover: V1 native tool-call action
normalization; `program`-only schema; rejection of free-text code and mixed
content/tool-call responses unless a later decision explicitly admits them;
private-capability authorization (a caller outside `agent.core`'s declaring
exports fails closed); inner eval isolation (`prelude: nil`, `runtime: nil`,
`discovery_exec: nil`); untrusted-data envelopes; redacted trace/report
projection with no raw prompts/messages by default; golden rendered M1 prompt
contains `run_ptc_lisp` and does not contain `lisp_eval`, fenced-code
instructions, direct-final-answer instructions, or demo-domain vocabulary;
extension-contract coverage for one injected private capability; `project_step/1`
shape; the D1 memory strategy; outer deadline kill, heap kill, and LLM-budget
exhaustion; bundle provenance surfaced in results; and **turn-event shape
parity** — extend
`test/ptc_runner/trace_log/turn_log_integration_test.exs` (branch precedent:
Session and SubAgent drivers must emit the same top-level TurnEvent shape;
the kernel becomes the third driver under the same assertion).

### Tier 1 — Canonical live smoke (one file, one command)

`test/ptc_runner/kernel/e2e_test.exs` — `use ExUnit.Case, async: false`,
`@moduletag :e2e` (excluded by default, test_helper.exs:17), `setup_all`
calls `LLMSupport.ensure_api_key!/1` and prints the resolved model (existing
e2e-module conventions). The repo convention on a missing key is **raise
under `--include e2e`**, not skip (llm_support.ex:94-116) — we follow it; the
default tag exclusion already keeps ordinary runs green.

    mix test test/ptc_runner/kernel/e2e_test.exs --include e2e

Content stays tiny: eval-case #1 (500 products) plus one multi-turn case.
Smoke is not evaluation — no pass-rate claims come from this tier.

### Tier 2 — Evaluation harness (pass rates, repeatable)

Stochastic evaluation is not assertion; it lives outside ExUnit as a mix task
in the existing `ptc.*` namespace (no LLM-eval task exists in `lib/` today;
`bench.check` is deterministic-only):

    mix ptc.kernel_eval --suite smoke --model deepseek \
      --runs 5 --variant kernel --report reports/kernel_eval.md

`--model` overrides `PTC_TEST_MODEL` for that invocation; both inputs resolve
through the R14 library-visible seam backed by
`PtcRunner.LLM.Registry.resolve/1`, so any registry alias (e.g. `deepseek`) is
valid. The flag is a per-run override of the env var, never a second
resolution path.

- **Cases are data, not test code** — lifted from demo per R10: the four
  dependency-free files recon verified as entanglement-free
  (`TestCase` case maps, the oracle core in `TestRunner.Base`, `SampleData`,
  `SearchTool`). Reusing the demo domain here is sanctioned (the experiment
  explicitly targets demo problems); it must still never leak into `agent.*`
  prelude sources.
- **Generate the dataset once per run** and share it across variants/cells.
  Demo's clojure-validation path regenerates data mid-comparison and validates
  against different data (lisp_test_runner.ex:723-765) — a known wart we must
  not copy.
- `--variant kernel | incumbent` — incumbent drives today's `SubAgent.run/2`
  over the same cases, oracles, context, and tools. This is the only parity
  mechanism (see rule below).
- Every ask runs inside `TraceLog.with_trace/2` writing JSONL turn logs to a
  **persistent** reports directory — the Treatment-A harness lost its traces
  to ExUnit's tmp_dir; don't repeat that. Report output is markdown plus a
  machine-readable JSON twin (demo `Report` convention), recording: model id,
  repo commit, bundle component `source_hash`es, per-case outcomes with
  rendered oracle failures, redacted prompt/action hashes, trace paths, and
  aggregate pass rates. Reports must surface trace drop/write-error counts;
  silent trace shedding is not acceptable for benchmark metrics.
- Debugging uses the same code path, not ad-hoc scripts:

      mix ptc.kernel_eval --suite smoke --case 1 --runs 1 \
        --variant kernel --debug --trace-dir reports/kernel_eval/debug

  Debug artifacts may include unsafe raw prompt/response excerpts only under an
  explicit unsafe flag and are never used for benchmark claims.
- Replay is offline by default: every Tier 2 report records sanitized action
  envelopes and eval projections sufficient to replay a failed case without an
  API key. Unsafe raw prompts/responses are optional debug artifacts, not the
  replay substrate.

### Tier 3 — A/B benchmark (M3 only)

Consumes Tier 2 unchanged (same suite, trace schema, report shape). Requires
**preregistration before any run**, as an experiment-notes doc following the
local template added before M2 ends. Required fields: date + scope with
explicit non-goals; frozen suite and dataset seed/hash; a cells table with
**frozen bundle `source_hash`es**; primary endpoint and primary cell pair;
minimum detectable effect, alpha, power, and computed N; blocked randomized
run order by `{case_id, replicate}`; retry/exclusion/stopping rules; metrics
computed from turn logs via `TraceLog.Analyzer` (turns, tool calls, duplicate
reads by `args_hash`, tokens, correctness); correction policy for secondary
metrics/cells; the exact command; and an honest outcome section — including
"did not run" when true. Reports stratify outcomes by task family, tool shape,
oracle strength, turn-count band, and data-visibility mode; aggregate pass rate
alone is never the conclusion.

### Incumbent parity rule

- **M1:** kernel is smoke-tested only (Tiers 0–1). No comparisons.
- **M2:** Tier 2 runs both `--variant kernel` and `--variant incumbent` on the
  case subset. Results are recorded as *informal parity observations* — used
  to catch capability gaps, never quoted as claims.
- **M3:** preregistered comparisons only. The primary cell pair is
  kernel-bundle-A vs kernel-bundle-B (the policy thesis); kernel vs incumbent
  may run as an additional preregistered cell pair on the same tasks — never
  ad hoc.

### Oracle contract (adopted from demo, one deliberate divergence)

Two-part oracle per case: an `:expect` type check plus a `:constraint` tuple —
`{:eq, v}`, `{:gt, n}`, `{:gte, n}`, `{:lt, n}`, `{:between, min, max}`,
`{:length, n}`, `{:gt_length, n}`, `{:starts_with, s}`, `{:one_of, list}`,
`{:has_keys, keys}` (string-key normalization on both sides). There is
deliberately no float `{:eq, _}` — SampleData is unseeded-random, so float
expectations are ranges (`{:between, ...}`), the reason the whole format is
constraint-based. Divergence: demo's checkers **fail open** on an unknown
`:expect` atom or constraint tuple (base.ex:41,137); the kernel harness fails
closed with a stable error, per repo policy on validation and limits.

## Phase 0 — Research backlog

Answer by reading code; no new code. Each item names the consumer that needs
the answer.

- [x] **R1a — LLM callback response shape** (answered by review round 1,
  2026-07-07): `LLM.callback/2` returns `{:ok, %{content:, tokens:}}`
  (llm.ex:78,153); test lambdas may return bare `{:ok, text}`; kernel
  normalizes both — recorded in architecture.md fact 5.
- [ ] **R1b — LLM callback failure surface**: error return shapes, retryable vs
  terminal mapping, timeout handling, whether retry sleep consumes the mission
  deadline, whether retries are host-owned or prelude-owned, and whether
  streaming is explicitly unsupported in kernel V1. (Feeds kernel capability #1
  error path.)
- [ ] **R2 — Step → map projection**: full `Step.fail` structure (`t:fail/0`),
  how eval errors render as strings today (`Lisp.format_error/1`), what the
  loop prelude needs to produce good feedback. (Feeds `project_step/1`, D5.)
- [x] **R3 — Demo problem extraction** (answered by recon, 2026-07-07): all 30
  cases are pure data maps in `PtcDemo.TestRunner.TestCase`
  (`%{query:, expect:, constraint:, description:}` + optional
  `max_turns:/signature:/plan:`; case #1 is the 500-products one,
  test_case.ex:36-41); oracle core is `TestRunner.Base.check_type/2` +
  `check_constraint/2` (base.ex:36-137); `SampleData` is a dependency-free
  generator (5 datasets, ~450KB, unseeded random — counts deterministic,
  values not); `SearchTool` depends only on SampleData. These four files lift
  cleanly; everything else (Agent GenServer, LispTestRunner, Report/CLIBase)
  is demo-entangled. demo/README.md:531-606 is the difficulty taxonomy.
- [ ] **R4 — Prompt/token substrate**: which `priv/prompts/` templates render the
  PTC-Lisp language spec + native `run_ptc_lisp` tool-use instructions, how to
  render them host-side (`PromptRegistry` / `SystemPrompt`), byte sizes,
  estimated tokens, live provider-reported prompt tokens for a dry M1 request,
  max-context failure shape, and what the kernel passes as `data/language-spec`.
  (Feeds `agent.prompt`, D11.)
- [x] **R5 — Bundle + deps API**: exact call shape for layered preludes
  without a `PreludeStore` (raw `Bundle.compile/1` is dep-blind by design —
  confirm whether `agent.core` calling `agent.feedback/*` requires
  `namespace_deps:` via `compile_precompiled/2` or a store-resolved attach).
  Answered 2026-07-08 for M2 2a: compile the dependency namespace first,
  compile the dependent namespace with `deps: [feedback]` and
  `namespace_deps: %{"agent.core" => ["agent.feedback"]}`, then assemble the
  components with `Bundle.compile_precompiled/2` and the same
  `namespace_deps:` map. Evidence:
  `mix test test/ptc_runner/kernel/prelude_split_test.exs`.
- [x] **R6 — Tool-arg/result normalization path** (answered by review round 1,
  2026-07-07): keys stringified, keyword values collapsed to strings
  (eval.ex ~1166–1270); closure tuples preserved (lisp.ex:1209) — recorded in
  architecture.md fact 8. S2 remains to measure the practical consequence.
- [ ] **R7 — TraceLog/TraceContext contract**: minimal way for the kernel to emit
  `TurnEvent`s so existing `log/` introspection and `args_hash` duplicate-call
  metrics work on kernel runs; nested `TraceLog.with_trace`, outer loop trace
  vs inner model eval trace, `record_turn_event` vs `write_to_active`, child
  trace propagation, one-shot `TraceContext` cleanup, and nil-token handling.
  (Feeds D4 and M3 measurement.)
- [ ] **R8 — SubAgent loop autopsy** (already largely done in the
  investigation session): per-turn control flow of `loop.ex` driver_loop,
  `turn_feedback.ex`, retry/must-return phases — as the checklist of behaviors
  `agent.core`/`agent.feedback` must (or deliberately won't) reproduce.
- [ ] **R10 — Case-format + oracle port**: lift the four R3 files into the
  kernel eval harness home (decision D8): finalize the canonical case shape
  (`id, query/task, context_ref, tools, expect, constraint, max_turns, tags`),
  close demo's fail-open oracle holes (fail closed, stable error), decide
  whether to seed `SampleData`'s randomness for reproducible A/B cells (demo
  is deliberately unseeded; preregistered cells may want a recorded seed),
  define model-visible case projection (never `expect`/`constraint`/`plan`),
  and define how oracle failures render in reports.
- [ ] **R11 — Report/replay artifact schema**: finalize the Tier-2 JSON twin's
  required fields (model id, provider/backend metadata when available, repo
  commit, bundle manifest, component `source_hash`es, run command, seed/dataset
  hash, trace path per case, redacted prompt/action hashes, per-case outcomes,
  aggregate pass rates), the persistent trace/report directory layout, unsafe
  debug artifacts policy, and how `--replay-report CASE_ID` reproduces a
  failure.
- [ ] **R12 — deepseek shakedown** (live, needs key; do before any
  conclusion-bearing run): establish that `deepseek`
  (openrouter:deepseek/deepseek-v4-flash) can do PTC-Lisp at all by running
  the *incumbent* SubAgent on a stratified demo subset: case #1, case #3, one
  filter-only case, one search/refinement case, and one multi-hop/cross-dataset
  case. If the incumbent fails this shakedown on deepseek, kernel failures on
  deepseek attribute to the model/config before they attribute to the
  architecture — without this baseline we cannot tell those apart.
- [ ] **R13 — Copy-volume/setup-pressure inputs**: define S5's representative
  payload sizes and measurements: large mission context, growing memory map,
  large return value, large prints, large prompt/spec binaries, sub-binary
  slices, projected-step caps, outer/inner `setup_max_heap` sizing, setup
  failure shape, `baseline_bytes`, and term-size estimates. This turns BEAM
  process-copy pressure into a measured budget rather than an anecdote. (Feeds
  S5, D1, D5, Tier 2 thresholds.)
- [x] **R14 — Kernel eval model/config seam**: Tier 2 is a `lib/` mix task, so
  it cannot depend on `test/support/LLMSupport`. Move/reuse env loading, model
  alias resolution, and API-key checks from a lib-visible module; tests call
  that seam, not the reverse. The autonomous M2 mini-eval spike must implement
  this seam before enabling live `mix ptc.kernel_eval` mode; no second
  live-eval env/key path. Answered 2026-07-08 by `PtcRunner.Kernel.Eval`:
  `resolve_model/1` delegates to `PtcRunner.LLM.Registry`, live mode loads
  `.env` through `PtcRunner.Dotenv`, checks key requirements through
  `ReqLLMAdapter.requires_api_key?/1` plus resolved-provider key lookup
  (including Bedrock bearer-token vs AWS key-pair validation), and builds
  `PtcRunner.LLM.callback/2` directly.
- [ ] **R15 — Security/redaction and trust policy**: define private
  kernel-tool ledger projection, prompt/action redaction, unsafe debug artifact
  policy, prelude trust/provenance policy, and inner eval denial defaults
  (`prelude: nil`, `runtime: nil`, `discovery_exec: nil`). (Feeds D5, D10.)
- [x] **R16a — Native action/provider mechanics, M1 slice** (answered by
  vertical slice, 2026-07-07): `PtcRunner.Kernel.Action.normalize/2`
  accepts exactly one `run_ptc_lisp` call and rejects free text, mixed text
  plus tool call, missing/multiple/wrong calls, invalid/non-map args, missing/
  empty/non-string/oversized `program`, and extra args such as `commentary`.
  ReqLLM/OpenRouter requires `temperature: 0.0` and map tool choice
  `%{type: "tool", name: "run_ptc_lisp"}`. The adapter now forwards
  `:tool_choice`; the blessed DeepSeek smoke passed and preserved token usage.
- [ ] **R16b — Native action/provider mechanics, full provider audit**:
  normalize content/tool-call
  response shapes into the V1 action envelope; document DeepSeek/OpenRouter
  reasoning fields, provider routing/fallback metadata, generation controls
  (`temperature`, `top_p`, `seed`, `max_tokens`, `reasoning.effort`,
  `provider.order`, `allow_fallbacks`), token/cost fields, and unsupported
  controls. (Feeds D9, D11.)
- [x] **R16c — Retry transport shape, M1 slice** (answered by fix commits,
  2026-07-08): prelude-built retry messages must be normalized to the
  atom-keyed `ReqLLMAdapter.build_messages/1` contract; assistant retry
  messages carry `content: nil` plus structured tool calls; eval feedback is
  JSON with `type`, `instruction`, and `untrusted_eval_result`; the system
  prompt travels once through the request `:system` channel; LLM
  `{:error, reason}` becomes `transport_error` / `llm_transport_error`, not
  model protocol feedback. Covered by mock tests and a two-turn live
  DeepSeek/OpenRouter smoke.
- [ ] **R17 — Experiment rigor plan**: choose primary endpoint/cell pair,
  baseline pass-rate estimate, MDE, alpha, power, N via
  `PtcRunner.Metrics.Statistics`, randomization/counterbalancing, multiple
  comparison policy, stopping/rerun rules, and local prereg template. If N=20
  remains, label it descriptive/shakedown only.
- [ ] **R18 — Oracle audit and holdout policy**: strengthen broad demo
  constraints before M3; classify weak oracles as exploratory; add a small
  holdout suite not used during spikes/M1/M2 debugging.
- [ ] **R19 — Prelude maintainer loop and bundle manifest UX**: define commands
  to compile the kernel prelude bundle, inspect docs/meta/source, print a
  manifest/lock view (component id, namespace, origin, hash, deps, compile API),
  run a scripted mission, and replay a failing trace.
- [ ] **R20 — Kernel error envelope**: stable categories and rendering for
  prelude compile/runtime errors, private capability denial, LLM failure,
  protocol error, inner eval parse/eval/fail, timeout, heap/setup heap, and
  budget exhaustion; define prelude-visible value, host result, trace fields,
  and report rendering for each.
- [ ] **R21 — Runtime edge policy**: inner `link: true` cleanup, shared
  atomic/server-owned LLM/eval counters under `pmap`, outer/inner
  `pmap_*`/worker heap settings, host-held memory holder lifecycle, and
  journal/tool-cache threading or explicit exclusion.
- [ ] **R22 — Soak/lifecycle audit**: inventory every long-lived owner process,
  process-dictionary key, async queue, ref-counted binary holder, closure
  capture, cache, trace collector, HTTP pool interaction, and atomics slot
  involved in one kernel run. Define before/after measurements for process
  count, memory, reductions, mailbox length, trace drops, and pool health.
  (Feeds D16, S11.)
- [ ] **R23 — Model-facing action UX**: decide whether the V1 tool schema stays
  `program`-only, whether `commentary` is worth adding as metadata, whether
  terminal free-text final answers exist at all, and how protocol errors spend
  turn/retry budgets. Include golden prompts and exact retry messages from the
  model's point of view. (Feeds D14, S6.)
- [ ] **R24 — Future feature extension matrix**: classify sessions, compaction,
  journal/plans/progress, MCP/catalog discovery, compiled agents, budget
  introspection, streaming, structured outputs, multi-agent/parallelism, and
  policy plugins as `prelude-only`, `private capability`, `host state service`,
  or `kernel mechanism`. Every item gets either a no-Elixir-change path or an
  accepted kernel edit. (Feeds D15, M4.)
- [ ] **R25 — Cross-domain and retrieval-negative controls**: define a holdout
  suite not derived from demo: numeric tables outside commerce, graph/topology,
  calendar/time intervals, text classification, nested JSON transforms, and
  non-search tool orchestration. Add retrieval variants with exact-token
  search, ranked noisy search, cursor-only pagination, empty-result ambiguity,
  and transient tool errors. (Feeds M3 genericity claims.)
- [ ] **R26 — Release/API/package shape**: decide whether `PtcRunner.Kernel`,
  `mix ptc.kernel_eval`, eval case modules, and `priv/preludes` are
  experiment-internal, public experimental, or stable surface. Check package
  file lists and release smoke so preludes are either intentionally shipped or
  intentionally hidden. (Feeds D18.)
- [ ] **R27 — Replay/redaction/schema promotion**: define kernel TurnEvent
  schema extension (`driver: "kernel"`), analyzer compatibility, offline replay
  cassettes, kernel trace redaction defaults, dropped-event counters, and
  source-exposure policy for `agent.*` preludes. (Feeds D4, D17, Tier 2.)
- [ ] **R9 — Teardown inventory** (see §Teardown below): classify every
  module/test/doc/config/prompt under `lib/ptc_runner/sub_agent/`, related
  guides, prompt templates, e2e fixtures, and benchmark setup into **keep**
  (kernel substrate), **absorb** (policy that becomes prelude code), **delete
  now** (obsolete/non-baseline surface whose removal speeds or clarifies the
  branch), or **delete at promotion**. Produce `teardown.md` with the table,
  active callers, replacement path, and quality gate for each deletion batch.
  Cheap to do alongside R8 and forces the mechanism/policy classification to be
  exhaustive rather than anecdotal.

## M0 — Spikes

Pre-registered in [`spikes.md`](spikes.md). Order matters: S1 → S2 gate the
design; S5 gates copy-volume/memory strategy; S3/R16 gate the live path; S4
de-risks the prelude before the kernel exists; S6/S7/S8 harden the action and
feedback protocol before M1/M2 claims; S10-S14 are extensibility and soak
spikes that must run before promotion and, where noted, before M2/M3 claims.
For an autonomous vertical-slice run that deliberately combines several M0
questions, use [`autonomous-spike.md`](autonomous-spike.md) as the goal brief.

- [ ] **S1 — Re-entrancy**: nested `Lisp.run` from inside a sandboxed tool
  closure.
- [ ] **S2 — Memory round-trip**: model-defined closures surviving
  loop-threaded memory across the tool boundary. → Decides D1.
- [ ] **S5 — Copy-volume/setup pressure**: nested kernel-shaped runs with large
  grants, growing memory, large returns, and large prints; measure setup cost,
  baseline bytes, projection size, and failure modes. → Decides D1/D5 caps.
- [ ] **S3 — Blocking LLM call in the sandbox**: real deepseek call from a
  tool closure under relaxed outer limits; timeout accounting; kill-mid-HTTP
  behavior.
- [x] **S4 — Loop expressiveness**: write a minimal `run-mission` loop as a
  plain prelude against a *scripted stub* native-action llm tool (no kernel, no
  network, plain `Lisp.run`). Proves the language carries the V1 action
  protocol and turn loop comfortably; its source seeds `agent.core`.
- [x] **S6 — Native action protocol hardening**: scripted tool-call, final,
  and protocol-error responses; reject free-text code, missing/multiple/wrong
  tool calls, invalid arguments, and disallowed finals.
- [ ] **S7 — Capability confused-deputy + untrusted envelope**: attempts to
  alter roles/system content, force extra LLM/eval calls, pass arbitrary `src`,
  forge telemetry, or inject instructions through tool output/prints/errors are
  wrapped, rejected, or rendered as untrusted data.
- [ ] **S8 — Prelude maintainer/replay loop**: compile bundle, inspect
  source/meta/manifest, run a scripted mission, and replay one failing report
  through the blessed debug path.
- [ ] **S10 — Pluggable private capability contract**: inject one private
  capability outside the hardcoded `llm-complete`/`eval-program`/`log` trio;
  a prelude export can call it, model/user code cannot, and the kernel traces
  it without source edits.
- [ ] **S11 — Kernel-shaped soak**: 1,000 mock turns plus a smaller live-short
  HTTP matrix; record process/memory/reduction deltas, collector mailbox/drop
  counts, stale TraceContext state, pmap worker cleanup, atomics slots, and
  Req/Finch pool health.
- [ ] **S12 — Host-held state handle prototype**: owner process with monitor
  cleanup, stale-token errors, run-end invalidation, per-run byte caps, bounded
  projections, and concurrent access behavior under `pmap`.
- [ ] **S13 — Cross-domain holdout + retrieval negative controls**: run the
  blessed harness on non-demo cases and hostile retrieval semantics; report by
  task/tool/oracle family instead of aggregate only.
- [ ] **S14 — Release/replay artifact smoke**: package/release visibility for
  preludes plus offline replay from a sanitized Tier 2 report, no API key.
- [ ] **S19 — Bundle swap provenance + feedback-only A/B preregistration**:
  prove `prelude.metadata.components` plus source hashes attribute a run to a
  specific prelude variant before M3 compares feedback policies. Register the
  A/B shape before running it: feedback prelude only varies; prompt prelude,
  cases, `max_turns`, model, and runner stay fixed; N repeats per case per
  variant report pass counts as directional evidence, not statistics.

**Exit gate:** D1 decided; D5 has initial projection caps; D9 action protocol
and D10 error envelope have Tier 0 coverage; D14 minimal action surface is
settled for M1; no spike revealed a mechanism gap that requires new evaluator
machinery. If one did — stop, update
architecture.md, rethink.

## M1 — Kernel + `agent.core`, single mission

Smallest real slice: one bundled prelude (core only, prompt/feedback inlined),
one mission, mock-llm tests, one live smoke.

- [x] `PtcRunner.Kernel.run/2` per architecture.md §Capability Model
  (capabilities, backstops, bundle compile, outer run).
- [x] `agent.core` prelude v0: single-turn mission — render prompt, one
  `llm-complete`, accept exactly one `run_ptc_lisp` action, one `eval-program`,
  return/fail.
- [ ] Tier 0 suite: scripted llm lambdas covering happy path, unparseable
  response/protocol error, program `fail`, LLM budget exhaustion, outer deadline
  kill, private-capability authorization, inner eval isolation, redacted
  tracing, untrusted envelope, golden prompt hygiene, extension-contract smoke,
  turn-event shape parity. Partial M1 spike coverage landed for happy path,
  protocol retry, action hardening, transport error, caller-supplied system
  prompt channel, adapter-boundary retry message structification, JSON
  untrusted eval feedback, program `fail`, private capability denial, bounded
  projection, and prompt hygiene; budget/deadline/trace parity remain.
- [x] Tier 1 smoke file with a tiny no-tool arithmetic mission live on the
  blessed command, plus a two-turn live retry smoke that forces the
  assistant/tool-message transport path. The original eval-case #1
  product-count oracle remains for the later Tier 2 harness.
- [ ] First `mix ptc.kernel_eval --suite smoke --runs 5 --variant kernel`
  run recorded (Tier 2, kernel variant only — the task can exist in minimal
  form this early).
- [ ] Gate: standing gates + Tier 0 green + Tier 1 passes + Tier-2 smoke
  records ≥ 4/5 on case #1 + S11 mock soak shows no unbounded process/memory/
  trace accumulation.

## M2 — Multi-turn + prelude split

The modular-config claim becomes real here.
For an autonomous next-step spike that combines the prelude split with a tiny
repeatable eval path, use
[`autonomous-m2-prelude-eval-spike.md`](autonomous-m2-prelude-eval-spike.md)
as the goal brief.

- [ ] Multi-turn loop in `agent.core`: feedback message construction,
  max-turns wind-down, memory threading (per D1).
  2026-07-08 M3 partial: memory threading now uses per-run host-held native
  state in `Kernel.run/2`; deterministic tests prove `def` and `defn` survive
  across retry turns, bounded `memory_summary` crosses back to the loop, and
  memory cap breach fails closed while preserving prior state. Feedback wording,
  mini-suite extension, and live payoff probe remain open.
- [ ] Split `agent.prompt` and `agent.feedback` into their own dotted
  PTC-Lisp namespaces/components; wire deps per R5. Policy constants as
  exports.
  2026-07-08 M2 2a proof is complete for `agent.core -> agent.feedback`;
  2b full graph is complete for `agent.core -> [agent.prompt, agent.feedback]`
  in `priv/preludes/agent/*.lisp`, with focused tests proving empty
  prompt/feedback `tool_refs`, single-channel system prompt forwarding, and a
  feedback-only source override. Policy constants as exports remain open.
- [ ] Truncation policy implemented **in** `agent.feedback` (caps + hint
  wording).
- [ ] Suite extended: eval-cases 3/5 (filter + aggregation) and a multi-turn
  cross-dataset case, via Tier 2. M2 mini runner now has 5 tiny cases:
  arithmetic, context filter/count, context aggregation, one granted domain
  tool, and forced eval retry. Mock mode passes 5/5; live DeepSeek full-suite
  run on 2026-07-08 passed 4/5, with aggregation still unstable.
- [ ] Kernel emits turn events (per D4) so runs are measurable with existing
  tooling.
- [ ] Host-held state, trace, tool-cache, and pmap behavior follow R21/R22
  decisions; S11/S12 pass before widening live runs.
- [ ] Parity per rule: Tier 2 run with `--variant kernel` AND
  `--variant incumbent` on the same suite; observations recorded informally.
- [ ] Gate: standing gates + Tier-2 pass rates recorded (pre-register
  thresholds before running; suggest ≥ 3/5 each as a smoke bar, not a claim).

## M3 — The payoff experiment: policy A/B with zero Elixir diff

Runs as Tier 3 of the testing strategy: pre-register before running
(llm-benchmark methodology: cells, sample size, metrics, thresholds — the
preregistration doc is the gate, and it freezes the bundle `source_hash`es).

- [ ] Two `agent.feedback` components differing **only** in truncation/feedback
  policy (e.g. bare truncation vs truncation-hints wording from the
  Treatment-A work), hashes frozen in the prereg doc.
- [ ] Same tasks, same model, same seeded/persisted dataset, blocked randomized
  run order; N comes from R17. N ≥ 20 is allowed only for a descriptive
  shakedown, not a conclusion-bearing A/B, unless the power plan justifies it.
- [ ] Cross-domain holdout and retrieval-negative results recorded separately;
  genericity claims require those strata, not only demo parity.
- [ ] Metrics off turn logs: turns, tool calls, repeated reads (`args_hash`),
  correctness, tokens.
- [ ] Deliverable: experiment notes doc + verdict on the thesis ("policy
  iteration as prelude diff") with honest framing.

**Overall exit:** after M3, write a verdict section in architecture.md —
promote (execute §Teardown as M4), iterate, or archive with findings.

## Teardown (the clean start) — position

Deletion is expected in a 0.x repo when it reduces obsolete surface area. The
constraint is not compatibility; it is that the repo stays coherent and green
at every step. Since `main` remains available as historical reference, the
branch does not keep old behavior merely for recoverability.

The measured incumbent is different. During the experiment, keep enough of
today's SubAgent path to run `--variant incumbent` on the same task suite,
because M2/M3 need that baseline inside the same worktree. A mass deletion of
`sub_agent/` before the verdict would either break `mix precommit` or push
baseline measurement into another checkout, making traces, parity, and review
less reliable.

Deletion that is allowed before the verdict:

- docs/config/prompts/tests that assert behavior explicitly out of scope for
  the kernel branch, once no active caller depends on them;
- duplicate or stale benchmark harness setup replaced by the blessed Tier 2
  path;
- obsolete experimental scaffolding around the kernel after replacement tests
  exist;
- slow lint/test surface whose only purpose is old behavior not used by the
  incumbent comparison.

Deletion that waits for a "promote" verdict:

- the incumbent loop and enough `sub_agent/` surface to run baseline parity;
- shared substrate the kernel reuses (`lisp/`, `sandbox.ex`, `llm.ex`,
  `trace_log/`, `prelude_store.ex`, tool/capability machinery);
- docs needed to interpret incumbent-vs-kernel measurements.

What we do *now* is R9: the inventory that makes both kinds of deletion
mechanical and reviewed instead of an archaeology project.
Working guess at the classification (R9 verifies and completes it):

| Bucket | Examples |
| --- | --- |
| Keep (kernel substrate) | `lisp/` (all), `sandbox.ex`, `llm.ex` + adapters, `step.ex`, `turn.ex`, `schema.ex`, `trace_log/`, `prelude_store.ex` |
| Absorb into preludes | prompt assembly, `turn_feedback.ex`, truncation rendering, retry phrasing, progress vocabulary |
| Delete now if replaced and unreferenced | stale experiment notes, obsolete prompt variants, duplicate harness scripts, old tests for behavior explicitly outside kernel V1 |
| Delete at promotion | `sub_agent/loop*.ex`, `text_mode.ex`, `ptc_tool_call.ex`, compiled agents, compaction, exposure, related tests/guides |
| Undecided | `session.ex`, `upstream/` bridge, `evidence.ex`, MCP server implications |

**M4 — Teardown (only on a "promote" verdict):** execute the inventory
top-down as its own Conventional-Commit series on a fresh branch. Delete one
ownership boundary at a time: define the replacement API/config first, move the
closest callers, verify with `rg`, remove obsolete code+tests+docs/config
together, then run targeted tests and `mix precommit`. Delete old tests that
assert old behavior; move or adapt tests that assert still-valid contracts.

## Working agreements

- All work in the `~/projects/ptc_runner-lisp-kernel` worktree on
  `exp/lisp-kernel`; the main checkout is shared with concurrent automations.
- Conventional Commit subjects; commit at phase boundaries, not mid-spike.
- Spike results are appended to spikes.md in the same commit as the spike.
- When code and this doc disagree, fix both in one commit.
