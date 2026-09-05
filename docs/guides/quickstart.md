# Quickstart

Install `ptc`, run a project that needs no API key, then run one where the
model writes the program.

Download the executable as described in
[Standalone installation](../installation/standalone.md).

## Run without a credential

<!-- ptc-guide-e2e: id=quickstart-no-api-key frontend=mix scratch=hello-ptc -->
```console
ptc init hello-ptc
ptc run hello-ptc/ptc-project.json
```

```json
{"greeting":"hello world"}
```

`init` writes a small application, a project document, and ignore rules for
run artifacts into a directory that must not exist yet. The run contacts no
model or tool and records a trace under `hello-ptc/.ptc`.

## Run a model-authored program

Materialize the tutorial, export an OpenRouter key, and run the multi-turn
agent:

```console
ptc init kernel-tutorial --example kernel-tutorial
export OPENROUTER_API_KEY=...
ptc run kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

```json
{"ok":true,"value":42}
```

The model writes a small mission program, sees its result, and finishes on the
second turn. Open the Viewer to read the program it wrote:

```console
ptc viewer kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

The tutorial projects retain private inspection and grant it to the Viewer, so
you see the PTC-Lisp behind each evaluation and the source of each prelude
component.

The generated `.env` file names the credential in a comment. Either export the
variable, as above, or write a non-empty value into that file. Credentials
belong in `ptc-host.json` or the environment, never in `ptc.json`, a program,
or a trace. The
[host reference](../reference/host-installation.md#declare-credentials-once)
has the loading rules.

## Check readiness before spending

`doctor` checks the configuration without contacting the provider. Add
`--connect` when you want to probe the credential and the network too:

```console
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json
ptc doctor kernel-tutorial/04-multi-turn-agent.ptc-project.json --connect
```

Continue with [Understand a generated project](getting-started.md),
[Use a model](using-models.md), or [Customize an agent](building-agents.md).
