# Quickstart

> **Audience:** new users verifying the `ptc` executable and running a first
> model-authored program without writing PTC-Lisp.

This guide uses an installed standalone executable. The public one-command
installer is not published yet, so first build the verified executable as
described under [Installation](../installation/standalone.md). For the local
image instead, use the complete commands in [Docker installation](../installation/docker.md),
which account for mounted-file ownership.

## Run without a credential

Create and run a provider-free project:

```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

`init` creates an application, a project document with local artifact settings,
and ignore rules for public and private run artifacts. The first run contacts no
model or external tool and records a canonical trace and command envelope under
`hello-ptc/.ptc`.

## Run a model-authored program

Materialize the tutorial projects and create their owner-only environment file:

```console
ptc init kernel-tutorial --example kernel-tutorial
printf 'OPENROUTER_API_KEY=\n' > kernel-tutorial/.env
chmod 600 kernel-tutorial/.env
```

Set `OPENROUTER_API_KEY` in that exact file, then run:

```console
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

```json
{"ok":true,"value":42}
```

The project selects the shipped agent loop. The model receives a task, writes a
bounded mission program, observes its result, and completes on the second turn.
You configure the task, model alias, mission, tools, and limits; you do not need
to read or edit the generated program. To read it anyway, open the Viewer:

```console
ptc viewer kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

The tutorial projects record private inspection and grant it to the Viewer, so
each evaluation shows the PTC-Lisp the model wrote and each prelude component
shows the source the run loaded.

Credentials belong to the operator-owned host configuration, never the
application manifest, generated program, or canonical trace. The manifest can
select the installed model alias but cannot name its endpoint or key.

## Diagnose readiness

Check configuration without contacting the provider:

```console
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

Probe credentials and connectivity only when remote work and possible cost are
intended:

```console
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json --connect
```

Continue with [Understand a generated project](getting-started.md), [Use a
model](using-models.md), or [Customize an agent](building-agents.md). The
[command-line reference](../reference/cli.md) owns the exact command and failure
contract.
