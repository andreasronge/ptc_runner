# Debug-navigation reference

This is the complete frozen-evidence graph and `debug.nav` contract.

A failed
run leaves an immutable capture. A second PTC run can
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
  -> runs / open / read / counters / follow
  -> generated source and result
  -> referenced prelude source
  -> dependency prelude source
  -> supported diagnosis, or insufficient evidence
```

Each arrow is a typed relationship carried on the evidence item itself, so a
walker never has to guess a filter or reconstruct an identity by hand.

## Capture the evidence a debugger can read

Two artifacts matter, and they carry different authority.

A **trace** is bounded operational evidence: run and evaluation
lifecycle, capability names and outcomes, counts, and a sanitized failure
taxonomy. It contains no prompts, model responses, capability payloads, or
generated source.

A failed capability attempt records its closed envelope `kind` and `reason`
on the `capability-stopped` event. An unrecognized envelope atom is retained
only as a one-way fingerprint.

A workflow's own `fail` value never reaches the public trace as prose. An
unrecognized `fail` kind is retained only as a one-way fingerprint on
`run-stopped`; that taxonomy is separate from the capability-stopped class.

A **private inspection artifact** is an explicit `0600` host development
authority. It adds the frozen component sources, the exact generated programs,
capability arguments and results, model exchanges, prints, and detailed
failures. Raised capability callbacks can include their bounded exception
message and formatted stacktrace here, but never in the correlated trace.
Those strings may contain secrets or local paths and cannot be reliably
redacted. Read the artifact only through an authorized private sink, and never
publish it alongside a normal trace.

A project document captures both:

```json
"artifacts": {"root": "target/.ptc", "trace": true, "inspection": true, "result": true, "envelope": true}
```

The equivalent low-level form is `--trace-dir` plus `--inspect`. See
[Running and debugging](cli.md) for every switch and
[Project configuration](project-files.md) for the artifact layout.

Inspection requires a trace, because every private record is validated against
the run it claims to describe.

### Publish one conversation with ptc transcript

For one certified conversation, avoid a REPL. Create a sibling directory
first; do not write into `/tmp` or into the project that holds the traces:

```console
mkdir -p out
ptc transcript RUN_ID \
  --traces .ptc/traces \
  --inspection .ptc/inspection \
  --private-unattended \
  --private-output out/conversation.private.json
```

`--private-output` names a new owner-only file. Its parent must already exist
and be reached without a symbolic link — on macOS `/tmp` is a symlink, so
`/tmp/out.json` is refused. The parent must also be physically separate from
`--traces` and `--inspection`: no directory may equal, contain, or be
contained by either of the others. A file in the current directory fails when
that directory contains `--traces`. A sibling directory, as above, satisfies
both rules. A rejection names the two conflicting switches and their physical
relationship, and discloses no path.

`RUN_ID` must be a canonical PTC command run reference. The command then
captures exactly `RUN_ID.jsonl` or `RUN_ID.private.jsonl` under `--traces` and
`RUN_ID.ptcins` under `--inspection`. It does not list those
directories, so unrelated, malformed, or oversized history cannot reject a
valid selected pair. Selected files still keep their individual source,
record, retained-memory, heap, deadline, and result ceilings. Both trace
suffixes present, a missing selected file, a symlink, an embedded identity
that does not match `RUN_ID`, a correlation mismatch, or malformed,
unsupported, changed, or oversized selected evidence fails closed. A refusal
names a stable `transcript/` diagnostic and does not echo `RUN_ID` or a
filesystem path. Whole-directory analysis snapshots remain a separate
contract: they still inventory every canonical member.

## Choose the smallest evidence authority

The four navigation paths answer different questions. Pick one before opening
private payloads:

| Need | Use | Authority and lifetime |
| --- | --- | --- |
| find candidate runs in a large artifact root | `private-run-catalog-v1` and `analysis/catalog` | one immutable metadata-only generation; no payload admission |
| publish one complete model conversation | `ptc transcript RUN_ID` | one exact correlated pair and one new owner-only result file |
| ask several private questions about up to sixteen runs | `private-run-analysis-v2` with repeated `--run` | one immutable selected-set session with `analysis/*` |
| make a repeatable debugger application or agent | install snapshots and select `debug.nav` | the manifest's fixed mission authority and typed relationship walk |

Catalog discovery and selected analysis are separate commands. For example,
page the first twenty admissible rows, then carry only chosen `run_id` values
into a new session:

```console
ptc repl --profile private-run-catalog-v1 \
  --resource traces=.ptc/traces \
  --resource inspection=.ptc/inspection \
  --private-unattended --format jsonl \
  -e '(analysis/catalog {"state" "admissible" "limit" 20})'

ptc repl --profile private-run-analysis-v2 \
  --run cmd-00000000000000000000000001 \
  --run cmd-00000000000000000000000002 \
  --resource traces=.ptc/traces \
  --resource inspection=.ptc/inspection \
  --private-unattended --format jsonl \
  -e '(analysis/open "cmd-00000000000000000000000001")'
```

If the catalog has more candidates than one selected set can hold, start a
second `private-run-analysis-v2` command with a later batch. Each command
re-verifies only its own explicit references and has independent source,
index, heap, result, handle, call, and session bounds. A catalog digest binds
only paging inside its discovery generation; it never crosses as an admission
token. `analysis/open` opens an already-admitted payload and cannot add a run
to the session.

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

A snapshot provider names its operations `<alias>.runs`, `<alias>.open`,
`<alias>.read`, and `<alias>.counters`, and the shipped prelude binds that
conventional alias, so the inspection selection must be called `debug.nav`. The
alternative shipped surface, `analysis`, binds the stable `analysis-runs`/
`analysis-open`/`analysis-read`/`analysis-counters` names a REPL profile
grants; install one or the other, never both.

## Navigate with debug.nav

`debug.nav` is a thin policy layer over the snapshot provider. It adds no host
authority and no diagnosis policy:

| Call | Purpose |
| --- | --- |
| `(debug.nav/runs options)` | list captured runs, filtered by status, name, tags, or id |
| `(debug.nav/open run-id)` | discover a run's collections, filters, identifiers, and completeness fields |
| `(debug.nav/read run-id options)` | read one bounded native page from a named collection |
| `(debug.nav/counters filters)` | return trace counters for a filtered run cohort |
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
| `incomplete` | the capture cannot answer, so no claim is made |
| `ambiguous` | the target is not uniquely determined; see below |
| `unavailable` | a complete search proved there is no such target |

`incomplete` is the honest catch-all for "not established": a non-terminal or
truncated run, producer evidence that was cut off, an absent or
malformed frozen prelude graph, or a program whose prelude-call analysis was
never captured. It does not distinguish those causes, and a null-filtered
`incomplete` relation cannot be followed at all.

`unavailable` is a finding rather than a gap: the evidence exists and contains
no match.

`ambiguous` means different things by relation. Ambiguous boundary-producer
candidates are emitted as several separate relations, each with its own exact
filter, rather than one unbounded scan. An ambiguous prelude or turn
association is a single relation whose one filter matches more than one item;
following it returns them all, and choosing between them is the caller's
problem.

Never follow a relationship whose filters are null.

Pages carry their own completeness separately from relationship state:
`next_cursor`, `omitted_count`, `truncated`, and `snapshot_hash`. Turn pages
add an `evidence` block reporting canonical completeness, missing model
exchanges, and ambiguity counts.

A diagnosis is supported when every edge it rests on is `complete` and the
pages it read were not truncated. Otherwise the honest report is insufficient
evidence, naming which edge was missing.

### What the completeness fields do and do not claim

A conversation's `complete?` is the conjunction of three specific facts: the
run reached a terminal event with no dropped events, no expected
model exchange is missing, and no turn or generated-source association is
ambiguous. It is a statement about the reconstruction, not a promise that every
field of every record is present. `ptc transcript` refuses to write a file at
all unless `complete?` holds, so that field is always `true` in a published
transcript; read it over `/api/analysis/runs/{id}/conversation`, which applies
no such gate, when you need it to be able to say no.

The refusal names which of the three facts failed and by how much, because they
have different next actions. `transcript/ambiguous_evidence` means nothing is
missing: the run is complete and every expected exchange was
captured, but some turn or generated-source association resolves to more than
one predecessor. Re-running does not help; read the ungated route instead.
`transcript/incomplete_evidence` means the trace is not terminal or
dropped events, or the inspection artifact does not carry every exchange the
trace expects — both facts about the capture rather than the reconstruction.

### Reaching the ungated reconstruction

`/api/analysis/runs/{id}/conversation` is served by `ptc viewer` and needs the
project's private grant. Four separate decisions withhold it — two about the
project, two about the run — and the Viewer's private routes answer for each by
name, so the reason body is the next action rather than a bare status:

| answer | cause | next action |
| --- | --- | --- |
| `404 inspection_not_configured` | the project records no inspection artifact | set `artifacts.trace` and `artifacts.inspection` and run again |
| `404 inspection_not_private` | the artifact exists, this Viewer was not granted it | set `viewer.private` and Refresh the Runs list; nothing needs re-running |
| `404 inspection_run_not_recorded` | the Viewer reads private evidence, this run recorded none | run the project again, now that `artifacts.inspection` is set |
| `404 inspection_run_mismatch` | the Viewer is pinned to a different run's artifact | start the Viewer for this run |

Every other answer is a transport status with prose, not a reason code: the
route reports a source that is unavailable, changed, oversized, or malformed as
the failure it is rather than as a setting the reader could change.
`/api/analysis/runs/{id}/preludes` answers on the same terms.

`omitted_count` is pagination: how many selected items this page did not
return. It never reports evidence withheld by policy. A source grant that
withheld trace files of the other kind reports that separately, as
`excluded_private_trace_files` or `excluded_sanitized_trace_files` on a run
listing or counters query.

Damaged evidence is also separate from pagination and policy exclusion.
`list_runs` and `counters` carry the same bounded `isolation` summary with
exact component, source, known-run, and reason totals plus capped examples.
The Viewer renders that object as a damaged-source notice without hiding the
source-kind exclusion notice. Opening a grant-visible run claim that belongs
only to an isolated component answers `422 run_isolated`; a direct trace
capture that exceeds its retained-memory ceiling answers
`413 Trace source retained size exceeded`.

### Join on correlation ids, never on sequence numbers

A transcript turn and a trace event live in different sequence
spaces. Turn `request_sequence` orders records inside the inspection snapshot;
canonical `sequence` orders the run's event stream. Turn 1 reporting request
sequence 12 says nothing about trace event 12, which is an unrelated
record. Correlation identifiers — `capability-5`, `mission-evaluation-9` — are
the same in both artifacts and are the only sound join key.

## Run the credential-free example

The checked-in example needs no credential or network access. `target/` prices
an order through `orders` → `pricing.tax`, which branches to `pricing.base` and
`pricing.rule`. The rule adds 2 while the captured call requires 20, so the run
fails. `pricing.discount` is an unused decoy.

Capture the failed run. It exits nonzero by design:

```console
ptc init debug-a-failed-run --example debug-a-failed-run
ptc run debug-a-failed-run/target.ptc-project.json
```

Then navigate that capture:

```console
ptc run debug-a-failed-run/debugger.ptc-project.json
```

The debugger is a private run, so read its value from the project's result
directory rather than stdout:

```console
cat debug-a-failed-run/debugger/.ptc/results/*.private.json
```

It reports the boundary failure, the exact generated program including the
required total, and the frozen dependency closure with each component's source:

```json
{
  "boundary_kind": "workflow_failed",
  "closure_complete": true,
  "dependency_closure": ["orders", "pricing.tax", "pricing.base", "pricing.rule"],
  "evidence_states": ["complete", "incomplete", "unavailable"],
  "generated_source": "(let [quote (orders/place {\"subtotal\" 100})] (if (= (get quote \"total\") 120) quote (fail {:kind \"order-total-mismatch\"})))",
  "terminal_reason": "explicit_failure"
}
```

The decoy never appears, because the walk follows frozen dependency edges
rather than the manifest's component list. Both branches under `pricing.tax`
do appear: a walk that followed one edge per component would silently drop the
other, and might drop the defective one.

Two fields keep the report honest about its own coverage. `closure_complete` is
false whenever the walk stopped at an edge the host could not prove or hit its
own bound, so a partial closure is never mistaken for the whole one.
`evidence_states` includes `incomplete` here because this run failed by calling
`fail`, so no direct boundary producer was proven.

The generated program is what makes this diagnosis supported rather than
plausible. It carries both values the check ran on — subtotal 100 and required
total 120 — so the reached sources settle the question: `pricing.base` returns
the subtotal unchanged and `pricing.rule` adds 2, and no other component in the
closure decides the amount.

This is worth noticing, because the same example with `data/params` in the
generated program instead of the literal order is genuinely insufficient
evidence. The capture would still show the check and the whole source chain,
but not the value checked, and a wrong input would then be indistinguishable
from a wrong component. A live model given that earlier capture correctly
refused to name a component for exactly this reason. What a run generates is
what a later run can prove.

Confirming the diagnosis is a separate step: edit `target/pricing.rule.clj`,
remove the stale capture, and rerun the target.

## Let a model do the walking

The same mission works for an agent. `debugger-agent/` in the example replaces
the deterministic walk with the shipped agent loop over the same authority. It
is the one part of the example that needs a credential, named on the command
line so no environment file has to live inside the example directory:

```console
ptc run debug-a-failed-run/debugger-agent.ptc-project.json --env-file .env
```

Keep `debug.nav` as the mission's only domain authority and select a model into
the workflow:

```json
"workflow": {"components": [{"library": "agent.main"}], "entry": "agent.main/run"},
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

Selecting an inspection snapshot fixes the run's class to `private_inspection`,
so the model installation must declare
`"accepts_data": ["normal", "private_inspection"]`. That declaration permits
captured private evidence, including generated source, frozen component source,
and failure detail, to be sent to a model vendor. Enable it only when intended.

Name the mission that holds the evidence, and require a result contract with an
explicit decision so an abstention is a first-class answer rather than an empty
diagnosis slot:

```json
"input": {"value": {"task": "...", "agent": {"max_turns": 14, "mission": "evidence"}}},
"contracts": {"result_schema": {"path": "report.schema.json"}}
```

The agent loop runs inside one workflow evaluation, so `workflow_timeout_ms`
must cover every model turn, not one call. Its installed default of 30 s ends a
multi-turn investigation mid-flight; the example raises the host ceiling and
the manifest together.

### What to expect

Four limits showed up repeatedly while this example was built against a live
model, and all four are worth designing around.

**Traversal beats budget.** Told only to "read the boundary error", the model
looped on the public `activity` collection for eight turns and never reached
`execution_errors`. Naming the collections and the intended order — API
vocabulary, not answer hints — moved it onto the typed relationships
immediately. Generic navigation authority does not imply a generic traversal
plan.

**Available tools postpone conclusions.** With the evidence chain fully read by
turn 7, the model spent its remaining turns re-reading unrelated collections.
An explicit stopping rule in the task fixed it. Treat an exhausted turn limit
as an unfinished investigation, not an absent cause.

**Report shape is a separate failure mode.** One run reached the right evidence
and returned a report missing a single required field. The bounded contract
feedback named exactly that field; the model resumed exploring instead of
correcting. Stating the contract's fields in the task removed the problem.

**What the run generated decides what the debugger can prove.** Against the
current capture, whose generated program carries both the order and the
required total, the live model traced the branching chain and correctly named
`pricing.rule`, citing that `pricing.base` returns the subtotal unchanged while
the rule adds 2. Against an earlier capture whose program referenced
`data/params` instead of the literal order, the same configuration correctly
returned `insufficient-evidence`, reasoning that without the input value a
wrong input and a wrong component are indistinguishable. Both answers were
right about their own evidence.

**A contract-valid report is still not a correct one.** A third run returned a
confident `diagnosed` report whose evidence lines were all accurate and
genuinely read, and whose conclusion was wrong — it blamed the component that
never calls the unused decoy. Nothing in the substrate could have prevented
that, because the substrate deliberately does not choose a diagnosis. Treat a
single sample as one opinion.

That is the reason this layer stops where it does. Where a claim is
mechanically testable, test it: apply the proposed change and run it against
host-owned cases before believing it. The model may diagnose and author;
whether a change is accepted stays with the host.

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

- [Kernel REPL](repl.md) covers `private-run-analysis-v2` for
  interactive or unattended investigation of the same capture.
- [TraceLog and run-analysis reference](../maintainers/trace-log-contract.md) defines
  every collection,
  filter, relationship, and completeness field.
- [Running and debugging](cli.md) documents artifacts,
  diagnostics, and the transcript command.
- [Components and preludes](component-contracts.md) explains component
  identity, dependencies, and the shipped libraries.
