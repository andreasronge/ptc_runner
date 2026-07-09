# Lisp Kernel — Eval Domains and Prelude Specialization Discussion

**Status:** discussion notes, not an autonomous implementation brief.

This document captures the current thinking on evaluating domain-specific
preludes for the Lisp kernel. It is deliberately not named `autonomous-*` and
does not define a ready-to-run build sequence. The purpose is to sharpen the
research questions, requirements, and pilot shape before turning any part of
this into a preregistered experiment or implementation plan.

## Core Question

Can a domain-specific prelude improve an agent's ability to write useful
PTC-Lisp programs without turning into benchmark memorization or
query-specific dispatch?

The useful distinction is:

- **Healthy specialization:** reusable domain mechanics such as interval
  arithmetic, graph traversal, typed table aggregation, schema validation,
  pagination, normalization, and certificate checks.
- **Unhealthy overfit:** task IDs, fixture IDs, answer literals, expected
  query patterns, hidden file names, benchmark-specific dispatch tables, or
  policy that only works because the eval queries are known.

Some overfit is acceptable only when the workload is explicitly fixed and the
claim is scoped that way. It is not acceptable to report that as general
domain capability.

## Current Take

The public benchmark research points in the right direction: use existing
benchmarks as design references, not as the final hidden eval substrate.

The strongest PTC-native eval shape is:

```text
initial state/data
+ approved tools
+ model-authored PTC-Lisp program
+ structured return value
+ deterministic validator
+ turn-log metrics
```

The main value to borrow from benchmarks is task shape, split design, oracle
style, and anti-leakage discipline. The final eval cases should be freshly
generated or freshly assembled so that a prelude can encode mechanics but
cannot memorize case facts.

## Benchmark Patterns Worth Borrowing

### Stateful Tool Orchestration

AppWorld, ToolSandbox, and tau-bench-style tasks are useful references because
they evaluate final state rather than exact wording or a single action
sequence. They are probably too large for the first pilot, but they are the
right north star for later stateful domains.

Useful pattern:

- task instruction plus initial app/database state;
- approved API/tool surface;
- multiple valid trajectories;
- final-state validator;
- collateral-damage checks.

### Structured Retrieval

STaRK, ToolQA, BEIR, and mixed text/table RAG benchmarks are useful because
they separate query handling from evidence retrieval and expose qrels,
entity IDs, or exact answer sets.

Useful pattern:

- graph/relational/text data separated from queries;
- train/validation/test or human-query splits;
- set-based answer validation;
- noisy or incomplete retrieval surfaces.

### Deterministic Domain Mechanics

Natural Plan, TCP, TRD, NLGraph, DataBench, DABench, Spider/BIRD, and
ProofWriter-style datasets are especially relevant because the validator can
usually be deterministic.

Useful pattern:

- generated hidden cases;
- exact solvers or certificate validators;
- difficulty levels;
- same mechanics over unseen data;
- paraphrase and task-family holdouts.

## Candidate Pilot Domains

### 1. Calendar and Time Intervals

This should likely be the first pilot domain.

Why:

- hidden data is easy to generate;
- validators can be exact;
- the domain prelude value is clear: interval algebra, timezone handling,
  recurrence expansion, free/busy intersection, and schedule construction;
- counterfactual data mutation is straightforward.

Possible query families:

- interval overlap;
- free/busy intersection;
- recurrence expansion;
- timezone conversion;
- schedule construction under constraints.

Risk:

- natural-language parsing can become the real task if the tool/data contract
  is too loose;
- a full scheduling solver in the prelude may collapse the task into selecting
  the right helper.

### 2. Graph and Topology

This is probably the strongest anti-overfit domain.

Why:

- unlimited hidden graphs can be generated;
- oracle checks can validate certificates rather than exact prose;
- task families are crisp and measurable;
- it is easy to distinguish mechanics from memorized answers.

Possible query families:

- reachability;
- shortest path;
- connected components;
- cycle detection;
- topological order;
- bipartite matching or max-flow after the simpler tasks work.

Risk:

- if the prelude exports full solvers for every task, the model contribution
  may become mostly parser/selector behavior. That may still be valuable, but
  the claim must say so.

### 3. Table and Numeric Records

This is a natural third domain because it exercises PTC-Lisp's data
transformation strengths.

Why:

- validators can check exact counts, sets, rankings, and numeric tolerances;
- generated tables allow hidden-data splits;
- tool-call traces reveal whether the prelude reduces duplicate collection,
  bad pagination, and fragile ad hoc filtering.

Possible query families:

- filter/count;
- group/aggregate;
- join/link records;
- sort/rank/top-k;
- numeric unit or scale normalization.

Risk:

- too close to existing commerce/demo shapes if the fixtures reuse similar
  vocabulary or expected operations;
- public table benchmarks can leak answer patterns.

### 4. Nested JSON Transformation

This is a strong follow-up once the harness is stable.

Why:

- PTC-Lisp naturally expresses transformations;
- exact final-document equality is a clean oracle;
- schema validation can be separated from semantic correctness.

Possible query families:

- nested path update;
- array insert/delete/move;
- merge and canonicalization;
- schema-directed extraction;
- JSON patch generation.

Risk:

- schema-valid output can still be semantically wrong;
- generated tasks need enough variety to avoid path-template memorization.

## Experimental Conditions

For a small pilot, compare at least three conditions:

- **Generic baseline prelude:** domain-blind core mechanics only.
- **Domain-specific prelude:** reusable mechanics for one domain, no case facts.
- **Overfit/control prelude:** intentionally query- or fixture-aware, used only
  as a calibration cell to show what overfit looks like in traces.

Keep model, tool budget, retry policy, validator, data, and run order identical
across conditions.

## Split Design

A useful first full pilot could be 3 domains x 50 tasks, but the first
iteration should probably be smaller: one domain, around 30 tasks, enough to
test whether the trace metrics separate real mechanics from prompt-only
improvements.

Recommended split per domain:

| Split | Purpose |
| --- | --- |
| Dev/seen | Allow normal prelude development. |
| Paraphrase holdout | Same data and mechanics, different language. |
| Task-family holdout | New operation family after prelude freeze. |
| Unseen-data holdout | Same query families over freshly generated fixtures. |
| Adversarial/noisy-tool | Pagination shuffle, irrelevant records, duplicate data, missing optional fields. |

Freeze the domain prelude before generating or revealing hidden unseen-data
cases.

## Structured Return Contract

Tasks should require a structured PTC-Lisp return rather than free prose.
Example shape:

```clojure
(result
  :answer_type "sorted_ids"
  :ids [...]
  :evidence [...]
  :constraints_checked [...])
```

Exact shape should vary by domain, but validators should prefer:

- canonical JSON equality;
- set equality over IDs;
- sorted ID lists;
- numeric value with unit/scale tolerance;
- interval constraint satisfaction;
- graph certificate validation;
- final-state diff;
- executable unit tests.

For multiple-valid-answer tasks, grade certificates instead of exact strings:
a graph path must be valid and optimal, a topological order must satisfy all
edges, and a calendar schedule must satisfy all interval constraints.

## Prelude Requirements

A domain prelude may contain:

- pure reusable algorithms;
- typed constructors and normalizers;
- tool wrappers;
- pagination and deduplication helpers;
- domain validators or certificate builders;
- schema or relation traversal helpers;
- concise domain vocabulary that belongs to the tool/domain itself.

A domain prelude must not contain:

- task IDs;
- fixture IDs;
- hidden file names;
- expected answer literals;
- hashes of hidden data;
- query-specific dispatch;
- benchmark-domain hints in generic `agent.*` prompts;
- public benchmark examples copied as hidden eval content.

This aligns with the repo's domain-blind prompt rule: generic system prompts
and agent configurations must not contain benchmark-domain hints. Domain tool
descriptions and explicitly selected domain preludes may reference their own
domain, but the claim must be scoped accordingly.

## Trace Metrics

Correctness alone is not enough. The logs should show whether the prelude is
used and whether it changes the shape of work.

Record at least:

- correctness;
- valid PTC program rate;
- turns;
- tokens;
- tool calls;
- unique tool-call argument hashes;
- duplicate calls;
- retries;
- failure category;
- exported prelude functions invoked;
- trace write/drop counts;
- unsafe debug artifact status.

Useful signs of a valuable prelude:

- fewer duplicate tool calls;
- fewer retries;
- better valid-program rate;
- cleaner evidence/certificate returns;
- lower variance across paraphrases;
- transfer to unseen data and task-family holdouts.

Warning signs:

- high correctness only on dev/seen tasks;
- no invocation of domain helper exports;
- brittle failure on counterfactual data mutation;
- answer-like constants in prelude source;
- query-family dispatch rather than reusable mechanics.

## Anti-Overfit Checks

Minimum controls:

- freeze preludes before hidden-data generation;
- use salted fixture IDs per split;
- statically scan preludes for forbidden constants;
- mutate underlying data while preserving query shape;
- separate paraphrase, task-family, and unseen-data holdouts;
- randomize pagination order and page sizes;
- inject irrelevant records and duplicates;
- run an ablation where helper behavior remains but docstrings are removed, or
  where key helpers are removed, to separate prompt wording from executable
  mechanics.

## Open Discussion Topics

1. Should the first pilot be calendar-only, or should it immediately include
   graph and table tasks to test cross-domain behavior?
2. How much algorithmic power should a domain prelude expose before the eval is
   no longer testing model-authored programs in a meaningful way?
3. Should the overfit/control prelude be deliberately bad and obvious, or
   should it model the subtle overfit risks we actually expect?
4. What exact line separates allowed domain vocabulary from disallowed prompt
   hints?
5. Should prelude usage be scored only by trace invocation, or should helper
   calls require useful downstream effect to count?
6. Should hidden fixtures be generated inside the eval harness, checked into
   encrypted bundles, or produced by a separate sealed generation step?
7. Which metrics should be primary for a preregistered claim: correctness,
   tool-call efficiency, retry reduction, transfer to unseen data, or a
   composite?
8. How should public benchmark tasks be cited when we borrow task shape but do
   not reuse the data?

## Likely Next Step

The missing runtime channel is now registered as S21, with an autonomous
implementation brief:
[`autonomous-s21-inner-eval-domain-prelude.md`](autonomous-s21-inner-eval-domain-prelude.md).
S21 is deterministic infrastructure only. It separates the trusted loop bundle
from a role-authorized model-callable inner bundle, keeps inner runtime
authority nil, projects only callable inner exports, and adds separate
provenance plus runtime invocation counts. It does not run the calendar pilot.

Before implementing the calendar pilot, define the PTC-native eval contract:

- case schema;
- fixture generator interface;
- reference solver interface;
- validator return shape;
- split policy;
- prelude anti-leak rules;
- trace metric report;
- minimum report fields for a claim.

Once that contract is written, the safest first implementation target is a
small calendar/time pilot with generic, domain-specific, and overfit/control
prelude conditions.
