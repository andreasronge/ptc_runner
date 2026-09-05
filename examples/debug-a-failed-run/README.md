# Let an agent improve its own debugging workflow

A debugging workflow fails because of a bug in its navigation helper — the one
component that reads a failed run's captured evidence before any model call. An
agent reads that failed run, proposes an exact edit to the helper, and the host
checks the edit without a model. The repaired workflow then diagnoses a broken
application, and a second agent proposes a fix that the host validates on inputs
the agent never saw. No checked-in source changes.

One run with Gemini 3.8 Flash took 21 model calls and about nine cents. Model
runs vary, and the script stops at the first failed stage.

## What navigation means here

A failed PTC run leaves an immutable capture: the boundary failure, every
program the run generated, the results those programs returned, and the frozen
source of every component they called. A later run reads that capture through
`debug.nav`, a shipped prelude. Nothing is guessed: each evidence item carries
typed relationships that name their own target collection and exact filter, and
a walk follows them:

```clojure
(let [run (first (get (debug.nav/runs {"status" "error" "limit" 1}) "items"))
      program (first (get (debug.nav/read (get run "run_id")
                                          {"collection" "generated_sources" "limit" 1})
                          "items"))]
  (get program "relationships"))
```

Run against the debugging workflow's own failed run — the capture the improving
agent reads — that returns two relationships:

| `rel` | `state` | What it means |
| --- | --- | --- |
| `producing_turn` | `unavailable` | the host proved there is none; a deterministic program has no model turn |
| `referenced_prelude_source` | `complete` | the component the program called, with an exact filter |

Following the second returns the page of source an investigation starts from.
Following the first fails the program: a relationship proved absent carries no
filter to follow. Reading `state` before following is the whole skill, and it is
the skill the seeded bug lacks.

A **navigation helper** is a small component that performs that walk on the
workflow's behalf and hands the result to the agent as untrusted evidence, so
the model starts from real evidence instead of spending turns discovering it.
`self-debugger/debug.start.clj` holds this one: a single function,
`debug.start/context`, which selects the latest failed run, its first generated
program, and one page of source.

## Why the helper is not a shipped prelude

`debug.nav` is core. It ships in the kernel preludes and its source is frozen.
Which run to open, which program to read, which relationship to start from, and
how much to hand the model is policy, and that differs per workflow. Policy
lives in the workflow's own components, where it stays inspectable, overridable,
and — here — improvable. A helper promoted into the core prelude would be frozen
source with nothing for an agent to edit, and this loop would have no subject.

## The loop

`run-self-improvement.sh` runs five stages:

1. Run the application and the debugging workflow. Both fail on purpose.
2. Let an agent read the workflow's own failed trace and edit its helper.
3. Check the proposed helper on two captured applications, without a model.
4. Run the improved workflow to diagnose the application failure.
5. Let a second agent propose the application fix, then validate it on three inputs.

Each proposal leaves the tree alone. The model's source is materialized into a
candidate component with its own descriptor, and a later run selects that
descriptor on the command line. The installed files are never written, which is
why the last check can assert they are byte-identical.

```text
stage 1  target                            -> capture A  broken pricing
         self-debugger                     -> capture B  the helper's own failure
stage 2  self-improver reads B             -> helper-proposal.private.json
         ptc materialize                   -> helper/descriptor.json
stage 3  self-check          + descriptor  -> replays capture A, no model
         variants/target-workflow-control  -> capture C  broken fulfillment
         self-check-workflow + descriptor  -> replays capture C, no model
stage 4  self-debugger       + descriptor  -> diagnosis.private.json, from capture A
stage 5  self-repair reads the diagnosis   -> application-proposal.private.json
         ptc materialize                   -> application/descriptor.json
         target              + descriptor  -> three inputs, pass or fail
```

## What the agent saw and did

The seeded bug is one line in `self-debugger/debug.start.clj`. The helper takes
the first relationship of the first generated program, although its docstring
says relationship order has no meaning:

```clojure
relationship (first (get generated "relationships"))
```

That is the `producing_turn` relationship above, so the workflow fails before it
reads any source.

The improving agent gets the task, the `debug.nav` library, and
`repair.edit/propose`. The task names the contract to keep. It does not name the
application, the faulty line, or the replacement. On its sixth model call the
agent read the failing program's relationships and found the same two rows. Two
calls later it submitted this replacement for the line above:

```clojure
(first (filter (fn [r] (and (= (get r "rel") "referenced_prelude_source")
                           (= (get r "state") "complete")
                           (not (nil? (get r "filters")))))
               (get generated "relationships")))
```

The model supplied only a before fragment and an after fragment.
`repair.edit/propose` copied the source hash and the unchanged bytes from the
frozen capture, and it refuses a fragment that is missing or occurs twice. When
the model had to return the whole file instead, it miscopied hashes and source.
This one helper is what made the loop reliable.

The repaired workflow then handed its first source page to the investigating
agent. On its third call that agent followed both dependencies of `pricing.tax`
in one program. It saw that `pricing.base` returns its input unchanged while
`pricing.rule` promises a charge of 20 and adds 2. Following only the first
dependency would have missed the bug. The repair agent received that diagnosis
as untrusted evidence and changed `(+ subtotal 2)` to `(+ subtotal 20)`.

## What counts as success

The model's explanation is not the acceptance check. The host:

- materializes and compiles each candidate;
- checks the helper on the pricing capture and on the fulfillment capture in
  `variants/target-workflow-control`, so a helper that only works on the run it
  was written from does not pass;
- reruns the application on the observed order and on two inputs absent from
  the failure capture;
- confirms afterwards that the original source files are byte-identical.

## Run it

```console
ptc init debug-a-failed-run --example debug-a-failed-run
sh debug-a-failed-run/run-self-improvement.sh /absolute/path/to/.env
```

The environment file holds an OpenRouter key and stays outside the example.
`self-host.json` and `self-improver-host.json` select the model. A successful
run ends with:

```text
Completed: helper checks, trace navigation, and three application validation cases. Artifacts: self-improvement-results
```

Start each full run from a fresh initialized directory. A failed stage leaves
its artifacts in `self-improvement-results`.

## Look inside

Read the helper proposal:

```console
ptc repl --project debug-a-failed-run/self-improver.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 6000 \
  -e '(let [r (first (get (analysis/runs {"status" "ok"}) "items"))] (get-in (analysis/open (get r "run_id")) ["result" "value"]))'
```

Use `self-debugger.ptc-project.json` for the investigation and
`self-repair.ptc-project.json` for the application fix. The `model_exchanges`
collection holds every request the model received and the program it generated
in reply. `(analysis/open "RUN_ID")` lists the collections, `analysis/read`
pages through one, and `ptc help transcript` exports a whole conversation.

## Files

The story is six files:

| File | Role |
| --- | --- |
| `run-self-improvement.sh` | The five stages. |
| `self-debugger/debug.start.clj` | The navigation helper with the seeded bug. |
| `self-debugger/check.clj` | Host check of a proposed helper. |
| `repair-agent/edit.clj` | Exact edits over frozen source. |
| `self-debugger/repair-input.clj` | Hands the diagnosis to the repair agent as untrusted evidence. |
| `self-debugger/validation/` | The three application inputs. |

Everything else is supporting material. `target/` is the broken application and
`self-*` are the five projects the script runs. `debugger/` walks the same
evidence deterministically, `debugger-agent/` walks it with a model, and
`repair-agent/` proposes a replacement component or abstains. `variants/` holds
two other failure shapes and explains itself.

## Limits

This is one bounded cycle. It edits a copy, validates it on a handful of inputs,
and stops. Adopting a candidate, and rechecking earlier cases after adoption, is
a host policy this example leaves out. The seeded defect is also a footgun the
library could close: `debug.nav/follow` fails loudly on a relationship it cannot
follow, but nothing yet offers the filtered selector every caller writes by
hand. See `ptc docs debug` for the evidence contract and `ptc docs repl` for
private analysis.
