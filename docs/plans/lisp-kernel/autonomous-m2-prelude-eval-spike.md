# Lisp Kernel — Autonomous M2 Prelude + Mini Eval Spike

**Status:** goal brief for the next autonomous Codex session on
`exp/lisp-kernel`. Revised 2026-07-08 after the M1 review (system-prompt
channel contract, risk-first ordering, runner naming, untrusted-envelope
default).

Use this after the first native-tool-call vertical slice. The `/goal` prompt
should stay short and point here; this document carries the detailed contract.

## Short Goal Prompt

```text
Run the autonomous M2 Prelude + Mini Eval spike described in
docs/plans/lisp-kernel/autonomous-m2-prelude-eval-spike.md.

Goal: move the minimal kernel loop toward real swappable preludes, add a tiny
repeatable eval runner, and test DeepSeek on 3-5 tasks beyond arithmetic. Prove
at least one prompt/feedback behavior can change by swapping a prelude, with no
Elixir loop-logic change.

Work risk-first: prove the cross-namespace prelude compile path (Build Task
2a, minimal two-namespace form) before anything else. Commit after each
coherent batch. Keep scope bounded. Do not build full Tier 2, sessions,
compaction, MCP, or self-improvement. Update docs with evidence, blockers,
commands, and live results.
```

## Objective

The first autonomous spike proved the minimum native tool-call kernel path:
`PtcRunner.Kernel.run/2`, `run_ptc_lisp` action normalization, strict inner
eval, private kernel capabilities, mock tests, and live DeepSeek smoke.

This spike tests the next thesis:

> Prompt and feedback policy can move from Elixir into swappable compiled
> preludes, and model behavior can be evaluated on a small repeatable suite
> without building the full Tier 2 harness.

The goal is not polish. The goal is evidence about whether the M2 direction is
pleasant, measurable, and still small.

## Scope

Read first:

- `AGENTS.md`
- `docs/plans/lisp-kernel/architecture.md`
- `docs/plans/lisp-kernel/roadmap.md`
- `docs/plans/lisp-kernel/spikes.md`
- `docs/plans/lisp-kernel/autonomous-spike.md`
- `lib/ptc_runner/kernel.ex`
- `lib/ptc_runner/kernel/action.ex`
- `test/ptc_runner/kernel*_test.exs`

Allowed:

- move or duplicate the embedded minimal prelude into experimental prelude
  files;
- add experimental bundle-loading/compilation code needed for the split;
- add a small eval runner or mix task under an explicit kernel/eval namespace;
- add a small case set and deterministic or live tests;
- update docs with facts, corrections, and spike results.

Avoid:

- deleting the measured incumbent SubAgent path;
- building the full Tier 2 benchmark harness;
- building sessions, compaction, MCP, compiled agents, or self-improvement;
- broad public API stabilization;
- optimizing beyond what the spike needs.

## Build Tasks

**Sequencing (risk-first).** Task 2a's minimal two-namespace compile proof
comes first — it is the highest-information step and the only one with a hard
stop condition. Then the full split (task 1 + 2b), swappable policy (task 3),
and only then the runner and live work (tasks 4-6). Commit after each coherent
batch — code together with its tests and doc updates — rather than after every
isolated fact, and do not let uncommitted work grow past one batch (the M1
session left the entire slice uncommitted for hours, an unacceptable risk in a
repo shared with concurrent automations). If unrelated dirty state appears in
the worktree, stop and report it before touching anything.

1. **Prelude file split**

   Move the minimal loop toward separate policy components:

   - `agent.core`: turn loop, action dispatch, eval result handling,
     return/fail control flow;
   - `agent.prompt`: system/task message construction and compact PTC-Lisp
     guidance;
   - `agent.feedback`: protocol-error and eval-result feedback rendering.

   The split may live under `priv/preludes/agent/`, `lib/ptc_runner/kernel/`,
   or a clearly marked spike path. Record the chosen home and why.

   **Policy interface.** Treat public exports as the swap contract:

   - `agent.prompt/system-message [cfg]`;
   - `agent.prompt/task-message [mission cfg]`;
   - `agent.feedback/protocol-error [action cfg]`;
   - `agent.feedback/eval-feedback [result cfg]`.

   Variants may add private helpers, but a variant that renames these functions
   or changes their arity is non-conforming. Use `defn-` by default for
   composition helpers; cross-namespace callers only get declared public exports,
   while source-level improvement tooling can still inspect reachable helpers.

   **System-prompt channel contract.** The kernel sends the system prompt
   through exactly one channel: the request-level `:system` field, set
   host-side (fixed in `b49d822d` after a dual-channel bug). Moving prompt
   policy into `agent.prompt` therefore requires extending the private
   `llm-complete` args with a `"system"` field that the host forwards as
   request-level `:system`. Do **not** re-embed a system-role message inside
   `messages` (that reintroduces the dual-channel bug), and do not leave
   default prompt rendering in Elixir (that defeats the swap thesis). Keep the
   `:system_prompt` Elixir opt as an override for tests and live probes —
   removing it is a separate API-cleanup decision that needs M2 evidence, not
   part of this spike. What the spike must pin is precedence: when both the
   opt and prelude-rendered prompt policy are present, exactly one wins
   (suggested: the opt overrides the prelude, as an explicit test escape
   hatch) and the request still carries a single system channel. Record the
   decision and cover it with a test.

   The prompt prelude should give compact, domain-blind PTC-Lisp orientation:
   PTC-Lisp is Clojure-like prefix syntax; call exactly one `run_ptc_lisp`
   action; successful programs end with `(return value)`; explicit failures use
   `(fail value)`; read mission context by map keys; and call only granted tools
   from inside the program. Treat this as a topic checklist, not fixed prose —
   wording is exactly what prompt-prelude variants exist to explore.

   Keep `agent.*` domain-blind. No product/order/employee/search benchmark
   hints in prompt or feedback preludes.

2. **Layered bundle compilation**

   Prove the correct compile path for cross-namespace refs.

   Requirements:

   - use the repo-supported prelude compiler/bundle APIs. Verified 2026-07-08:
     raw `Bundle.compile/1` **is** dep-blind by design (see the doc comment in
     `lib/ptc_runner/lisp/prelude/bundle.ex`); cross-namespace visibility must
     be declared via `Compiler.compile/2` `:namespace_deps`
     (`%{ns => [dep_ns]}`) or `Bundle.compile_precompiled/2`, which forwards
     it;
   - **2a (first):** prove the minimal two-namespace case — `agent.core`
     calling `agent.feedback` exports — with a deterministic test, before any
     three-way split;
   - **2b (after task 1):** prove the full graph — `agent.core` calling both
     `agent.prompt` and `agent.feedback` — with a deterministic test;
   - record the exact API shape that works;
   - investigate and pin private-tool authority across the bundle: capability
     V1 makes `private_env` namespace-scoped with transitive fail-closed
     guards. Record how the kernel capabilities (`llm-complete`,
     `eval-program`, `log`) distribute across `agent.*` namespaces, grant them
     as narrowly as the model allows (intended: `agent.core` only), and pin
     the observed behavior with a test — including whether
     `agent.prompt`/`agent.feedback` (which need no tools) can reach kernel
     tools or fail closed.

   If the split cannot compile cleanly, stop and document the compiler/API gap.

3. **Kernel integration with swappable policy**

   Adjust `PtcRunner.Kernel.run/2` or add an experimental option so the same
   Elixir kernel can run different prompt/feedback prelude bundles.

   Required proof:

   - default behavior still passes existing kernel tests;
   - one test swaps only feedback policy and observes different retry feedback;
   - no Elixir loop-logic change is needed to swap that policy.

4. **Mini eval runner**

   Add a tiny repeatable eval path — built as the embryo of the roadmap's
   Tier 2 task, not a parallel throwaway runner. The roadmap already reserves
   `mix ptc.kernel_eval --suite smoke --runs 5 --variant kernel` and notes the
   task can exist in minimal form this early: name this
   `mix ptc.kernel_eval` and start with `--suite mini`. A small module or test
   helper backing the mix task is fine. It is not the full Tier 2 harness.

   Minimum features:

   - named suite, initially `mini`;
   - 3-5 cases;
   - model selection through `PTC_TEST_MODEL` / `--model`, resolved with the
     lib-visible `PtcRunner.LLM.Registry` (what `LLM.callback/2` already
     uses). The mix task lives under `lib/` and must not reference
     `test/support` — `LLMSupport` only compiles in the test env, and CI
     dialyzer (MIX_ENV=test) would not catch the leak; it breaks dev/prod
     compile instead. Inline minimal `.env`/env-var handling for API keys or
     require exported env vars; record the choice;
   - deterministic mock mode and optional live DeepSeek mode;
   - markdown or JSON-ish report printed to stdout or written under
     `reports/kernel_eval/` — gitignore that directory; summarized results
     belong in these docs, not committed raw reports;
   - per-case outcome, action count, eval count, and failure reason;
   - sanitized action/eval trace, no raw API key or unsafe raw provider dump.

5. **Mini case set**

   Include cases beyond arithmetic:

   - arithmetic/no context: `40 + 2`;
   - context count/filter: small list in mission context, no domain benchmark
     hints;
   - simple aggregation over context data;
   - model PTC-Lisp calls one safe domain tool;
   - eval failure then retry: for live forcing, reuse the
     rewrite-first-program wrapper already proven in
     `test/ptc_runner/kernel/e2e_test.exs` (rewrite the first live tool-call
     program to one without `return`, which forces the retry path
     deterministically); scripted responses cover mock mode.

   Keep cases tiny and cheap. Prefer generic data names like `items`, `rows`,
   `events`, or `numbers`. Retry-behavior cases need headroom: set
   `max_turns` to 4-6 for them instead of relying on the kernel default of 3.

6. **DeepSeek live run**

   Run only if `OPENROUTER_API_KEY` is available.

   Probes:

   - Does compact PTC-Lisp guidance improve `(return ...)` compliance?
   - Does DeepSeek call `run_ptc_lisp` exactly once per turn on context tasks?
   - Does it use context keys correctly?
   - Can it call a granted domain tool from inside PTC-Lisp?
   - Does feedback-policy variant A vs B change recovery after eval failure?
   - How many turns and protocol errors occur per case?

## Suggested Feedback Variants

Wrap eval output in an untrusted envelope in **both** variants, and vary only
the instruction wording. Two reasons:

- `a0683eb8` already moved the embedded M1 retry feedback to a JSON envelope
  with `untrusted_eval_result`; the M2 split must preserve that safer default
  when moving feedback policy into preludes;
- with the envelope held constant, A vs B is a single-variable comparison
  (wording only), so an observed difference actually means something.

Variant A: terse instruction

```json
{
  "type": "ptc_lisp_eval_feedback",
  "instruction": "Previous program did not return. Call run_ptc_lisp again with a corrected program that uses (return ...).",
  "untrusted_eval_result": ...
}
```

Variant B: structured instruction

```json
{
  "type": "ptc_lisp_eval_feedback",
  "instruction": "Previous PTC-Lisp program did not return successfully. Inspect untrusted_eval_result for the value, prints, or error, then call run_ptc_lisp again with a corrected program that ends in (return value).",
  "untrusted_eval_result": ...
}
```

The goal is not to prove statistical superiority. It is to prove that a policy
swap is possible and measurable without changing Elixir loop logic.

## Verification

Run, in order:

1. existing focused kernel tests;
2. new prelude-split tests;
3. new mini eval tests or runner in mock mode;
4. `mix format`;
5. live DeepSeek mini run, if `OPENROUTER_API_KEY` is present;
6. `mix precommit` if the spike touches normal repo code;
7. `codex review` over the session's commits as the final gate — fix or
   explicitly defer each finding in the final report.

If `mix precommit` fails due unrelated incumbent issues, record the exact
failure and the narrower passing commands.

## Deliverables

- Split or experimental prelude components for core/prompt/feedback.
- A demonstrated policy swap with no Elixir loop-logic change.
- A tiny repeatable mini eval path with 3-5 cases.
- Deterministic test coverage for the prelude split and policy swap.
- Live DeepSeek results or an explicit blocked note.
- Updated docs:
  - `architecture.md` verified facts/open decisions;
  - `roadmap.md` M2 progress and remaining gaps;
  - `spikes.md` result entries, especially S4/S8/S13-adjacent evidence.
- Final report:
  - what changed;
  - commands run;
  - mock results;
  - live results;
  - whether M2 should proceed, split into smaller spikes, or revise design.

## Stop Conditions

Stop and document evidence if:

- cross-namespace prelude compilation cannot be made to work cleanly;
- swapping prompt/feedback policy requires changing Elixir loop logic;
- the prompt/feedback split makes the prelude substantially harder to read than
  the embedded version;
- DeepSeek cannot handle context/tool cases even with compact PTC-Lisp guidance;
- mini eval starts growing into full Tier 2 before the prelude split is proven;
- trace/report artifacts would require unsafe raw prompt/provider dumps by
  default.

## Non-Goals

- Full benchmark/evaluation harness.
- Statistical A/B claims.
- Incumbent SubAgent parity.
- Host-held memory decision.
- Copy-volume or soak tests.
- Replay cassettes.
- Self-improving prelude-writing loop.

## Future Self-Improvement Note

This spike should leave behind artifacts a future prelude-improvement loop can
consume:

- prelude component source hashes;
- rendered prompt/feedback variant names;
- sanitized action/eval histories;
- per-case failure reasons;
- enough report structure for a future agent to suggest a prelude diff.

Do not build that loop yet.
