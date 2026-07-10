# Lisp Kernel — M2 completion brief

**Status:** active completion brief for `exp/lisp-kernel`, revised 2026-07-10
after M1 closure and the deterministic M2 implementation.

The earlier version of this document described a prelude-split and mini-eval
spike. Those proofs now exist. This brief owns the remaining work required to
close M2 without repeating them or creating a second evaluation runner.

## Short goal prompt

```text
Complete M2 using docs/plans/lisp-kernel/autonomous-m2-prelude-eval-spike.md.
Keep agent.core sequential, preserve the S21 capability split and program-only
action protocol, use the existing PtcRunner.Kernel.Eval harness for both
variants, and do not widen live runs until the recorded lifecycle gates pass.
Run both variants on the same seeded Tier 2 dataset and update the evidence.
```

## Baseline already proved

- `agent.core`, `agent.prompt`, and `agent.feedback` are separate dotted
  namespaces with explicit dependency edges.
- Only `agent.core` holds `llm-complete`, `eval-program`, and `log` tool
  references. Prompt and feedback components remain capability-free.
- The loop is multi-turn, emits turn events, threads host-held callable memory,
  and records bounded memory summaries.
- Feedback-only source overrides change component hashes without changing
  Elixir loop logic.
- `PtcRunner.Kernel.Eval` is the blessed deterministic/live runner. Do not add
  another Mix task, report type, oracle, or trace path.

## Frozen scope

M2 completes the modular-policy and informal-parity claim. It includes:

1. exported prompt/feedback policy constants and feedback-owned truncation;
2. a generated memory-boundary property plus canonical continuation-path docs;
3. five canonical Tier 2 cases, fail-closed typed constraints, one seeded
   dataset shared across cells, and a multi-turn cross-dataset case;
4. kernel and incumbent adapters behind the same cases, oracles, trace
   sanitizer, report schema, and CLI;
5. persistent Markdown/JSON reports with dataset/model/repository/provenance,
   aggregate pass rate, projected results, prompt/action hashes, and trace
   integrity fields;
6. preregistered paired live smoke evidence after the lifecycle gates pass.

M2 does not include sessions, compaction, MCP, self-improvement, a parallel
`agent.core`, public API stabilization, or a statistical performance claim.
The measured incumbent SubAgent path must remain intact.

## Canonical contracts

### Cases and data

Each Tier 2 case has `id`, `task`, `context_ref`, `context`, `expect`,
`constraint`, `max_turns`, `tags`, and adapter fixtures used only in mock mode.
The multi-turn memory case also declares `required_persistence`, which is
verified from raw private turn traces before those traces are sanitized. The
definition must be committed, and the terminal program must pass host-scored
dependency checks without rereading the source employee dataset. The host
replays the definition to verify the expected ID set as the turn's only change,
then evaluates the terminal program against several program-derived ID subsets.
Every returned total must match the host-computed expense total for that exact
subset; a hard-coded branch, unchanged answer, or counterfactual error fails the
persistence gate.
The model-visible mission contains only `task` and `context`; it never receives
the oracle, tags, fixture programs, or plan metadata.

Generate the dataset once for a requested integer seed, share it unchanged
across the selected cell, and record its hash. Paired reports are comparable
only when the seed and dataset hash match.

### Oracle

Use `PtcRunner.Kernel.Eval.Oracle`. Unknown/missing expectation types and
constraint tuples fail closed with stable reasons. Equality is exact; floating
answers use ranges. Oracle failures are data in the report, not exceptions and
not model-visible retry instructions.

### Variants

- `kernel` calls `PtcRunner.Kernel.run/2` through the native action protocol.
- `incumbent` calls `PtcRunner.SubAgent.run/2` with explicit completion.

Both use the same task, context, tools, maximum turns, oracle, dataset, model,
trace sanitizer, and report writer. Variant-specific adapters may translate the
mock or provider response envelope but may not change case semantics or rewrite
model-authored programs.

### Memory

Kernel continuation memory stays owner-held and is never serialized between
turns. Callable definitions use `Lisp.run_native/2` with
`preserve_runtime_callables: true`; the public/JSON memory projection is
observation-only. Any future parallel eval path remains excluded until R21
defines atomic budgets and state ownership.

### Reports and privacy

Tier 2 and all live modes require a persistent report path. Reports include the
seed, dataset hash, case-definition hash, model identity, provider, LLM source,
evidence eligibility, commit, command options, component provenance visible in
sanitized turns, per-case projected oracle and
actual results, trace paths, hashes, integrity counters, and aggregate rates.
Eligibility requires a live registry-backed, non-aborted, nonempty run from a
valid clean Git commit.
Raw prompts, responses, programs, tool results, memory values, and credentials
remain excluded unless the existing explicit unsafe-debug path is selected.

Offline execution replay from sanitized artifacts remains S8/S14 work: the M2
artifact preserves audit/revalidation evidence but deliberately does not store
raw model programs merely to make execution replay possible. Do not weaken the
M1 redaction boundary to claim replay completeness.

## Required sequence

1. Keep deterministic mock tests green for both variants and all five Tier 2
   cases.
2. Complete R21/R22 decisions relevant to state ownership and explicitly keep
   parallel behavior excluded where no decision exists.
3. Pass S12 owner cleanup/invalidation/cap/concurrency checks and the remaining
   S11 live-short HTTP lifecycle matrix before widening live runs.
4. Use `experiments/m2-tier2-prereg.md` unchanged. Run the incumbent cell first,
   then kernel, with the same seed/model. If the incumbent shakedown fails,
   attribute the result to model/configuration before architecture.
5. Record outcomes honestly, including infrastructure failure or "not run".
6. Run standing quality gates and an independent clean review before commit.

## Stop conditions

Stop and update the roadmap rather than silently expanding scope if:

- parity requires changing the task, context, oracle, or model between cells;
- a raw secret or model program would enter the default report/trace;
- implementation requires concurrent `eval-program` calls or non-atomic owner
  state mutation;
- the provider/model cannot complete the incumbent shakedown;
- lifecycle measurements show unbounded process, memory, mailbox, trace, or
  HTTP-pool growth.

## Completion evidence

M2 closes only when deterministic tests, the lifecycle prerequisites, both
preregistered live cells, standing gates, documentation, and independent review
are all clean. The live smoke bar is at least 3/5 in each cell and remains an
informal capability observation rather than a claim.
