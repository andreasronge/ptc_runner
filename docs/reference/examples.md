# Examples reference

This is the complete inventory of shipped example trees, the layout every tree
follows, and the aspect each one demonstrates.

Four trees are embedded in the executable and materialize anywhere:

```console
ptc init DIRECTORY --example kernel-tutorial
ptc init DIRECTORY --example support-triage
ptc init DIRECTORY --example debug-a-failed-run
ptc init DIRECTORY --example llm-replay
```

`ptc init` refuses a directory that already exists and writes the tree
atomically. The copy is complete: it carries its own application manifests,
host document, PTC-Lisp sources, and data, plus a generated `.env` stub when
the tree names one. Nothing resolves back to a checkout, so the copy runs from
wherever you put it.

The remaining trees are checkout-only and are listed at the end of this page.

## How an example tree is laid out

Every runnable step is a pair: a project document beside a directory of the
same name.

```
kernel-tutorial/
  ptc-host.json                     installed providers, shared by the steps
  01-orders.ptc-project.json        the thing you run
  01-orders/
    ptc.json                        application manifest
    orders.clj                      PTC-Lisp source
    orders.json                     input data
  02-deepseek-extract.ptc-project.json
  02-deepseek-extract/
    ...
```

Point `ptc run` at the project document, never at the directory. The project
document supplies the paths for everything else, so a run and its Viewer take
the same single argument:

```console
ptc run kernel-tutorial/01-orders.ptc-project.json
ptc viewer kernel-tutorial/01-orders.ptc-project.json
```

Three separate documents carry three separate concerns, and
[the project-configuration reference](project-files.md) holds the full field
contract for each.

A tree has many step directories because each step directory is the complete
project at that point. Later steps repeat earlier files rather than referencing
them, so two steps can be diffed to see exactly what one design decision added:

```console
diff -ru support-triage/01-one-question support-triage/02-domain-api
```

One `ptc-host.json` at the tree root serves the steps that select a provider. A
step needing a different installed ceiling gets its own host document instead,
which is why `kernel-tutorial` also ships `ptc-host-cost-budget.json`.

## What each step demonstrates

`kernel-tutorial` builds up the runtime surface. Steps 01 and 05 need no
credential.

| Step | Aspect |
| --- | --- |
| `01-orders` | A deterministic workflow that selects no provider |
| `02-deepseek-extract` | One model call producing a structured value |
| `03-file-agent` | An agent loop holding a filesystem tool over MCP |
| `04-multi-turn-agent` | A two-turn agent loop under explicit Kernel clocks |
| `05-signature-feedback` | Signatures, and the feedback a failed check returns |
| `06-cost-budget` | A deliberate cost-limit refusal, exit status 6 |

`support-triage` grows one support-inbox scenario through three design
decisions. Every step selects a provider.

| Step | Aspect |
| --- | --- |
| `01-one-question` | Tickets granted as mission data, one bounded question, no tools |
| `02-domain-api` | A prompt-visible mission API the model composes, instead of tool relay |
| `03-specialists` | Two named missions with different grants, and a result contract |

`debug-a-failed-run` pairs a failing target with the debuggers that read its
evidence. `target.ptc-project.json` fails on purpose;
`debugger.ptc-project.json` walks the evidence deterministically and
`debugger-agent.ptc-project.json` walks it with a model. The `-ambiguous` and
`-workflow-control` variants change the failure so the same debuggers meet a
different shape.

`llm-replay` serves one recorded model response from `replay.jsonl`. It needs
no credential and performs no network activity, which makes it the tree to copy
when building a test that must not call a provider.

## Examples that need a checkout

These trees are not embedded. Run them from a clone, or read them on GitHub.

| Tree | Aspect |
| --- | --- |
| [`named-mission-reader-writer`](https://github.com/andreasronge/ptc_runner/tree/main/examples/named-mission-reader-writer) | Two missions holding separate tool authority over separate roots |
| [`dabstep-fraud`](https://github.com/andreasronge/ptc_runner/tree/main/examples/dabstep-fraud) | A stage's answer reviewed in workflow code before anyone acts on it |
| [`viewer-demo`](https://github.com/andreasronge/ptc_runner/tree/main/examples/viewer-demo) | Five journeys producing varied trace data to exercise the Viewer |
| [`viewer-live-dashboard`](https://github.com/andreasronge/ptc_runner/tree/main/examples/viewer-live-dashboard) | A parallel model fan-out and synthesis pass, long enough to watch live |
| [`kernel-inspection-lab`](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-inspection-lab) | A trace and a private inspection record from one credential-free run |

`kernel-inspection-lab` and `viewer-demo` are driven by a script rather than a
project document, and `dabstep-fraud` downloads a dataset before it runs. Each
tree's `README.md` states its own prerequisites.
