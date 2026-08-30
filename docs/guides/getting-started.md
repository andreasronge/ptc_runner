# Understand a generated project

Understand the files, result, and trace created by `ptc init` without writing
an agent loop.

Create a project that needs no API key if you do not already have one:

`ptc init` requires a target directory that does not already exist. It
assembles the complete scaffold and publishes it atomically without replacing
anything. To add PtcRunner to an existing repository, initialize a new sibling
or subdirectory, then deliberately copy or move the generated files the
repository wants.

```console
ptc init hello-ptc
```

It contains four files with different jobs:

| File | Purpose |
| --- | --- |
| `ptc-project.json` | Stable local paths, artifacts, and Viewer preferences |
| `ptc.json` | Workflow, input, missions, selected providers, and narrower limits |
| `main.clj` | The generated example component selected by the workflow |
| `AGENTS.md` | Routing card telling a coding agent which commands answer what |

The project document is the normal command argument. It points to the other
files, so commands do not depend on the shell's current directory.

## Run a data workflow

The checked-in orders example is deterministic and needs no credential:

<!-- ptc-guide-e2e: id=generated-orders frontend=mix scratch=tutorial-example -->
```console
ptc init tutorial-example --example kernel-tutorial
ptc run tutorial-example/01-orders.ptc-project.json
```
```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

The application reads structured input and returns one bounded JSON value. No
model or external tool is involved.

## Inspect the run

Open the local Viewer:

```console
ptc viewer tutorial-example/01-orders.ptc-project.json
```

The trace records the command, evaluations, limits, outcome, and
resource usage. It never contains prompts, model responses, generated source,
or tool payloads. Those are private evidence, recorded only when
`artifacts.inspection` is true and served only when `viewer.private` is also
true.

The tutorial project documents set both, so the Viewer joins that evidence into
the transcript: every effective prelude lists a `source` link beside each
component, and the model-driven steps show each evaluation's generated
PTC-Lisp under **Program source** along with the model conversation. Set either
setting back to `false` and the same run shows the trace alone.

You can also explore the workflow directly:

```console
ptc repl --project tutorial-example/01-orders.ptc-project.json
```

Continue with [Configure an application](manifests-and-capabilities.md) to add
input, missions, or selected providers. Use the
[project-configuration reference](../reference/project-files.md) for
the complete local file and artifact contract.
