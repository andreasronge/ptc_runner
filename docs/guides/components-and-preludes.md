# Inspect and customize components

Inspect the installed prompt, then try a changed copy without editing the
manifest. If you keep the change, give your permanent components new IDs.

A prelude is the compiled set of components used by one workflow or mission.
You replace one selected component when the next run starts.

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

## Try a different agent prompt

Export the installed prompt, edit the copy, then publish a gated candidate.
The two materialize modes are separate because a descriptor hashes the exact
candidate beside it:

```console
mkdir -p private
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source-out private/agent.prompt.clj
# edit private/agent.prompt.clj
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source private/agent.prompt.clj \
  --out private/agent-prompt-candidate
```

Neither destination may already exist. Validate, then run the candidate:

```console
ptc validate ptc-project.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
ptc run ptc-project.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

The override applies only to that command. Use
[replay](evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
when you need a fair comparison with the same model responses.

## Keep a change

Use new component IDs for permanent application code. A local component cannot
reuse a shipped library ID. If you replace a prompt or policy permanently,
select a loop whose dependencies point to your new components.

The [source-inspection reference](../reference/source-inspection.md) chooses a
retrieval surface. The
[components-and-preludes reference](../reference/component-contracts.md)
defines replacement rules, descriptor fields, and hashes.
