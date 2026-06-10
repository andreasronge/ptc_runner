# Future Directions — Idea Backlog

**Status:** exploratory idea backlog, not plans. Each section is discussion
material: a problem worth solving, a mechanism sketch grounded in what already
exists in the source, and open questions. None of this is committed work.
Companion docs:
[`programmable-agent-loop.md`](programmable-agent-loop.md) (loop policy hooks),
[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
(control surface),
[`capability-prelude-discovery.md`](capability-prelude-discovery.md)
(authority model),
[`function-passing-between-subagents.md`](function-passing-between-subagents.md)
(closure passing).

The common thread: every idea here leans on strengths the library already has
— cheap isolated sandbox processes, immutable program/memory/closure values,
effect classification, and trace infrastructure — rather than importing
patterns from frameworks built on mutable runtimes.

---

## 1. Call ledger: exactly-once tool effects and safe re-execution

**Problem.** The journal capability (`(task "id" expr)` / `(step-done ...)`,
`priv/prompts/capability-journal.md`) asks the LLM to implement a safety
property: side effects are deduplicated only if the model remembers to wrap
each one in `(task ...)` with a well-chosen string ID. And the record lives in
the wrong failure domain: the journal travels inside the eval context, and
several error paths rebuild the error `Step` from the *turn-start* journal
rather than the journal at the failure point (see the `Step.error(...,
journal: journal)` calls on the timeout/no-context paths in `lisp.ex`, vs the
`:error_with_ctx` path which preserves `eval_ctx.journal`). A sandbox timeout
or heap kill loses it entirely. Net effect: a program that succeeds at
`(task "call-bob" (tool/phone-call ...))` and crashes two expressions later
can re-dial on the retry turn. Separately, `tool_cache` documents its own
race: "in `pmap`, two parallel branches may both miss the cache and execute"
(`tool.ex`).

**Direction.** Move exactly-once out of the program and into a host-owned,
per-mission **call ledger** in a separate process — the same durability move
the upstream subsystem already made with its separate-process `Collector`,
and the same design as the deferred Phase 3b attempt-records in
[`upstream-runtime-roadmap.md` §4.1](upstream-runtime-roadmap.md#41-phase-3b--core-attempt-record-ledger--mcp-ledger-retirement-defer)
(a loop-level consumer of such records is literally that section's trigger
no. 1). Sketch:

- Tools declare effect policy in metadata, next to the existing `cache:`
  flag on `PtcRunner.Tool`: `effect: :read | :write` plus `once: true`.
- For a `once: true` tool, dispatch consults the ledger first: atomic claim →
  `attempted` row (pre-dispatch, survives sandbox kill) → dispatch → finalize
  `ok`/`error` with the result.
- Replay semantics on retry turns: prior `ok` → return the recorded result
  (memoized replay); prior `attempted` with no terminal row → fail closed as
  `:in_doubt` — never silently retry a non-idempotent effect — surfaced
  through the existing continuation-guard / `:partial_side_effects` path.
- **Keys are not LLM-invented wrappers.** Because the LLM regenerates the
  program each turn, arg-hashes are fragile identities (formatting, key
  order). For `once: true` tools, require an explicit `:idempotency-key`
  argument in the tool signature, so omission fails validation rather than
  double-firing at runtime. Host-computed canonicalized-arg hashes remain the
  fallback for stable-args cases.
- The atomic claim in a ledger process also fixes the documented `pmap`
  double-execution race in `tool_cache`.
- Once shipped, delete `(task ...)` rather than maintaining two idempotency
  stories (0.x rules); `(step-done ...)` folds into whatever plan vocabulary
  a prelude provides.

**Why this shape.** Mainstream agent harnesses that successfully use
plan-as-program pair the program with a replay journal underneath — re-running
a script replays completed work from cache, and determinism constraints keep
the replay sound. ptc_runner's multi-turn loop is already "regenerate the
program and run again"; ledger-backed replay turns every retry turn into a
resume instead of a re-execution.

**Open questions.** Ledger/Collector unification or parallel mechanisms; key
canonicalization rules; how `:in_doubt` entries are presented to the LLM for
resolution; whether read-classified calls are ever memoized for consistency
(see §2); retention of ledger rows in `Step` and traces.

---

## 2. Plan/apply: dry-run execution for write-bearing programs

**Problem.** The biggest blocker for letting agents touch systems that matter
is that a generated program's writes execute as a side effect of finding out
what the program does.

**Direction.** A dry-run execution mode, leaning on the effect classification
that already exists (`PtcRunner.Upstream.Effect.classify/3`,
`SideEffectGuard`): read-classified calls execute for real; write-classified
calls are intercepted and accumulated into a **plan** — tool, args,
classification, position in the program — and the program continues with a
placeholder result where one can be synthesized, or halts at the first write
whose result later expressions depend on. A human (or a policy) reviews the
plan; on approval, the *same program* re-runs with writes enabled, with reads
served from the dry-run's recorded results (the §1 ledger) so the apply pass
acts on the same world the plan was computed from.

This is plan/apply from infrastructure tooling applied to agent programs. PTC
makes it feasible where chat-loop agents cannot: the unit of execution is a
program that can be run twice, not an opaque trajectory.

**What exists.** Effect classification and guards (upstream); the `once`/
ledger mechanism (§1) supplies the record-and-replay substrate; MCP
elicitation/approval flows are a natural review surface for the MCP host.

**Open questions.** Write-result placeholders vs halt-at-first-dependent-write
(likely: halt is V1, placeholders never); read staleness between plan and
apply; rendering a plan for human review (bounded, redacted — same rules as
trace payloads); how local in-process tools get effect metadata (today
classification is upstream-only; `PtcRunner.Tool` would need an `effect:`
field, which §1 wants anyway).

---

## 3. Speculative N-candidate execution

**Problem.** A single generated program is a single sample from the model.
For hard transformations, the first sample is sometimes subtly wrong, and the
failure surfaces downstream where it is expensive.

**Direction.** Generate N candidate programs (resampling or prompt
variations), run all of them in parallel isolated sandboxes against the same
context, and accept by validation and agreement: candidates must pass
signature validation (`SubAgent.Signature` / return validation), and
divergence among passing candidates is itself a signal — agreement → accept;
disagreement → escalate (another turn, a judge, or a human). Sandbox spawns
are cheap on the BEAM and `pmap`/parallel-budget machinery already manages
worker pools.

The hard constraint is side effects: speculative execution is only sound for
read-only or pure programs. Composition with §2 resolves it — candidates run
in dry-run mode, and only the accepted candidate's plan is applied.
Self-consistency voting over *programs with checkable outputs* is
substantially stronger than voting over prose.

**Open questions.** Cost policy (N model calls per turn — likely a
per-mission opt-in, budget-gated); equality of candidate returns (float
precision, map ordering — `float_precision` normalization helps); whether
divergence feeds back into the prompt as structured feedback.

---

## 4. Replay-based regression corpus for model upgrades

**Problem.** "Did the model upgrade break my agent?" is answered today by
re-running live missions — slow, paid, and nondeterministic.

**Direction.** Record real runs as replayable artifacts: context projection,
generated program per turn, tool calls with results, final return (the trace
infrastructure — `trace_log`, journal JSONL read by `ptc_viewer` — already
captures most of this). Two replay tiers:

1. **LLM-free CI:** replay recorded *programs* against recorded tool results
   (stubbed executors). This pins the evaluator: language changes, prelude
   changes, and refactors cannot silently change what an old program
   computes. No tokens spent.
2. **Model regression:** on a model/prompt change, generate *new* programs
   for the recorded missions and compare returns against the frozen corpus —
   pass-rate over the corpus, using the existing benchmark statistics
   tooling rather than single-run claims.

This composes with the historical-artifact design in
[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
— the same durable artifact serves debugging (fork-before-failed-turn) and
regression (replay corpus). Define the artifact once for both consumers.

**Open questions.** Artifact schema and redaction (same payload policy as MCP
response shaping); equality semantics for returns; corpus curation (which
missions earn a slot); where stubs live so test prompts stay domain-blind per
repo policy.

---

## 5. Earned skill libraries (slow-loop function promotion)

**Problem.** Agents re-derive the same helpers mission after mission. Within
one mission,
[`function-passing-between-subagents.md`](function-passing-between-subagents.md)
fixes this for parent→child. Across missions, nothing accumulates.

**Direction.** A promotion pipeline from mission-scoped definitions to
curated prelude exports: successful runs leave `defn`s in memory and traces →
candidates are extracted (e.g. recurring near-identical helpers across
missions), rendered for review via `CoreToSource` → benchmarked against the
incumbent prelude → human approves → the helper lands in a versioned prelude
with provenance metadata. This is the LLM-authored-prelude proposal workflow
already on the deferred list in
[`capability-prelude-discovery.md`](capability-prelude-discovery.md), pointed
at function accumulation, and it is the "slow loop" of
[`programmable-agent-loop.md`](programmable-agent-loop.md) applied to domain
helpers instead of loop policy.

Security note: promotion changes *trust presentation*, not authority — a
promoted function still runs sandboxed with the same grants, but it gains
prompt visibility and implicit endorsement, which is why the human gate and
benchmark evidence are non-negotiable.

**Open questions.** Provenance/versioning metadata on exports; namespacing
promoted helpers vs hand-written ones; deprecation/eviction when a helper
goes stale; whether extraction is trace-mining or explicit
`(propose-skill ...)` from the agent.

---

## 6. Budget-adaptive programs

**Problem.** Token/cost budgets are enforced from outside; the program that
could choose a cheaper strategy never finds out it should.

**Direction.** The smallest idea here: `:budget` is already classified as a
program-observable eval input (see the option table in
[`capability-kernel-runtime.md`](capability-kernel-runtime.md)). Make the
pattern first-class: bounded budget introspection builtins plus prompt/prelude
guidance so generated programs branch on remaining budget — sample-and-
estimate under pressure, full scan plus `llm-query` when there is headroom.
Cost-adaptive behavior written by the LLM *into the program* is more reliable
than hoping the model self-limits across turns. Mostly a prompting + prelude
pattern; possibly zero core changes.

**Open questions.** What budget facts are safe and useful to expose (remaining
tool calls, elapsed ms, token budget share); whether adaptive branching
measurably improves pass-rate-per-cost (benchmark before recommending it in
prompt cards).

---

## Sequencing notes

Rough dependency order, not commitment:

- §1 (ledger) is the foundation — §2 needs its record/replay substrate, §3
  composes with §2 for write safety, and the journal's known weaknesses make
  it the most *currently painful* item.
- §4 depends only on artifact design and can proceed in parallel; it shares
  the artifact with the control-plane debugging story.
- §5 depends on function passing (shipped Option E would strengthen it) and
  the approval workflow; it is slow-loop by construction.
- §6 is independent and cheap; worth a benchmark experiment whenever
  convenient.
