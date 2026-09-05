# Let an agent improve its own debugging workflow

A debugging workflow fails because its navigation helper has a bug. An agent
reads that failed run, proposes an exact edit to the helper, and the host
checks the edit without a model. The repaired workflow then diagnoses a broken
application, and a second agent proposes a fix that the host validates on
inputs the agent never saw. No checked-in source changes.

## The loop

`run-self-improvement.sh` runs five stages:

1. Run the application and the debugging workflow. Both fail on purpose.
2. Let an agent read the workflow's own failed trace and edit its helper.
3. Check the proposed helper on two captured applications, without a model.
4. Run the improved workflow to diagnose the application failure.
5. Let a second agent propose the application fix, then validate it on three inputs.

Each proposal is materialized into a candidate descriptor that later runs
select explicitly. The source files stay as they are.

## What the agent saw and did

The seeded bug is one line in `self-debugger/debug.start.clj`. The helper
takes the first relationship of the first generated program, although its
docstring says relationship order has no meaning:

```clojure
relationship (first (get generated "relationships"))
```

The improving agent gets the task, the `debug.nav` library, and
`repair.edit/propose`. The task names the contract to keep. It does not name
the application, the faulty line, or the replacement. On its sixth model call
the agent read the failing program's relationships:

| Relationship | State |
| --- | --- |
| `producing_turn` | `unavailable` |
| `referenced_prelude_source` | `complete` |

Two calls later it submitted this replacement for the line above:

```clojure
(first (filter (fn [r] (and (= (get r "rel") "referenced_prelude_source")
                           (= (get r "state") "complete")
                           (not (nil? (get r "filters")))))
               (get generated "relationships")))
```

The model supplied only a before fragment and an after fragment.
`repair.edit/propose` copied the source hash and the unchanged bytes from the
frozen capture, and it refuses a fragment that is missing or occurs twice.
When the model had to return the whole file instead, it miscopied hashes and
source. This one helper is what made the loop reliable.

The repaired workflow then handed its first source page to the investigating
agent. On its third call that agent followed both dependencies of
`pricing.tax` in one program. It saw that `pricing.base` returns its input
unchanged while `pricing.rule` promises a charge of 20 and adds 2. Following
only the first dependency would have missed the bug. The repair agent received
that diagnosis as untrusted evidence and changed `(+ subtotal 2)` to
`(+ subtotal 20)`.

## What counts as success

The model's explanation is not the acceptance check. The host:

- materializes and compiles each candidate;
- checks the helper on the pricing capture and on a fulfillment capture;
- reruns the application on the observed order and on two inputs absent from
  the failure capture;
- confirms afterwards that the original source files are byte-identical.

One run with Gemini 3.8 Flash took 21 model calls and cost about nine cents.
Model runs vary, and the script stops at the first failed stage.

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
`self-repair.ptc-project.json` for the application fix. The
`model_exchanges` collection holds every request the model received and the
program it generated in reply. `(analysis/open "RUN_ID")` lists the
collections, `analysis/read` pages through one, and `ptc help transcript`
exports a whole conversation.

## Files

| File | Role |
| --- | --- |
| `run-self-improvement.sh` | The five stages. |
| `self-debugger/debug.start.clj` | The helper with the seeded bug. |
| `self-debugger/check.clj` | Host check of a proposed helper. |
| `repair-agent/edit.clj` | Exact edits over frozen source. |
| `self-debugger/repair-input.clj` | Hands the diagnosis to the repair agent as untrusted evidence. |
| `self-debugger/validation/` | The three application inputs. |

The directory also keeps the smaller pieces: three `target*` applications that
fail on purpose, `debugger` for a deterministic walk, `debugger-agent` for a
model-driven walk, and `repair-agent*` for a repair from a host-built incident
packet. `mix help ptc.repair` runs their validation suites from a checkout.

## Limits

This is one bounded cycle. It edits a copy, validates it on a handful of
inputs, and stops. Adopting a candidate, and rechecking earlier cases after
adoption, is a host policy this example leaves out. See `ptc docs debug` for
the evidence contract and `ptc docs repl` for private analysis.
