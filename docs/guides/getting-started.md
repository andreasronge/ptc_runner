# Understand a generated project

> **Audience:** new application authors who have completed the Quickstart and
> want to understand the files, result, and trace without writing an agent loop.

Create a provider-free project if you do not already have one:

```console
ptc init hello-ptc
```

It contains four application roles:

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

```console
ptc run examples/kernel-tutorial/01-orders.ptc-project.json
```
```json
{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}
```

The application reads structured input and returns one bounded JSON value. No
model or external tool is involved.

## Inspect the run

Open the local Viewer:

```console
ptc viewer examples/kernel-tutorial/01-orders.ptc-project.json
```

The canonical trace records the command, evaluations, limits, outcome, and
resource usage. It does not contain prompts, model responses, generated source,
or tool payloads. Those sensitive records require explicit private inspection.

You can also explore the workflow directly:

```console
ptc repl --project examples/kernel-tutorial/01-orders.ptc-project.json
```

Continue with [Configure an application](manifests-and-capabilities.md) to add
input, missions, or selected providers. Use the
[project-configuration reference](../reference/project-files.md) for
the complete local file and artifact contract.
