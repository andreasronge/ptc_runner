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

## 7. Unified callable model: agents as typed functions

**Problem.** `SubAgent.run/2` takes a long option list; tools, `llm-query`,
prelude exports, and SubAgents are presented as different concepts with
different calling conventions; and authoring agents or tools requires Elixir.
The goal: running a SubAgent should feel like a function call with declared
input and output parameters, and PTC-Lisp should be sufficient to *compose*
agents and tools — Elixir remains the host that backs them.

**The unification is already latent in the source.** The signature grammar is
a function type — "Full format: `(params) -> output`"
(`sub_agent/signature.ex`), e.g. `(name :string) -> {greeting :string}` —
with `Signature.validate_input/2` already implemented. `SubAgentTool` already
presents an agent to a calling agent as a typed callable carrying that
signature, and the builtin `llm-query` already takes a prompt plus a
signature. The function-call model exists in the type system; it just is not
the primary surface.

**Direction.** Treat everything invocable as a typed function; they differ
only in *backing*:

```text
pure defn ⊂ prelude export ⊂ tool ⊂ llm-query ⊂ single-shot agent ⊂ multi-turn agent
```

`llm-query` *is* a single-turn agent with no tools; a single-shot SubAgent is
`llm-query` plus tools; multi-turn adds the loop. One calling convention (map
in → validated value out), one descriptor shape (name, params, returns,
docstring, effects/`requires`), one discovery surface (`doc` / `meta` /
`apropos` over all of them — the descriptor registry direction in
[`capability-prelude-discovery.md`](capability-prelude-discovery.md)).

`SubAgent`'s option list sorts into three buckets, mirroring the eval-input vs
sibling-policy discipline of
[`capability-kernel-runtime.md`](capability-kernel-runtime.md):

1. **Contract** — prompt template, `params -> returns` signature, output
   mode. Defines the function.
2. **Capability refs** — `tools:`, `llm:`. In Lisp-authored definitions these
   are *names resolved against grants* (`:crm/get-user`, `:code`), never raw
   closures or credentials. Composition without authority.
3. **Policy siblings** — `max_turns`, `retry_turns`, `compaction`, budgets.
   Host/profile defaults, rarely per-call.

A Lisp-authored agent is a **pure data value** holding bucket 1 plus bucket-2
refs:

```clojure
(def analyst
  (agent {:params  "(topic :string, orders [:map])"
          :returns "{summary :string, top-regions [:string]}"
          :prompt  "Analyze {{topic}} in the provided orders."
          :tools   [:crm/get-user :llm-query]
          :llm     :code}))

(analyst {:topic "orders" :orders vip-orders})
```

Because the value references granted capabilities by name, it cannot
escalate: a child can only name tools and model aliases the enclosing profile
grants. That dissolves the "`agent/run` as escape hatch" concern in
[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
— authority is answered by profiles, not by the agent API.

Two further unifications fall out:

- **Context and params merge.** The child's context *is* its validated
  params: the args map becomes `data/*`, template vars resolve from it, and
  `validate_input/2` runs **before any tokens are spent**. Declared keys
  validated; undeclared rejected by default. Large values surface in the
  child prompt as schema + samples, not inlined — the PTC philosophy applied
  to the call boundary.
- **Higher-order agents.** A `:fn` param type plus
  [`function-passing-between-subagents.md`](function-passing-between-subagents.md)
  (closures cross boundaries as immutable tuples) makes agents combinators
  that accept functions as arguments.

**Hold the line on three things:**

- *Function-call shape, not cost illusion.* Invocation dispatches through the
  capability boundary like `tool/*` — the `Lisp.RuntimeCallable` pattern (a
  value carrying a qualified ref, bound to the eval context at call time) is
  the precedent — so budgets, depth caps, tracing, and the §1 ledger all
  apply. The call appears in `tool_calls` and can be refused.
- *Only `run` is a function.* Stateful chat/sessions (memory threading,
  `agent/session`) are not functions; they stay a separate surface per the
  control-plane sketch.
- *The Elixir floor stays.* LLM adapters/credentials, native tool
  implementations that touch the world, grants, limits, persistence —
  host-side, period. The end state is not "no Elixir"; it is the
  control-plane README pressure test realized: PTC-Lisp as the authoring
  language, Elixir as the host SDK that backs the names.

**Migration order (each step useful alone):**

1. Enforce input signatures on `SubAgent.run` itself — validate context
   against declared params when present. The machinery exists; this promotes
   it from the tool boundary to the primary surface.
2. Collapse `llm_query` / `LlmTool` / `SubAgentTool` toward one callable
   descriptor — one schema-derivation path, one prompt presentation.
3. `(agent ...)` values + invocation from Lisp via the host capability
   interface — requires the control-plane primitive layer and budget/depth
   inheritance to land first.
4. Descriptor/discovery unification; README flips to Lisp-primary with
   Elixir as the host layer.

**Open questions.** Policy for undeclared arg keys (closed by default, or an
explicit `:open` flag); whether agent values serialize into memory/traces (as
data they should — but bucket-2 refs must re-resolve against the *current*
grants on rehydration, never capture backing); ad-hoc `(agent ...)` values vs
profile-registered agents (both should yield the same descriptor; only the
latter are discoverable capabilities); how bucket-3 policy defaults resolve
for Lisp-defined agents (profile defaults vs explicit per-agent overrides).

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
- §7 step 1 (input-signature enforcement on `SubAgent.run`) is independent
  and small — a good first PR. Steps 3–4 depend on the control-plane
  primitive layer and the profiles/grants model; §7's higher-order params
  depend on function passing (Option E).
