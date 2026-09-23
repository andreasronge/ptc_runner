---
program: self-improvement
experiment: self-improvement/001
issue: 2052
tag: research/self-improvement/001
kinds: [explore]
hypotheses: [H1]
model: none
replay: examples/llm-replay/replay.jsonl
tags: [prelude, inventory, no-model]
---

# Shipped prelude helper inventory

Date: 2026-09-23. This is an `explore` result, not a test of H1. No model was
called, no candidate was edited, and live spend was USD 0. The machine-readable
[inventory](001.json) has one row for each of the 61 public `defn` forms in
`priv/preludes/kernel/*.clj`, excluding generated `agent.failure.clj`. It gives
the source line, classification and reason, known recording count, direct test
call sites, unverified paths, current cost observability, and a replay judgment
for every function. Private `defn-` forms are included in the public caller's
reasoning but are not separate rows.

## Method and limits of the evidence

I enumerated public definitions from the shipped source, read their bodies and
callers, and searched the retained fixture and test trees for explicit calls.
Classification is about the *whole public call*, including effects of its
callees. `model-visible` means its value, prompt state, or message can enter a
model request in the shipped agent path; even a pure implementation can be in
this class. `nondeterministic` means a model, changing run state, or external
capability can affect the call. `deterministic` means the function computes from
supplied values or a frozen manifest contract. A caller can still forward a
deterministic result to a model; the classification does not license changing
that result.

`coverage_count` in the JSON is a conservative number of **distinct public
function invocations in retained fixture scenarios**, inferred from workflow
control flow and recorded request counts. Test reruns do not add to this
number. It is zero where no execution could be established from retained
evidence. `direct_test_call_sites` lists explicit calls in non-E2E test files
(including nightly tests),
including multiline literals. A site can execute many times, and a helper can
execute indirectly with no site in its row. Exact dynamic counts and branch
paths still need evaluator instrumentation. Zero means **no established
retained execution**, not proof that the function never ran. This remains a
material gap for b02.

`examples/llm-replay/workflow.clj:5-9` invokes `cap/unwrap!` once, paired with
one response in `examples/llm-replay/replay.jsonl`. It calls
`tool/llm-request` directly, so it does not cover `llm/request` or the agent
loop. Other retained fixtures do cover the agent loop:

| Fixture/scenario | Distinct agent loops | Recorded model calls | Evidence |
| --- | ---: | ---: | --- |
| `examples/dabstep-fraud/replay.jsonl`, one full workflow | 3 | 11 | `workflow.clj:19-68`; `evidence/STUDY.md:155-165` |
| `examples/dabstep-fraud/reviewer-replay.jsonl`, three reviewer cases | 3 | 3 | `reviewer-workflow.clj:15`; `evidence/STUDY.md:150-155` |
| `examples/dabstep-fraud/verification-replay.jsonl`, correction and exhaustion cases | 6 | 7 | `evidence/VERIFICATION.md:9-21`; `dabstep_reviewer_regression_test.exs:102-136` |
| `examples/adaptive-web-parser/replay.jsonl`, one repair run | 1 | 2 | `workflow.clj:61`; its README and fixture |

These yield twelve `agent.core/run-outcome` calls, one
`agent.core/run-value` call, thirteen `agent.machine/start` calls, and at least
23 `llm/request`, `agent.native/normalize`, and prompt-render calls. The
`coverage_count` rows show conservative per-function counts; they do not imply
coverage of every branch. I also propagated only guaranteed transitive calls:
all thirteen loops resolve a named return contract and validate a returned
candidate (`agent.core.clj:94-114,647`), every model response is annotated
(`agent.core.clj:482-487`), and each prompt render reads mission model context
(`agent.prompt.clj:311-316`). Ten requests occur after the first request of
their loop, establishing at least ten retry-policy and prompt-transition
calls. The adaptive repair run reads the accepted source and evaluates the
installed parser before requesting a model, establishing at least two
`kernel/eval-with` calls; its successful repair also checks terminal source
and evaluates the candidate on two URLs (`workflow.clj:10-31,61-80`). These
are lower bounds where the code may invoke a helper more often. The three
`scripts/labs/prelude-search/subjects/*.clj` are application preludes, not
shipped kernel helpers. Their 300 of 300 byte-equal re-executions in
[prelude-search/000](../prelude-search/000-reproducibility.md) therefore count
as **zero** recorded shipped-helper executions for this inventory. The
`test/fixtures/prompts/` files are prompt inputs consumed by
`prompt_audit_test.exs`, not standalone run recordings. Other fixtures were
searched for explicit helper calls; none supplied a retained per-call execution
index. The direct test sites in the JSON are evidence of test exercise, but
their exact dynamic counts and branch paths remain unknown.

Structural branch forms (`if`, `cond`, `case`, `when`, `and`, `or`, `loop`) were
read in each public function's source span. `uncovered_paths` identifies
branches with no demonstrated *recording* and highlights meaningful test-only
paths. This is a conservative source and fixture comparison, not measured
statement coverage. For example, `cap/fold-pages` has tests for completion,
page limit, resume, changed snapshot, invalid bound/hash, cursor cycle, and
large traversal in `test/ptc_runner/kernel/cap_agent_main_test.exs:90-180`, but
no retained replay recording for any arm. `agent.machine/advance` has a broad
event table in `agent_machine_test.exs`, yet no per-event recording index.

## Classification and judgment

| Class | Public functions | Reason and replay consequence |
| --- | ---: | --- |
| Deterministic | 10 | `cap/unwrap!`, `result/*`, `prompt.audit/*`, `agent.retry/backoff-ms`, and the fixed-contract validators are functions of supplied or frozen input. A strict result-hash judge is possible after frozen inputs are retained. |
| Model-visible | 20 | `agent.prompt/*`, `agent.feedback/*`, `agent.machine/*`, `agent.native/*`, `agent.retry/retry?`, and prompt-facing Kernel presentations can alter request bytes or the number of requests. Existing response fixtures cannot judge a changed request; exact request-hash matching fails. |
| Nondeterministic | 31 | `agent.core/*`, `agent.main/run`, `llm/request`, analysis/debug navigation, `cap/fold-pages`, runtime counters, workflow annotation, installed capability discovery, and mission evaluation/checks depend on model, callbacks, or capability/run state. They require frozen external outputs or a separate judge. |

The row-level source lines and reasons are in `001.json`. A capability result
can be repeatable within one frozen run, but that is weaker than intrinsic
determinism; these calls are conservatively classified `nondeterministic`.
`kernel/mission-model-context` and contract presentations are stable for a
frozen manifest but are `model-visible` because `agent.prompt/render` and
`agent.core` place them into system-prompt state. `agent.retry/backoff-ms` is
pure and no shipped caller was found; optimizing an unused helper has no
measurable production gain.
`cap/fold-pages` calls caller-provided `fetch` and `step` functions
(`cap.clj:69,87`); `fetch` may call a changing capability. Its public call is
therefore `nondeterministic` without frozen, pure callbacks and page fixtures.

The current byte-equal mechanism for a deterministic candidate would freeze
its bundle and input, re-execute them as prelude-search Phase 0 does, and
compare strict JSON result hashes. That method applies in principle to each
deterministic row, but the shipped-helper inputs and candidate-specific
recordings are missing. The `examples/llm-replay` request hash checks exact
provider-neutral request bytes; it can serve unchanged requests, but a helper
edit that changes a model-visible byte misses the fixture. The existing
prelude-search model fixtures are not a substitute for this judge: they cover
the three application subjects and record provider outcomes for their own
requests, not arbitrary shipped-helper calls. `prelude-search/004` had 48
evaluation-error slots among 105 scored candidates and a stopped truncated
model response. Agent feedback, machine, native normalization, and core loop
paths can depend on those failures, so a successful-only response fixture
would leave the important correction paths unjudged
([004 report](../prelude-search/004-stopped-e1-e2.md)).

Kernel traces report `duration_ms` for whole spans
(`lib/ptc_runner/kernel/trace_log.ex:2896`); `Kernel.run` exposes aggregate
usage, including subordinate evaluation counts and retained memory, as the
tests in `agent_library_test.exs:914-915,2945-2948,3063-3067` demonstrate.
Neither records per-public-helper evaluation steps, heap allocation, or elapsed
time. An isolated no-model run of a helper can be measured as an aggregate
invocation, but there is no retained paired cost example for these candidates
today. The approximately 4.5–5.1 ms per replay in prelude-search/000 measures
whole application runs of different subjects and must not be attributed to a
shipped helper. Each JSON row states this measurement boundary.

## Ranked shortlist for self-improvement/b02

These are suitable **targets for constructing a judge**, not yet admissible
optimization candidates. Rank reflects pure behavior, meaningful work, and
test inputs already available. Every entry needs a frozen input and withheld
branch cases before model-proposed edits are scored.

1. `prompt.audit/segments` (`prompt.audit.clj:112`): pure parsing of frozen
   prompt text with recognized/unrecognized and malformed-boundary cases in
   `prompt_audit_test.exs`. Replay complete output, including segment order.
2. `prompt.audit/measure` (`prompt.audit.clj:216`): pure counting over frozen
   prompt text, with ordinary/final prompt fixtures and newline/Unicode tests.
   Compare the full JSON result and aggregate isolated-run cost.
3. `prompt.audit/delta` (`prompt.audit.clj:269`): pure paired-prompt arithmetic.
   It needs retained before/after pairs and zero-baseline cases; its expected
   cost opportunity is smaller than the parser's.
4. `cap/fold-pages` (`cap.clj:39`), **conditional target**: real traversal and
   validation work, including a 5,000-item test in
   `cap_agent_main_test.exs:168-180`. Admit it only with pure `fetch` and
   `step` callbacks, frozen page inputs, and retained failure cases. The
   unrestricted public function is not replay-judgeable from today's fixtures.

`cap/unwrap!` and `result/*` are pure but too small to justify a model search
without a measured aggregate bottleneck. The contract validators use a Kernel
tool and need a frozen contract/input fixture; the fixed contract is part of
the judgment. No shortlisted helper currently has a measured per-helper cost
or a counted replay corpus, so b02 should first establish those inputs and a
hand-optimized comparator, as its program backlog already requires.

## Proposed backlog entries

- `self-improvement/b09` (`change`, after b01): retain a no-model shipped-helper
  corpus with frozen bundle, exact inputs, outcome hash, error outcomes, and a
  per-function/per-branch execution index. Include withheld property inputs.
  This is needed before b02 can claim coverage or byte-equal judgment.
- `self-improvement/b10` (`measure`, after b09): obtain paired isolated-run
  Kernel usage and elapsed cost for the four shortlisted helpers, with a
  hand-written optimization baseline. Freeze the useful-gain threshold before
  any model-proposed edit.
- `self-improvement/b11` (`explore`, after b09): characterize model-visible
  agent correction paths using the retained failure fixtures from
  prelude-search/004. A changed request requires live evaluation under a
  separate authorized budget; do not treat fixture misses as equality.

## Runtime wants

- Per-public-helper invocation and branch identifiers in private trace data,
  plus evaluation steps, peak/allocated heap, and `duration_ms` attributable to
  that invocation. The inventory had to use source call sites and aggregate
  run usage instead of counted executions or cost.
- Private retention of the exact run input with the frozen bundle and result
  hash. Prelude-search's reconstruction needed sidecars in 000 and private
  inspection records in the later lab; the shipped-helper fixture has no
  comparable indexed corpus.
- A no-provider re-execution path that compares strict outputs **and failure
  envelopes** for one shipped helper across a candidate bundle. Existing
  request-hash replay detects changed model requests but cannot judge them.

No runtime defect was established by this source inventory, so no ordinary
defect issue was opened. H1 remains open and untested.
