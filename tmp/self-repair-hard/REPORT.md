# Harder self-repair experiments

Date: 2026-08-15

Artifact root: `/private/tmp/ptc-self-repair-hard-20260815-a`

## Question

Can the unchanged debugger used for the original claim-submission example locate
and repair unrelated prelude bugs, including a fault hidden behind a transitive
prelude call? Does the result depend on Luna?

## Fixtures

| Fixture | Domain | Fault | Why it is harder |
| --- | --- | --- | --- |
| `inventory` | reservations | `inventory/reserve` returns `id` instead of `reservation_id` | Different domain and a typed output-contract failure |
| `dependency` | order tax | generated code calls `orders/place`, but the bug is `pricing.tax/add-fixed` adding 2 instead of 20 | Faulty function is absent from generated source; diagnosis must traverse the prelude dependency |
| `semantic` | temperature conversion | shape-correct function uses `+ 30` instead of `+ 32` | Signature passes; only the application result invariant exposes the error |

The first Luna pass used the original, unchanged debugger manifest and prompt
from `tmp/self-repair-obvious/debugger/ptc-context.json`.

## Target failures

| Fixture | Run | PTC finding |
| --- | --- | --- |
| inventory | `cmd-0hxq8hwsv30t56x6gx0cnh49ag` | Turn feedback contains `prelude_contract_error` for missing `reservation_id`; captured source returns `{"id" sku}` |
| dependency | `cmd-0820mq6jdtry1xwpr4kcfzpykw` | Generated source calls only `orders/place`; run metadata proves `orders` depends on `pricing.tax`; captured dependency source contains `(+ subtotal 2)` |
| semantic | `cmd-6dvf5ds17q5p2ccc15gm45q5xc` | First call returns a shape-correct value, then reconstructed feedback reports the result-schema `const` violation; captured source contains offset 30 |

All findings above were read through `mix ptc repl --profile
private-run-analysis-v1`; the console envelopes were not treated as sufficient
diagnostic evidence.

## Debugger results

| Model/interface | Inventory | Dependency | Semantic |
| --- | ---: | ---: | ---: |
| Luna, unchanged context | correct, 2 turns / 6.2 s | correct, 9 turns / 23.8 s | correct, 6 turns / 23.5 s |
| DeepSeek, unchanged context | correct, 2 turns / 43.0 s | **failed**, 12-turn limit / 151.1 s | correct, 10 turns / 207.5 s |
| DeepSeek, direct dependency sources included | not rerun | correct, 9 turns / 161.0 s | not rerun |

Correct means the report named the exact component and function, preserved the
component surface, and emitted the intended complete replacement source.

The Luna repair runs were:

- inventory: `cmd-5abxpg19jzq9tfwpw0v4ypqe3f`
- dependency: `cmd-1gsb6r4kqa3h6kb05yd9grfh3z`
- semantic: `cmd-20927sjwpzedv31bptgj1th691`

The DeepSeek runs were:

- inventory: `cmd-6q4qcgtrcjn65grr1mk8rs83bp`
- dependency baseline failure: `cmd-2hxj82ja7e7kq7p9n8nab9s3my`
- semantic: `cmd-4evndxdrypgm8t8dwjf0qv73jg`
- dependency-context follow-up: `cmd-54gsmez77fs4sbd0656hnd37ew`

The failed DeepSeek dependency trace is an interface failure more than a
reasoning failure. PTC reconstructed twelve attempted programs: after the
coarse call exposed `orders` and its dependency graph, DeepSeek spent the
remaining budget trying several unsupported shapes for
`debug.evidence/read`, including nested `filters`, keyword keys, and filter
arrays. It never obtained the `pricing.tax` source. Luna also made two avoidable
API-discovery errors in this fixture but recovered within nine turns.

The focused follow-up changed only the coarse context: it added sources for the
immediate dependencies of called components. The same DeepSeek model then
returned the exact `pricing.tax/add-fixed` patch. It still over-explored and
used nine turns, so this improves success but does not by itself solve
navigation efficiency.

## Candidate verification

All three Luna proposals passed materialization gates G1-G4. Each materialized
override was then exercised in a fresh target run with both models. PTC opened
all six trace/inspection pairs and reported complete reconstructed evidence,
one LLM call, zero errors, and the expected result:

| Candidate | Luna | DeepSeek |
| --- | --- | --- |
| inventory | `cmd-6nvwgetfmfwmq8gtxesserwtjq` -> `{"reservation_id":"sku-42"}` | `cmd-6v8je6rq5e5scpw8fya6k5vmdn` -> same |
| dependency | `cmd-2krmjqdc7n9ccz8cnten0h7x9p` -> `{"total":120}` | `cmd-14g4v13gr68kzy07p6ysf0550b` -> same |
| semantic | `cmd-7fhsx7pnv7f1qvywnq16svkz9g` -> `{"fahrenheit":212.0}` | `cmd-4sj1e5e73dwcgt3jc8427x1gep` -> same |

## Overfitting assessment

The current approach is not overfit specifically to the claim-submission bug:

- the same prompt and debugger prelude found three different fault classes in
  three unrelated domains;
- it crossed a prelude dependency boundary when the faulty function was not in
  generated source;
- it handled a shape-correct semantic error, not only a runtime or signature
  failure;
- a second model independently produced two repairs, and produced the third
  once the dependency source was present in coarse context.

It is still an optimistic benchmark. Every fixture contains a strong oracle in
documentation, a signature, an explicit invariant, or a result contract. It
does not yet test ambiguity, misleading evidence, stateful failures, multiple
plausible culprits, or a patch that must preserve substantial unrelated logic.

## Friction observed through PTC

1. `debug.evidence/read` advertises filters but models repeatedly guess the
   wrong options shape. The function doc should show one exact call example,
   and protocol feedback should include the corrected shape.
2. Direct called-component context is too narrow for transitive failures.
   Immediate dependency sources are a useful coarse expansion; loading every
   prelude source would not scale.
3. DeepSeek continued exploring after sufficient evidence was already present.
   A compact incident bundle should mark which evidence paths are complete and
   offer explicit next links, for example `inspect_dependency_source` and
   `inspect_boundary_feedback`.
4. The semantic Luna report labeled `target_environment` as `workflow` even
   though the patched component belongs to the mission environment. The
   materializer succeeded because the target mission was explicit, but the
   report vocabulary leaves room for this inconsistency.
5. Materialization checks compile-time and surface invariants, while the fresh
   target rerun checks only the observed scenario. The proposed validation
   plans are prose, not executable held-out checks.
6. Concurrent root `mix ptc run` processes serialize on the Mix build lock.
   This affected experiment wall time but not recorded run duration.

## Recommended next experiments

Run these as a small matrix, stopping after each boundary rather than building
a general graph system first:

1. **Safety/ambiguity:** two plausible faulty preludes and insufficient
   evidence. Expected result is `insufficient-evidence`, never a speculative
   patch.
2. **Misleading decoy:** one visibly suspicious but correct prelude plus a
   subtler actual fault. This tests causal attribution rather than source
   proofreading.
3. **Held-out behavior:** provide one failing input to the debugger, then run
   the materialized candidate against unseen boundary and negative inputs. This
   detects input-specific patches.
4. **Stateful failure:** a prelude whose second call violates an invariant while
   each isolated call looks valid. This tests whether the evidence bundle
   preserves causal sequence.
5. **Preservation pressure:** put several unrelated exports and dependency or
   effect metadata in the faulty component. Reject candidates that repair the
   bug by deleting or widening the surface.

The next implementation increment should be a bounded incident-context
operation, not a broad `debug.nav` namespace yet: return the failed boundary,
its reconstructed feedback, called component sources, immediate dependency
sources, and exact hypermedia-style follow-up call templates. Then repeat only
the failed DeepSeek dependency control. If it still over-explores despite exact
links, a dedicated navigation prelude becomes justified.

## Shipped navigation follow-up

The bounded incident experiment justified the dedicated prelude once it was
implemented as policy over the existing provider operations rather than as new
host authority. The shipped `debug.nav` component exposes `runs`, `open`,
`read`, `latest-failure`, `evaluation`, and `component-source`. A debugger
mission selects the correlated inspection snapshot provider under the
conventional alias `debug.nav`; the component adds no callback or capability.

DeepSeek was rerun against the unchanged transitive target and 12-turn budget
with only `{"library": "debug.nav"}`—no local `debug.context` or
`debug.evidence` components. Run `cmd-34vpvn2pehjzjg60v16y5sbj9c` succeeded in
8 turns with zero protocol errors and returned the exact
`pricing.tax/add-fixed` replacement. The raw-navigation baseline exhausted 12
turns with five protocol errors; the intermediate custom dependency context
succeeded in 9 turns with one protocol error. PTC reported complete turn
evidence for the shipped-prelude run.

The model still reopened the run and followed several evaluation views after
the incident already contained enough evidence. `debug.nav` therefore fixes
reliability and call-shape friction, but does not guarantee minimal reasoning.

## Automatic host loop follow-up

`mix ptc.repair` now consumes one structured `propose-change` result and keeps
authority split as follows:

- the report controls the logical target, component, captured base hash, and
  complete candidate source;
- the host controls the manifest, paths, authoring-run provenance, providers,
  credentials, validation input, and artifact destinations;
- the existing materializer controls G1-G4 and refuses effect widening;
- a fresh `ptc run` controls behavioral success;
- promotion remains a later operator decision.

The real automatic path consumed DeepSeek report
`cmd-34vpvn2pehjzjg60v16y5sbj9c`, materialized candidate source hash
`sha256:7aa75d78b482d4d127b02a082b264b1d9ddf5499220b4715231be8dd42cf4074`,
and launched Luna validation run `cmd-5zdsan4jk6cp12hx3wq7ktnrjz`. PTC opened
that trace and inspection pair and reported one model call, zero errors,
complete evidence, the verified override base/source hashes and authoring run,
and result `{"total": 120}`.

This automates generation-to-candidate and candidate-to-validation, not
installation. Its fresh run proves the selected application scenario only;
the next safety experiment should pass host-owned held-out inputs to
`ptc.repair` and require every run to succeed before a candidate is considered
promotion-ready.
