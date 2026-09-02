# Quickstart

Install `ptc`, verify it without an API key, then run a model-authored program
without writing PTC-Lisp yourself.

Download the executable as described under
[Standalone installation](../installation/standalone.md). Starting with the
next root release, the [Docker image](../installation/docker.md) provides the
same command interface; its installation page gives the complete mounted-file
and ownership form.

## Run without a credential

Create and run a project that needs no API key:

The `ptc init` target must not already exist. For an existing repository,
initialize a new sibling or subdirectory and deliberately copy or move the
generated files you want into the repository.

<!-- ptc-guide-e2e: id=quickstart-no-api-key frontend=mix scratch=hello-ptc -->
```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

`init` creates an application, a project document with local artifact settings,
and ignore rules for public and private run artifacts. The first run contacts no
model or external tool and records a trace and command envelope under
`hello-ptc/.ptc`.

## Run a model-authored program

Materialize the tutorial; its comment-only environment file names the credential:

```console
ptc init kernel-tutorial --example kernel-tutorial
```

Keep that comment and export a non-empty value, or add a non-empty assignment to
the file. File assignments, including empty ones, override exports; see
[Host installation](../reference/host-installation.md).

```console
export OPENROUTER_API_KEY=...
```

Then run:

```console
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

```json
{"ok":true,"value":42}
```

The model writes a bounded mission program, observes its result, and completes
on the second turn. To read that program, open the Viewer:

```console
ptc viewer kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

The tutorial projects record private inspection and grant it to the Viewer, so
each evaluation shows the PTC-Lisp the model wrote and each prelude component
shows the source the run loaded.

Credentials belong in `ptc-host.json`, never in `ptc.json`, a generated
program, or a trace. `ptc.json` can select the installed model alias but cannot
name its endpoint or key.

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
