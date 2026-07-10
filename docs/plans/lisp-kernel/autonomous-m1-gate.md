# Lisp Kernel — Autonomous M1 Gate Plan

**Status:** implementation-ready goal brief for the current
`exp/lisp-kernel` branch and worktree, revised 2026-07-10 after S21 completed.

**Worktree:** `/Users/andreasronge/projects/ptc_runner-lisp-kernel`

**Base:** `c2311601` plus the S21 review follow-ups already committed on this
branch. Continue on `exp/lisp-kernel`; creating another branch or worktree is
optional and is not required by this plan.

This replaces the pre-S21 brief in the sibling
`ptc_runner-lisp-kernel-m1` worktree. Do not cherry-pick or reimplement S21:
the current branch already contains its complete role, runtime, evaluator,
provenance, documentation, and boundary-test series.

## Short Goal Prompt

```text
Run the autonomous M1 Gate plan described in
docs/plans/lisp-kernel/autonomous-m1-gate.md.

Close the Lisp Kernel M1 gate in the current exp/lisp-kernel worktree by
completing missing Tier 0 deterministic coverage, implementing the minimum
recorded smoke/report contract, and running the S11 mock soak. Preserve S21's
separate loop/inner prelude authority and evidence fields. Do not widen the
work into M2, M3, a domain-effectiveness experiment, or a second runner.

Work test-first and risk-first. Inspect current coverage before claiming a
gap. Keep prompts domain-blind. Run the blessed live paths only when credentials
are available. Update roadmap, architecture, and spikes only from evidence.
```

## Objective

Determine whether one kernel mission can run through the strict native
tool-call protocol with stable failure handling, bounded/redacted
observability, and no obvious owner-process, trace, or memory accumulation.

M1 closes only when the roadmap gate passes. Deterministic tests alone are not
sufficient: the Tier 2 smoke, lifecycle soak, and required review evidence must
also be recorded. S21 established a model-callable inner-prelude channel, but
made no domain-effectiveness claim and does not close M1.

## Current Baseline

The current branch already has:

- `Kernel.run/2`, strict native `run_ptc_lisp` action normalization, and the
  embedded/role-backed `agent.*` loop;
- separately authorized, frozen loop and inner prelude artifacts;
- host-held multi-turn memory and inner runtime isolation;
- canonical kernel TurnEvents with MemorySink/JSONL parity;
- source-free loop/inner provenance and inner invocation counts;
- the deterministic `mini` kernel eval suite;
- S21 boundary coverage and a green `mix precommit`.

Before editing, verify every proposed gap against current source and tests.
In particular, do not restore old assumptions that inner programs always use
`prelude: nil`: no-inner remains the baseline, while role-authorized inner
artifacts are attached with `runtime: nil` and `discovery_exec: nil`.

## Required M1 Work

### 1. Tier 0 integration closure

Add only missing cross-boundary tests, preferably in
`test/ptc_runner/kernel/m1_gate_test.exs`. Keep action-shape tests in
`action_test.exs` and shared driver parity in
`turn_log_integration_test.exs`.

Audit and pin:

- strict tool-call-only action handling and no terminal prose answer;
- protocol retry versus terminal transport failure;
- program `(fail ...)`, outer timeout/heap/setup-heap, and stable envelopes;
- validated limits and failure-before-owner/model behavior;
- host LLM-call budgeting;
- private outer capability injection and model denial;
- bounded feedback, prints, errors, tool results, and memory projections;
- prompt hygiene and domain blindness;
- canonical Session/SubAgent/Kernel shape parity;
- loop and inner provenance/report fields without source leakage.

Do not duplicate already-green S21 tests. When an M1 change touches shared
kernel/evaluator/report code, preserve S21's authority and counting invariants.

### 2. Host LLM-call budget

Add validated `:max_llm_calls`, defaulting to validated `:max_turns`:

- both values are positive integers;
- claim a slot with one atomic owner operation before calling the provider;
- exhaustion never invokes `llm` and returns a terminal
  `budget_exhausted` action with reason `llm_budget_exhausted`;
- `agent.core` turns that action into a mission failure;
- the TurnEvent is uncommitted/error with `turn_type: budget_exhausted`;
- exhausted calls do not emit unsafe request payloads.

### 3. Private capability extension

Add `private_capabilities:` as an outer-loop-only map:

- normalize binary/atom names before checking duplicates and reserved names;
- reject invalid names, `llm-complete`, `eval-program`, and `log` collisions;
- accept only native private `%Tool{}` or `{fun, opts}` formats that normalize
  through `Tool.new/2` with a one-arity function;
- reject bare functions, public/non-native tools, malformed options, and
  ambiguous duplicate names before starting owners or calling the model;
- authorize through inferred prelude `tool_refs`;
- never expose these tools in symbol inventory or pass them to inner programs.

Validation precedence must be deterministic: invalid name, reserved name,
duplicate name, then normalized-name-sorted format/privacy validation.

### 4. Stable public failure envelopes

Keep these classes distinct and bounded/JSON-safe:

| Class | Shape |
| --- | --- |
| Preflight validation | `{:error, %{reason: "invalid_kernel_option" | "invalid_private_capability", option: ..., value_type: ...}}` |
| Outer sandbox failure | `{:error, %{reason: "kernel_error", step: bounded_step}}` |
| Mission policy failure | `{:error, %{"reason" => reason, ...}}` |

Never echo raw invalid values or arbitrary inspection output. Canonical option
names and error details are strings from a fixed vocabulary.

### 5. Minimum Tier 2 smoke/report contract

Extend the existing `mix ptc.kernel_eval` path; do not add another harness.

- `--suite smoke`: one deterministic 500-record count case with integer oracle;
- `--variant kernel`: required/accepted; other variants fail until M2;
- `--report PATH`: writes Markdown plus `.json` twin and is required for smoke
  and all live runs;
- each case runs in `TraceLog.with_trace/2` with a persistent sanitized JSONL
  path under the requested/default trace directory;
- reports include requested/resolved/provider model identity, commit, command
  options, loop and inner component hashes/projections, per-run result, trace
  path, and write/drop/unexpected counts;
- reports exclude raw prompts/messages, programs, tool args/results, API keys,
  prelude source/docs/private values, and host-held memory;
- `--allow-failures` affects exit status only, never recorded results.

Preserve the post-S21 evidence fields:

- `preludes` — trusted loop provenance;
- `inner_preludes` — model-callable artifact provenance;
- `inner_prelude_projection` — selected/resolved inner refs;
- `inner_prelude_call_counts` — current inner evaluation invocations.

Add `TraceLog.with_trace(..., return_metadata: true)` returning collector path
and write-error count while preserving the existing result shape for callers
that omit the option.

Compute expected kernel turns from completed eval events plus terminal
protocol/transport/budget actions. Compare that with persisted canonical
kernel turns for the run and report both dropped and unexpected counts.

### 6. S11 lifecycle soak

Add `test/soak/kernel_soak_test.exs`, tagged `:soak`, using existing
`MemorySoak` helpers. One iteration is one successful one-turn mock
`Kernel.run/2`, so owner creation and cleanup happen every iteration.

Required cells:

| Cell | Warmup / measured | Required evidence |
| --- | ---: | --- |
| Untraced churn | 25 / 1,000 | bounded total/binary memory, process delta <= 5, strict atom rate <= 0.1/iteration, empty trace context/sinks |
| Traced turns | 10 / 100 | zero write errors, expected=actual=100, dropped=unexpected=0, collector stopped, same process/atom/memory bounds |

Use monitors and repository async/eventually helpers; never `Process.sleep`.
Keep trace files in test `tmp_dir`. A passing mock soak does not establish live
HTTP/provider stability.

## Implementation Sequence

1. **Coverage inventory:** map every Tier 0 roadmap bullet to existing or
   missing tests; record facts before editing.
2. **Failing tests:** add deterministic boundary reproductions for uncovered
   behavior.
3. **Kernel hardening:** implement option validation, owner acquisition/cleanup,
   atomic LLM budget, private capabilities, and stable envelopes.
4. **Smoke/report:** extend the existing eval task and TraceLog contract with
   focused tests.
5. **Soak:** add and run the two S11 cells.
6. **Evidence closeout:** run all gates, independent review until clean, then
   update roadmap/architecture/spikes from actual results.

Implementation may proceed serially in this worktree and current branch. Do
not create parallel lanes unless explicitly requested later.

## Live Gates

Credentials are available in this worktree's ignored `.env`. The blessed eval
path calls `PtcRunner.Dotenv.load/0` before live model resolution, so do not
manually copy, print, or commit the key. Use the repository model alias
`deepseek`, which currently resolves through OpenRouter to
`openrouter:deepseek/deepseek-v4-flash`. Keep the alias in commands and record
both the requested alias and exact resolved identifier in reports; the model
registry remains the source of truth if the latest approved DeepSeek route is
updated later.

Tier 1 is therefore a required M1 run through:

```sh
mix test test/ptc_runner/kernel/e2e_test.exs --include e2e
```

Run Tier 2 only after its CLI/report contract exists:

```sh
mix ptc.kernel_eval --suite smoke --live --runs 5 --variant kernel \
  --model deepseek --report reports/kernel_eval/m1-kernel-smoke.md \
  --trace-dir reports/kernel_eval/m1-kernel-smoke-traces \
  --allow-failures
```

Run Tier 2 with `--model deepseek` as shown above. Provider failures must still
be recorded honestly; they do not become a pass and do not authorize an ad-hoc
live harness or a switch to another provider/model.

## Non-Goals

- No M2 memory-property suite or incumbent parity.
- No M3 feedback/domain experiment or effectiveness claim.
- No R10 generalized case registry, domain fixtures, randomized cells, or
  generalized validators.
- No replay system or second report/trace format.
- No teardown of the incumbent SubAgent implementation.
- No prompt hints about smoke data, benchmark domains, or expected patterns.
- No reimplementation or weakening of S21 boundaries.

## Worktree and Git Contract

- Work only in `/Users/andreasronge/projects/ptc_runner-lisp-kernel`.
- Continue on the current `exp/lisp-kernel` branch unless the user explicitly
  requests a branch change.
- Do not modify the sibling `ptc_runner-lisp-kernel-m1` worktree.
- Preserve unrelated user changes and stop on overlapping dirty state.
- Use failing tests before bug fixes and coherent Conventional Commits.
- Run `mix precommit` before every commit and `mix prepush` before pushing.
- Do not commit secrets, generated reports, `_build`, `deps`, or soak artifacts.

The sibling `exp/lisp-kernel-m1-gate` branch is an obsolete pre-S21 planning
base. No rebase/cherry-pick integration step is required for this plan.

## Read First

- `AGENTS.md` and linked usage rules;
- this plan, `roadmap.md`, `architecture.md`, and `spikes.md`;
- `lib/ptc_runner/kernel.ex`, `kernel/action.ex`, and `kernel/eval.ex`;
- `lib/ptc_runner/trace_log.ex` and `trace_log/turn_event.ex`;
- `priv/preludes/agent/core.lisp`;
- current kernel, eval, action, S21, and turn-log integration tests;
- `test/support/memory_soak.ex` and existing soak tests.

## Verification

```sh
mix test test/ptc_runner/kernel_test.exs test/ptc_runner/kernel \
  --warnings-as-errors
mix test test/ptc_runner/trace_log/turn_log_integration_test.exs \
  --warnings-as-errors
PTC_SOAK_ITERATIONS=1000 \
  mix test test/soak/kernel_soak_test.exs --only soak
mix ptc.kernel_eval --suite mini
mix precommit
mix prepush
```

Also rerun the focused S21 suite after shared kernel/evaluator/report changes.
Run an independent Codex review after all fixes and repeat until clean.

## Exit Criteria

M1 closes only when:

- Tier 0 deterministic coverage and `mix precommit` pass;
- Tier 1 passes (credential/provider blocking leaves the gate open);
- Tier 2 smoke records at least 4/5 on the single smoke case;
- S11 shows bounded process, memory, atom, and trace behavior;
- trace write, dropped, and unexpected counts are zero;
- domain-blind and redaction audits pass, including S21 inner evidence;
- one final independent review round is clean;
- docs record exact commands, commits, model identity, hashes, results, and
  limitations without claiming incumbent or domain superiority.

If any mechanism gap remains, document the exact blocker and leave M1 open.
Do not begin M2 merely because deterministic tests pass.

## Commit Boundaries

1. `docs(kernel): adapt autonomous M1 gate plan`
2. `test(kernel): pin M1 limits and isolation` (with implementation fixes)
3. `feat(kernel-eval): add recorded M1 smoke`
4. `test(kernel): add lifecycle soak`
5. `docs(kernel): close M1 gate` only after every exit criterion passes

## Expected Handoff

The final series should provide deterministic M1 contract closure, the minimum
sanitized smoke/report path, lifecycle evidence, and an honest gate verdict.
The handoff must list remaining M2 work: memory properties, canonical memory
path, wider suites, truncation policy, replay, and incumbent parity.
