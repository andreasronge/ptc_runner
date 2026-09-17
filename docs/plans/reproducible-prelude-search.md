# Reproducible prelude search: a toy harness for checked self-improvement

Status: draft, 2026-09-17. No tracking issue yet. Worktree
`plan/reproducible-prelude-search`.

## The claim under test

PtcRunner's distinguishing property is that a run is reproducible from its
artifacts: the language has no clock or random built-in, the bundle is frozen
and hash-identified, and every value that crosses a capability boundary is
recorded with its arguments and result. That makes a model's work
*reproducible*, *checkable* (trusted workflow code decides over recorded
evidence), and *accumulable* (what passes a check is kept as a prelude and
loaded next time).

This plan builds the smallest harness that can measure one consequence of
that property:

> Bounded parallel search over model-written candidates, selected by a check
> against recorded executions, produces prelude repairs that hold on
> executions the model never saw, at a cost that single-shot repair cannot
> match.

Everything else discussed around this direction (open-ended evidence graphs,
agent swarms, a stepping debugger, the incident-evidence domain) is an
instance of the claim, not the claim. Each may enter the harness only when an
experiment below stalls without it.

## What exists today (verified 2026-09-17)

| Boundary | Recorded | Where |
| --- | --- | --- |
| Run result | value and hash | `run-result` inspection record, `.ptc/results/`, hash on `run-stopped` |
| Run input | **no** | the package replaces `input` with an excluded marker; only the input contract hash is retained |
| Mission source | exact source plus the static set of prelude refs it names | `evaluation-source`, `evaluation-analysis` |
| Mission params (`kernel/eval-with`) | identity hash only | kernel-eval capability projection |
| Mission return value | **no** first-class record | reaches the artifact only via the run result, an explicit failure, or the next model request |
| Capability calls (tools, MCP, model) | full arguments and results | `capability-input`, `capability-output` |
| Prelude function calls inside a program | **no** | static reference set only |

Surfaces the harness reuses unchanged: `llm_replay` fixtures for fixed model
answers, `ptc materialize` plus `--component-override-descriptor` for
publishing and evaluating a candidate, `kernel/eval-with` for running a
candidate against one recorded input in a no-model mission, `pmap` for
bounded fan-out from workflow code, and `analysis/*` for reading captured
runs.

## Non-goals

- A stepping debugger. A no-model mission with the prelude installed and the
  recorded inputs bound is already a REPL over the function; `(component id)`
  yields the full source including private helpers.
- A generic multi-agent or swarm prelude. The frontier lives in workflow
  code until two experiments share the same search loop.
- A shared graph capability, open-ended graph construction, or the
  incident-evidence application. Phase 3 seeds the first of these only if
  Phase 2 passes.
- A performance objective (fewer calls, fewer tokens). It is the same loop
  with a different check and waits until the correctness loop is measured.
- Anything in shipped examples. The harness is a maintainer lab under
  `scripts/labs/prelude-search/` and is never published as a `ptc init`
  template while this plan is open.

## The toy

**Subject preludes.** Three small purpose-written, domain-blind PTC-Lisp
components, each with signed public functions and private helpers, roughly
forty to eighty lines: interval merging with a tolerance, a text normaliser
with a tokenizer, and a two-ledger reconciliation. None ships; they exist to
be broken.

**Mutation operators.** Semantic, never syntactically odd: comparator flip
(`<` to `<=`), boundary off-by-one, dropped edge-case clause, swapped map key,
wrong default in a private helper. Ground truth for one instance is the
mutated component, function, form, and the case class below.

**Executions.** An input generator per subject, seeded, produces inputs.
Each input runs once through the unmutated prelude (oracle output, hidden)
and once through the mutated prelude (observed output). Inputs split into a
*visible* set the model may read and a *held-out* set only the check may
use. Some visible inputs reach the mutation and some do not, so coverage is
a real signal.

**Soft evidence** (Phase 2 only). Docs in three variants (correct,
incomplete, wrong), bug reports in three variants (accurate, misleading,
about a non-bug), and a two-version history in which the mutation lands in
one version. Every evidence item carries an `authority` field: `executed` for
inputs, outputs, and counters, `asserted` for docs, reports, and version
notes.

**Case classes and expected answers.**

| Class | Truth | Expected answer |
| --- | --- | --- |
| `code-bug` | spec right, code mutated | localised repair that passes held-out |
| `spec-bug` | code right, doc wrong | no repair; the doc sentence and the executions that contradict it |
| `non-bug` | report misreads the contract | no repair; cite the contract and matching executions |
| `silent-change` | behaviour changed between versions, spec silent | insufficient evidence; name what would settle it |

The last two exist so that "point at the odd-looking line" loses. A diagnosis
is scored only when it cites the visible executions that support it.

## Experiments

Each has a metric, a baseline, and a stop rule. Prompts are domain-blind per
the repository rules; the subject preludes are the only domain-specific text
and they are data. Live runs use a cheap model; each experiment also records
replay fixtures so its regression form is network-free.

### E0. Reproducibility (no model)

Re-execute every recorded execution from its frozen bundle and input and
compare the result hash with the recorded `run-result`.

- Metric: fraction byte-equal; milliseconds per re-execution.
- Expected: all equal. Any inequality is a runtime defect and blocks the
  rest of the plan.
- This is also the cost of one check, which every later budget uses.

### E1. Single-shot repair (baseline)

One `agent.core/run` in a mission that holds the mutated prelude source and
the visible executions as `data/params`, with no tools. The mission returns a
candidate source and a diagnosis. Workflow code publishes the candidate and
checks it against the held-out executions in a no-model mission.

- Metrics: localisation accuracy (function, then form), held-out pass rate,
  tokens, wall-clock.
- Seeds: twenty mutation instances per subject.
- Stop rule: none; this is the baseline.

### E2. Parallel candidates, check selects

`pmap` over K missions, each a single-shot repair with a different visible
subset or ordering, at the same total token budget as E1 with K attempts.
The check ranks candidates; the first that passes held-out wins.

- Metrics: as E1, plus candidates generated and checked per solved instance.
- Hypothesis: pass rate rises with K under a fixed budget.
- Stop rule: if K of four shows no lift over E1 on the twenty seeds, stop the
  search line and report.
- Note: `fail` is refused inside `pmap`, so a candidate mission returns an
  error value rather than failing.

### E3. Evidence-supported diagnosis

Add the three soft-evidence variants and all four case classes.

- Metrics: case-class accuracy; false-repair rate (a repair proposed for a
  `non-bug` or `spec-bug` instance); citation validity (every cited
  execution exists and shows the claimed values).
- Hypothesis: the `authority` field lowers the false-repair rate at equal
  cost.
- Stop rule: if false repairs exceed one in five with authority present,
  the toy's soft evidence is too weak and needs redesign before Phase 3.

### E4. Iterative search with feedback

A candidate that fails held-out receives the failing input and both outputs,
and the mission proposes again, to depth D. Compare to E2 at equal budget.

- Metrics: as E2, plus depth at which the winner was found.
- Hypothesis: depth beats width once the mutation is in a private helper.
- Stop rule: no lift at depth three on the twenty seeds.

### E5. Accumulation and transfer

Let the model write a small evidence-reading helper (diff observed against
expected, group failures by input shape) during E4, keep the helper that the
workflow checked, and run a fresh mutation of a different subject with the
helper preloaded.

- Metrics: E4 metrics with and without the kept helper.
- Hypothesis: a kept helper lowers cost on an unseen subject. This is the
  first measured instance of "accumulable" and the seed of the graph-builder
  idea.
- Stop rule: no cost or pass-rate change on two subjects means helpers do
  not transfer at this size, and the graph direction waits for a larger toy.

## Runtime changes, pulled by experiments

Ordered by the experiment that first needs them. None starts before its
trigger.

1. **`run-input` inspection record** (trigger: E0). A private inspection
   record carrying the selected input value, with the same bounds as
   `run-result`, so a run re-executes from its artifacts alone. The package
   identity keeps excluding the input; only the private artifact gains it.
   The trace gains nothing. Until this lands, the lab stores the input file
   beside the artifacts and E0 reads it from there, which is enough to run
   E0 but not to make the reproducibility claim in a sentence.
2. **`evaluation-params` and `evaluation-result` records** (trigger: E4).
   Today a mission's params are recorded as a hash and its return value not
   at all, so a frontier decision made in workflow code is not auditable
   after the run. Two mission-scoped records in the closed vocabulary,
   validated in both `InspectionRecordTypes` and `InspectionRecord`.
3. **Search loop as a prelude** (trigger: E4 and E5 sharing the same loop).
   Until then the loop is lab workflow code. If promoted, it is a
   `search.core` library beside `agent.core`, not an extension of it.

Nothing here touches `agent.core`, the debug graph, or shipped examples.

## Phases and gates

**Phase 0, days.** One subject, three mutation operators, the generator, and
E0. Gate: E0 all-equal on one hundred executions; the lab runs with one
`mix run` command and leaves real trace and inspection artifacts.

**Phase 1, one to two weeks.** E1 and E2 on all three subjects with replay
fixtures. Gate: a table of pass rate and cost for E1 and E2 at K of two and
four, and a decision on runtime change 1.

**Phase 2.** Soft evidence and E3. Gate: false-repair rate and citation
validity reported; a decision on whether the case classes are hard enough.

**Phase 3.** E4 and E5, with runtime change 2 if E4 needs it. Gate: a
measured answer to "does anything the model wrote transfer", which decides
whether open-ended graph construction gets its own plan.

Each phase ends with numbers in this file, not prose. A phase that ends on
its stop rule is a result, not a failure, and closes the line it tested.

## Open decisions

- Which cheap model runs the live experiments, and whether one seed set is
  shared across all experiments or resampled per experiment.
- Whether a tracking issue opens now or after Phase 0 produces its first
  numbers.
- Whether runtime change 1 records the input under the normal or the private
  data class. The value can be private under `--private-input`, which argues
  for the private class only.
