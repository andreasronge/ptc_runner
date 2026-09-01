# Inspect and customize components

Change the shipped agent prompt on a run without editing the manifest.
Installing that prompt as application code is a separate graph change.

A prelude is the compiled set of components used by one workflow or mission.

## Inspect the installed prompt

Open a compile-and-inspect project REPL. It needs no API key:

```console
ptc repl --project ptc-project.json --inspect-only
```

```clojure
(component "agent.prompt")
```

Selecting the shipped agent loop also selects its prompt, so that prompt is an
override target even when it is not listed in the manifest.

## Change the prompt on a run

Export the installed prompt, edit the copy, then publish a gated candidate:

```console
mkdir -p private
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source-out private/agent.prompt.clj
# edit private/agent.prompt.clj
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source private/agent.prompt.clj \
  --out private/agent-prompt-candidate
```

Validate, then run the candidate:

```console
ptc validate ptc-project.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
ptc run ptc-project.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

Pass the descriptor on each command that should use the candidate. The project
file does not store it.

- One selected component's source is replaced; the loop wiring is not.
- The override cannot add a component, rename one, or change dependencies.
- If the shipped prompt source changes, publish a new candidate from the new
  base.

Use
[replay](evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
when you need a fair comparison with the same model responses.

## Install a prompt in the application

A local component cannot reuse a shipped library ID, so selecting the shipped
loop still installs the shipped prompt. Give the custom prompt a new ID and
select a loop whose dependencies name that ID. The
[component reference](../reference/component-contracts.md#install-a-custom-prompt)
covers which shipped callers to copy.

The [source-inspection reference](../reference/source-inspection.md) chooses a
retrieval surface. The
[components-and-preludes reference](../reference/component-contracts.md)
defines replacement rules, descriptor fields, and hashes.
