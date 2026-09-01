# Customize agent components

Try a changed prompt or agent loop without changing `ptc.json`. If you keep the
change, give your permanent components new IDs.

A prelude is the compiled set of components used by one workflow or mission.
It is immutable during a run. You do not replace the whole prelude. You replace
one selected component when the next run starts.

## Try a different agent prompt

Selecting `agent.core` also selects `agent.prompt`. The prompt is therefore an
override target even when it is not listed directly in the manifest.

Export the installed prompt, edit the copy, then publish a gated candidate.
`--source-out` and `--source`/`--out` are separate steps because a descriptor
hashes the exact candidate beside it:

```console
mkdir -p private
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source-out private/agent.prompt.clj
# edit private/agent.prompt.clj
ptc materialize ptc-project.json --workflow \
  --component agent.prompt --source private/agent.prompt.clj \
  --out private/agent-prompt-candidate
```

The second command checks the source and creates the candidate and descriptor
files. Neither destination may already exist.

Validate the candidate without acquiring a provider:

```console
mix ptc validate ptc.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

Run the normal version first. Then run the candidate:

```console
mix ptc run ptc.json
mix ptc run ptc.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

The override applies only to that command. It does not edit the manifest or
install the candidate. Use
[replay](evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
when you need a fair comparison with the same model responses.

## Keep a change

Use new component IDs for permanent application code. A local component cannot
reuse a shipped library ID. If you replace a prompt or policy permanently,
select a loop whose dependencies point to your new components.

The [components-and-preludes reference](../reference/component-contracts.md)
defines dependencies, mission targets, descriptor fields, hashes, effect
widening, failure messages, and security boundaries. The
[agent library reference](../agent-library-reference.md) documents the shipped
agent components and their options.
