# Examples reference

This is the complete inventory of shipped example trees, the layout every tree
follows, and the aspect each one demonstrates.

## Pick by purpose

Every row names the tree and the document to run first, so nothing has to be
traversed in order to find the one thing you came for.

| You want | Tree | Start with |
| --- | --- | --- |
| A first run with no credential | `kernel-tutorial` | `01-orders.ptc-project.json` |
| One model call with a structured-output schema | `kernel-tutorial` | `02-deepseek-extract.ptc-project.json` |
| An agent loop holding a tool over MCP | `kernel-tutorial` | `03-file-agent.ptc-project.json` |
| The feedback a failed signature check returns | `kernel-tutorial` | `05-signature-feedback.ptc-project.json` |
| A deliberate limit refusal and its exit status | `kernel-tutorial` | `06-cost-budget.ptc-project.json` |
| Many model requests in parallel, then one synthesis | `kernel-tutorial` | `07-parallel-fan-out.ptc-project.json` |
| A workflow composing deterministic rules with a model | `support-triage` | `02-domain-api.ptc-project.json` |
| Two named missions granted different capabilities | `support-triage` | `03-specialists.ptc-project.json` |
| A write kept behind its own mission | `named-mission-reader-writer` | `ptc-project.json` |
| Replaying a recorded model response | `llm-replay` | `ptc-project.json` |
| Verifying a result inside the run that produced it | `dabstep-fraud` | `ptc-project.json`, after `fetch-data.sh` |
| Repairing a workflow from a failed run's evidence | `debug-a-failed-run` | `run-self-improvement.sh` |

## The shipped trees

The trees below are listed in learning order: each one assumes the surface
the one before it introduced.

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
checkout-only. Its replay project reads the same downloaded file, so replay
removes the model calls but not the download. It is listed at the end of this
page.

## How an example tree is laid out

Most numbered steps pair a project document with a directory of the same name.
The self-improvement workflow shares component files through manifests at the
example root; its script creates the artifact directories before running.

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

`debug-a-failed-run` is the self-improvement example. `run-self-improvement.sh`
runs a debugging workflow that fails on purpose, lets an agent repair the
workflow's own navigation helper, checks that helper without a model, then uses
the repaired workflow to diagnose and repair an application. The same tree
keeps the smaller pieces: `target.ptc-project.json` fails on purpose,
`debugger.ptc-project.json` walks the evidence deterministically,
`debugger-agent.ptc-project.json` walks it with a model, and
`repair-agent.ptc-project.json` proposes a replacement component or abstains.
The `variants/` directory holds two other failure shapes, an underdetermined
mismatch and a workflow-routing defect, so the same debuggers and repair agent
meet more than one bug.

`llm-replay` serves one recorded model response from `replay.jsonl`. It needs
no credential and performs no network activity, which makes it the tree to copy
when building a test that must not call a provider.

## The example that needs a checkout

[`dabstep-fraud`](https://github.com/andreasronge/ptc_runner/tree/main/examples/dabstep-fraud)
runs three agent loops over 138,236 payment rows and reviews a stage's answer
in workflow code before anyone acts on it. Its `fetch-data.sh` downloads the
dataset before the first run, so the tree is not embedded. Run it from a clone,
or read it on GitHub; its `README.md` states the prerequisites.
