# Examples reference

This is the complete inventory of shipped example trees, the layout every tree
follows, and the aspect each one demonstrates.

Read the trees in the order listed: each one assumes the surface the one
before it introduced.

Five trees are embedded in the executable and materialize anywhere:

```console
ptc init DIRECTORY --example kernel-tutorial
ptc init DIRECTORY --example support-triage
ptc init DIRECTORY --example named-mission-reader-writer
ptc init DIRECTORY --example debug-a-failed-run
ptc init DIRECTORY --example llm-replay
```

`ptc init` refuses a directory that already exists and writes the tree
atomically. The copy is complete: it carries its own application manifests,
host document, PTC-Lisp sources, and data, plus the same `AGENTS.md` routing
card the scaffold ships and a generated `.env` stub when the tree names one.
Nothing resolves back to a checkout, so the copy runs from wherever you put it.

One tree, `dabstep-fraud`, downloads its dataset before it runs and is
checkout-only. It is listed at the end of this page.

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

## What each tree demonstrates

`kernel-tutorial` builds up the runtime surface one step at a time. Steps 01
and 05 need no credential.

| Step | Aspect |
| --- | --- |
| `01-orders` | A deterministic workflow that selects no provider |
| `02-deepseek-extract` | One model request with a structured-output schema, returning the filled object |
| `03-file-agent` | An agent loop holding a filesystem tool over MCP |
| `04-multi-turn-agent` | A two-turn agent loop under explicit Kernel clocks |
| `05-signature-feedback` | Signatures, and the feedback a failed check returns |
| `06-cost-budget` | A deliberate cost-limit refusal, exit status 6 |
| `07-parallel-fan-out` | Twelve model requests through `pmap`, then one synthesis request |

`support-triage` grows one support-inbox scenario through three design
decisions. Every step selects a provider.

| Step | Aspect |
| --- | --- |
| `01-one-question` | Tickets granted as mission data, one bounded question, no tools |
| `02-domain-api` | A prompt-visible mission API the model composes, instead of tool relay |
| `03-specialists` | Two named missions with different grants, and a result contract |

`named-mission-reader-writer` is one workflow coordinating two agent loops.
The `reader` mission holds only a read tool over one directory and the
`writer` mission holds only a write tool over another, so a generated program
in either mission cannot reach the other's authority. It is the runnable form
of a write kept behind its own mission.

`debug-a-failed-run` pairs a failing target with the debuggers that read its
evidence. `target.ptc-project.json` fails on purpose;
`debugger.ptc-project.json` walks the evidence deterministically and
`debugger-agent.ptc-project.json` walks it with a model.
`repair-agent.ptc-project.json` extends the incident into a phased agent run
whose only terminal actions are to propose a replacement component or to
abstain. The `-ambiguous` and `-workflow-control` variants change the failure
so the same debuggers and repair agent meet a different shape.

`llm-replay` serves one recorded model response from `replay.jsonl`. It needs
no credential and performs no network activity, which makes it the tree to copy
when building a test that must not call a provider.

## The example that needs a checkout

[`dabstep-fraud`](https://github.com/andreasronge/ptc_runner/tree/main/examples/dabstep-fraud)
runs three agent loops over 138,236 payment rows and reviews a stage's answer
in workflow code before anyone acts on it. Its `fetch-data.sh` downloads the
dataset before the first run, so the tree is not embedded. Run it from a clone,
or read it on GitHub; its `README.md` states the prerequisites.
