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
- Testing follows §Testing & Evaluation Strategy: Tier 0 green on every
  commit; live evaluation only through the blessed Tier 1–3 paths defined
  there — never a new ad-hoc harness.
- Honest reporting: pass rates over N runs for stochastic claims, no
  mock-data-presented-as-benchmark.

## Testing & Evaluation Strategy

One blessed path per tier. Future work (human or agent) extends these paths;
inventing a parallel harness is a review-blocking finding. All live tiers
resolve the model through the existing seam
`PtcRunner.TestSupport.LLMSupport.model/0` — `PTC_TEST_MODEL` env var, default
in the main checkout's `.env` pinned to
`openrouter:google/gemini-3.1-flash-lite`; the registry alias
`gemini-flash-lite` resolves to the same model (default_registry.ex:83-88) —
and gate on `LLMSupport.ensure_api_key!/1`. Note: this worktree has no `.env`
(Dotenv's upward walk finds none) — copy it from the main checkout or export
`OPENROUTER_API_KEY` before running live tiers.

### Tier 0 — Deterministic ExUnit (every commit)

`test/ptc_runner/kernel/*_test.exs`, inline mock `llm:` lambdas only — no API
key, no network, no OTP app config (testability invariant from
capability-kernel-runtime.md). Must cover: callback-shape normalization
(`{:ok, %{content:, tokens:}}` and bare `{:ok, text}`); private-capability
authorization (a caller outside `agent.core`'s declaring exports fails
closed); `project_step/1` shape; the D1 memory strategy; outer deadline kill,
heap kill, and LLM-budget exhaustion; bundle provenance surfaced in results;
and **turn-event shape parity** — extend
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

    mix ptc.kernel_eval --suite smoke --model gemini-flash-lite \
      --runs 5 --variant kernel --report reports/kernel_eval.md

`--model` overrides `PTC_TEST_MODEL` for that invocation; both inputs resolve
through the same seam (`LLMSupport.resolve_model/1` →
`PtcRunner.LLM.Registry.resolve/1`), so any registry alias (e.g. `deepseek`)
is valid. One model seam, not two — the flag is a per-run override of the env
var, never a second resolution path.

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
  rendered oracle failures, and aggregate pass rates.

### Tier 3 — A/B benchmark (M3 only)

Consumes Tier 2 unchanged (same suite, trace schema, report shape). Requires
**preregistration before any run**, as an experiment-notes doc following the
structure of `docs/plans/future/truncation-hints-a-experiment-notes.md`
(exists on branch `exp/truncation-hints-a`, not on this branch — read it
there): date + scope with explicit
non-goals; a cells table with **frozen bundle `source_hash`es**; N per cell;
metrics computed from turn logs via `TraceLog.Analyzer` (turns, tool calls,
duplicate reads by `args_hash`, tokens, correctness); the exact command; and
an honest outcome section — including "did not run" when true.

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
- [ ] **R1b — LLM callback failure surface**: error return shapes, retry
  behavior, timeout handling, and streaming interaction in `ReqLLMAdapter` —
  what `llm-complete` must translate into a recoverable value for the loop
  prelude. (Feeds kernel capability #1 error path.)
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
- [ ] **R4 — Prompt substrate**: which `priv/prompts/` templates render the
  PTC-Lisp language spec + output-format instructions, how to render them
  host-side (`PromptRegistry` / `SystemPrompt`), byte sizes. Decide what the
  kernel passes as `data/language-spec`. (Feeds `agent.prompt`.)
- [ ] **R5 — Bundle + deps API**: exact call shape for layered preludes
  without a `PreludeStore` (raw `Bundle.compile/1` is dep-blind by design —
  confirm whether `agent.core` calling `feedback/*` requires
  `namespace_deps:` via `compile_precompiled/2` or a store-resolved attach).
  (Feeds M2 prelude split.)
- [x] **R6 — Tool-arg/result normalization path** (answered by review round 1,
  2026-07-07): keys stringified, keyword values collapsed to strings
  (eval.ex ~1166–1270); closure tuples preserved (lisp.ex:1209) — recorded in
  architecture.md fact 8. S2 remains to measure the practical consequence.
- [ ] **R7 — TraceLog reuse**: minimal way for the kernel to emit
  `TurnEvent`s so existing `log/` introspection and `args_hash` duplicate-call
  metrics work on kernel runs. (Feeds D4 and M3 measurement.)
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
  and define how oracle failures render in reports.
- [ ] **R11 — Report/trace artifact schema**: finalize the Tier-2 JSON twin's
  required fields (model id, repo commit, bundle component `source_hash`es,
  per-case outcomes, aggregate pass rates), the persistent trace/report
  directory layout, and how Tier 3 preregistration docs reference report
  artifacts.
- [ ] **R9 — Teardown inventory** (see §Teardown below): classify every
  module/test/doc under `lib/ptc_runner/sub_agent/`, related guides, and
  prompt templates into **keep** (kernel substrate), **absorb** (policy that
  becomes prelude code), or **delete at promotion**. Produce
  `teardown.md` with the table. Cheap to do alongside R8 and forces the
  mechanism/policy classification to be exhaustive rather than anecdotal.

## M0 — Spikes

Pre-registered in [`spikes.md`](spikes.md). Order matters: S1 → S2 gate the
design; S3 gates the live path; S4 de-risks the prelude before the kernel
exists.

- [ ] **S1 — Re-entrancy**: nested `Lisp.run` from inside a sandboxed tool
  closure.
- [ ] **S2 — Memory round-trip**: model-defined closures surviving
  loop-threaded memory across the tool boundary. → Decides D1.
- [ ] **S3 — Blocking LLM call in the sandbox**: real flash-lite call from a
  tool closure under relaxed outer limits; timeout accounting; kill-mid-HTTP
  behavior.
- [ ] **S4 — Loop expressiveness**: write `extract-code` + a minimal
  `run-mission` loop as a plain prelude against a *scripted stub* llm tool
  (no kernel, no network, plain `Lisp.run`). Proves the language carries the
  loop comfortably; its source seeds `agent.core`.

**Exit gate:** D1 decided; no spike revealed a mechanism gap that requires
new evaluator machinery. If one did — stop, update architecture.md, rethink.

## M1 — Kernel + `agent.core`, single mission

Smallest real slice: one bundled prelude (core only, prompt/feedback inlined),
one mission, mock-llm tests, one live smoke.

- [ ] `PtcRunner.Kernel.run/2` per architecture.md §Capability Model
  (capabilities, backstops, bundle compile, outer run).
- [ ] `agent.core` prelude v0: single-turn mission — render prompt, one
  `llm-complete`, extract program, one `eval-program`, return/fail.
- [ ] Tier 0 suite: scripted llm lambdas covering happy path, unparseable
  response, program `fail`, LLM budget exhaustion, outer deadline kill,
  private-capability authorization, turn-event shape parity.
- [ ] Tier 1 smoke file with eval-case #1 ("how many products", no tools,
  `{:eq, 500}` oracle) live on the blessed command.
- [ ] First `mix ptc.kernel_eval --suite smoke --runs 5 --variant kernel`
  run recorded (Tier 2, kernel variant only — the task can exist in minimal
  form this early).
- [ ] Gate: standing gates + Tier 0 green + Tier 1 passes + Tier-2 smoke
  records ≥ 4/5 on case #1.

## M2 — Multi-turn + prelude split

The modular-config claim becomes real here.

- [ ] Multi-turn loop in `agent.core`: feedback message construction,
  max-turns wind-down, memory threading (per D1).
- [ ] Split `agent.prompt` and `agent.feedback` into their own namespaces/
  components; wire deps per R5. Policy constants (`feedback/config`) as
  exports.
- [ ] Truncation policy implemented **in** `agent.feedback` (caps + hint
  wording).
- [ ] Suite extended: eval-cases 3/5 (filter + aggregation) and a multi-turn
  cross-dataset case, via Tier 2.
- [ ] Kernel emits turn events (per D4) so runs are measurable with existing
  tooling.
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
- [ ] Same tasks, same model, same seeds where possible; N ≥ 20 runs per cell
  (adjust per llm-benchmark power guidance).
- [ ] Metrics off turn logs: turns, tool calls, repeated reads (`args_hash`),
  correctness, tokens.
- [ ] Deliverable: experiment notes doc + verdict on the thesis ("policy
  iteration as prelude diff") with honest framing.

**Overall exit:** after M3, write a verdict section in architecture.md —
promote (execute §Teardown as M4), iterate, or archive with findings.

## Teardown (the clean start) — position

The clean start is **earned, not assumed**. During the experiment the old
SubAgent stays untouched because:

- `mix precommit` / the full test suite is the standing gate — deleting
  `sub_agent/` breaks it and blinds us;
- M3 needs the incumbent loop as the measured **baseline** on the same tasks;
- a mass-deletion branch diverges from `main` and makes rebasing a
  weeks-long experiment painful.

What we do *now* is R9: the inventory that makes the eventual deletion a
mechanical, reviewed commit series instead of an archaeology project.
Working guess at the classification (R9 verifies and completes it):

| Bucket | Examples |
| --- | --- |
| Keep (kernel substrate) | `lisp/` (all), `sandbox.ex`, `llm.ex` + adapters, `step.ex`, `turn.ex`, `schema.ex`, `trace_log/`, `prelude_store.ex` |
| Absorb into preludes | prompt assembly, `turn_feedback.ex`, truncation rendering, retry phrasing, progress vocabulary |
| Delete at promotion | `sub_agent/loop*.ex`, `text_mode.ex`, `ptc_tool_call.ex`, compiled agents, compaction, exposure, related tests/guides |
| Undecided | `session.ex`, `upstream/` bridge, `evidence.ex`, MCP server implications |

**M4 — Teardown (only on a "promote" verdict):** execute the inventory
top-down as its own Conventional-Commit series on a fresh branch, deleting
code+tests+docs together per the 0.x working style (delete, don't deprecate;
no shims), with `mix precommit` green after every commit.

## Working agreements

- All work in the `~/projects/ptc_runner-lisp-kernel` worktree on
  `exp/lisp-kernel`; the main checkout is shared with concurrent automations.
- Conventional Commit subjects; commit at phase boundaries, not mid-spike.
- Spike results are appended to spikes.md in the same commit as the spike.
- When code and this doc disagree, fix both in one commit.
