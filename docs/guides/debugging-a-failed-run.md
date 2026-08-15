# Debug a failed run with another PTC run

A failed run leaves an immutable capture. A second, ordinary PTC run can
navigate that capture: the boundary failure, the programs the run generated,
their results, the prelude source those programs reached, and that source's
frozen dependencies.

The substrate is structural. It exposes evidence and typed links; it never
selects a suspect or proposes a repair. Reaching a conclusion — or deciding the
evidence is insufficient — stays with the caller, whether that caller is a
deterministic walk or a model.

## What the evidence path looks like

```text
failed immutable run
  -> runs / open / read / follow
  -> generated source and result
  -> referenced prelude source
  -> dependency prelude source
  -> supported diagnosis, or insufficient evidence
```

Each arrow is a typed relationship carried on the evidence item itself, so a
walker never has to guess a filter or reconstruct an identity by hand.

## Capture the evidence a debugger can read

Two artifacts matter, and they carry different authority.

A **canonical trace** is bounded operational evidence: run and evaluation
lifecycle, capability names and outcomes, counts, and a sanitized failure
taxonomy. It contains no prompts, model responses, capability payloads, or
generated source. A workflow's own `fail` value never reaches it; an
unrecognized `kind` is retained only as a one-way fingerprint.

A **private inspection artifact** is an explicit `0600` host development
authority. It adds the frozen component sources, the exact generated programs,
capability arguments and results, model exchanges, prints, and detailed
failures. Read it only through an authorized private sink, and never publish it
alongside a normal trace.

A project document captures both:

```json
"artifacts": {"root": "target/.ptc", "trace": true, "inspection": true, "result": true, "envelope": true}
```

The equivalent low-level form is `--trace-dir` plus `--inspect`. See
[Running and debugging](running-and-debugging.md) for every switch and
[Project configuration](project-configuration.md) for the artifact layout.

Inspection requires a trace, because every private record is validated against
the canonical run it claims to describe.

## Give the debugger bounded navigation authority

The debugger is an ordinary application. Its host document installs the failed
run's two directories as snapshot providers:

```json
{
  "install": {
    "failed-run-traces": {
      "source": "ptc_private_trace_snapshot",
      "installation_revision": "failed-run-traces-v1",
      "directory": "target/.ptc/traces"
    },
    "debug.nav": {
      "source": "ptc_inspection_snapshot",
      "installation_revision": "failed-run-inspection-v1",
      "directory": "target/.ptc/inspection"
    }
  }
}
```

Use `ptc_private_trace_snapshot` when the captured run wrote a
`.private.jsonl` trace, and `ptc_trace_snapshot` for an ordinary one. Either
way the inspection selection fixes the debugger's data class to
`private_inspection`, so no normal vendor connector can run beside it.

The manifest selects both into one mission and installs the `debug.nav`
prelude:

```json
"missions": {
  "evidence": {
    "components": [
      {"id": "evidence.walk", "path": "evidence.walk.clj", "dependencies": ["debug.nav"]},
      {"library": "debug.nav"}
    ],
    "providers": ["debug.nav", "failed-run-traces"]
  }
},
"providers": {
  "mission": [
    {"name": "debug.nav"},
    {"name": "failed-run-traces", "config": {"expose": false}}
  ]
}
```

`{"expose": false}` keeps the trace selection as the inspection source's
dependency without creating a second navigation namespace.

A snapshot provider names its operations `<alias>.runs`, `<alias>.open`, and
`<alias>.read`, and the shipped prelude binds that conventional alias, so the
inspection selection must be called `debug.nav`. The alternative shipped
surface, `analysis`, binds the stable `analysis-runs`/`analysis-open`/
`analysis-read` names a REPL profile grants; install one or the other, never
both.

## Navigate with debug.nav

`debug.nav` is a thin policy layer over the snapshot provider. It adds no host
authority and no diagnosis policy:

| Call | Purpose |
| --- | --- |
| `(debug.nav/runs options)` | list captured runs, filtered by status, name, tags, or id |
| `(debug.nav/open run-id)` | discover a run's collections, filters, identifiers, and completeness fields |
| `(debug.nav/read run-id options)` | read one bounded native page from a named collection |
| `(debug.nav/follow run-id relationship options)` | follow one typed relationship |

`follow` takes a relationship exactly as an evidence item published it and
reads its declared target collection and filters. It returns the original
relationship beside the unchanged page envelope, so cursors, `omitted_count`,
`snapshot_hash`, truncation, and the relationship's own state all survive the
hop. Caller options may contain only `limit` and `cursor`; a relationship that
is `unavailable` or carries null filters is refused rather than guessed at.

Start from the failure:

```clojure
(let [run (first (get (debug.nav/runs {"status" "error" "limit" 1}) "items"))
      run-id (get run "run_id")
      error (first (get (debug.nav/read run-id {"collection" "execution_errors"}) "items"))]
  {"terminal_reason" (get run "terminal_reason")
   "relationships" (map #(get % "rel") (get error "relationships"))})
```

## Follow the typed links

Relationships are declared with a semantics that is deliberately narrower than
their name:

| Relation | Semantics | Reaches |
| --- | --- | --- |
| `boundary_failure` | causation | the failing activity record |
| `child_evaluations` | nesting | evaluations parented by the failing one |
| `direct_boundary_producer` | causation | the child evaluation that produced the boundary value |
| `generated_source` | association | that evaluation's generated program |
| `producing_turn` | association | the model turn that emitted a program |
| `referenced_prelude_source` | association | a component a program actually called |
| `dependency_prelude_source` | dependency | a component's frozen direct dependencies |

`causation` requires proof: a workflow boundary failure, or a direct-return
origin marker plus exact equality with the retained child result. A parent edge
alone is never promoted to causation. When a run fails by calling `fail`
directly, no direct producer is proven, and that relation honestly reports
`incomplete` instead of pointing at the most likely child.

Generated entries embedded in `turns` carry the same relationships as their
`generated_sources` item, so a walker that starts from a model turn can follow
evidence without a second exact read.

From a generated program, one hop reaches the component it called, and each
further hop reaches that component's frozen dependencies:

```clojure
(let [referenced (first
                   (filter #(= (get % "rel") "referenced_prelude_source")
                           (get generated "relationships")))
      entry (first (get (get (debug.nav/follow run-id referenced {}) "page") "items"))]
  (get entry "source"))
```

A component ID alone is not an occurrence identity: the same component can be
frozen into the workflow environment and into several missions with different
dependency edges. Every dependency filter therefore repeats its `environment`
and, for a mission occurrence, its `mission_name`. The edges come only from a
frozen prelude graph that satisfies its complete positional contract, so a
malformed or absent graph produces one `incomplete` relation rather than a
guessed edge.

## Read the evidence state honestly

Every relationship carries one of four states, and a walker that ignores them
will report confident nonsense:

| State | Meaning |
| --- | --- |
| `complete` | the host proved this edge; the filters are exact |
| `incomplete` | evidence was truncated or the canonical run is not terminal |
| `ambiguous` | several candidates match; each is offered as its own exact filter |
| `unavailable` | a complete search proved there is no such target |

`unavailable` is a finding, not a gap: it means the evidence exists and
contains no match. `incomplete` means the capture cannot answer. Never follow
a relationship whose filters are null.

Pages carry their own completeness separately from relationship state:
`next_cursor`, `omitted_count`, `truncated`, and `snapshot_hash`. Turn pages
add an `evidence` block reporting canonical completeness, missing model
exchanges, and ambiguity counts.

A diagnosis is supported when every edge it rests on is `complete` and the
pages it read were not truncated. Otherwise the honest report is insufficient
evidence, naming which edge was missing.

## Run the credential-free example

The checked-in example needs no credential or network access. `target/` prices
an order through `orders` → `pricing.tax` → `pricing.rule`; the rule adds 2
while the captured call requires 20, so the run fails. `pricing.discount` is an
unused decoy.

Capture the failed run. It exits nonzero by design:

```console
mix ptc run examples/debug-a-failed-run/target.ptc-project.json
```

Then navigate that capture:

```console
mix ptc run examples/debug-a-failed-run/debugger.ptc-project.json
```

The debugger is a private run, so read its value from the project's result
directory rather than stdout:

```console
cat examples/debug-a-failed-run/debugger/.ptc/results/*.private.json
```

It reports the boundary failure, the exact generated program including the
required total, and the frozen dependency closure with each component's source:

```json
{
  "boundary_kind": "workflow_failed",
  "dependency_closure": ["orders", "pricing.tax", "pricing.rule"],
  "evidence_states": ["complete", "incomplete", "unavailable"],
  "generated_source": "(let [quote (orders/place data/params)] (if (= (get quote \"total\") 120) quote (fail {:kind \"order-total-mismatch\"})))",
  "terminal_reason": "explicit_failure"
}
```

The decoy never appears, because the walk follows frozen dependency edges
rather than the manifest's component list. `evidence_states` includes
`incomplete` because this run failed by calling `fail`, so no direct boundary
producer was proven — a fact the report keeps rather than hides.

The generated program requires 120, the reached rule adds 2, and the closure
contains exactly one component that decides the added amount. That is a
supported diagnosis. Confirming it is a separate step: edit
`target/pricing.rule.clj`, remove the stale capture, and rerun the target.

## Let a model do the walking

The same mission works for an agent. Keep `debug.nav` as the mission's only
domain authority and let the shipped agent loop drive it:

```json
"workflow": {
  "components": [{"library": "agent.main"}],
  "entry": "agent.main/run"
},
"missions": {
  "evidence": {
    "components": [{"library": "debug.nav"}],
    "providers": ["debug.nav", "failed-run-traces"]
  }
},
"providers": {
  "workflow": [{"name": "deepseek"}],
  "mission": [{"name": "debug.nav"}, {"name": "failed-run-traces", "config": {"expose": false}}]
}
```

Supply the task and turn budget through input, and require a result contract
with an explicit decision so an abstention is a first-class answer rather than
an empty diagnosis slot:

```json
"input": {
  "value": {
    "task": "Explain why the captured failed run did not produce its required value. Cite the exact evidence you read. If the evidence does not identify one faulty component, say so and name what is missing.",
    "agent": {"max_turns": 8}
  }
},
"contracts": {"result_schema": {"path": "report.schema.json"}}
```

Two limits are worth knowing before trusting such a run.

A model that can still call evidence tools may keep verifying instead of
concluding, even when the decisive comparison is already in its context.
Budget for that, and treat an exhausted turn limit as an unfinished
investigation rather than an absent cause.

A contract-valid report is not a correct one. A forced diagnosis slot invites
an invented explanation. Where the claim is mechanically testable, test it:
run the proposed change against host-owned cases before believing it. The
model may diagnose and author; whether a change is accepted stays with the
host.

## Scope and limits

This substrate is structural navigation, not automatic debugging:

- it reports evidence and typed links, and never selects a diagnosis;
- the walk follows dependency edges only — not callers, data flow, or
  capability side effects;
- it assumes a captured failure with retained generated source; a run that
  produced no program leaves nothing to walk;
- host validation, not a model report, decides whether a repair is accepted.

The one shape it demonstrably covers is a complete single-call failure whose
relevant source lies inside the called component's dependency closure.
Discovery outside that closure, and repair of nonlocal or weakly specified
defects, are not established.

## Next steps

- [Kernel REPL](kernel-repl.md) covers `private-run-analysis-v1` for
  interactive or unattended investigation of the same capture.
- [TraceLog contract](../trace-log-contract.md) defines every collection,
  filter, relationship, and completeness field.
- [Running and debugging](running-and-debugging.md) documents artifacts,
  diagnostics, and the transcript command.
- [Components and preludes](components-and-preludes.md) explains component
  identity, dependencies, and the shipped libraries.
