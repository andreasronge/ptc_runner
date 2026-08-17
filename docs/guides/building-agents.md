# Customize an agent

> **Audience:** application authors using the shipped agent loop or replacing
> its prompt, policy, mission composition, or complete implementation.

Most users do not write the programs an agent executes. They configure a task,
model, approved tools, data, limits, and the shipped `agent.core` loop. The
model writes bounded mission programs during the run.

The checked-in multi-turn example shows that default path:

```console
ptc run examples/kernel-tutorial/04-multi-turn-agent.ptc-project.json
```

It selects `agent.core`, gives the trusted workflow a model alias, and declares
a mission in which generated programs run. The two environments are separate:

- the **workflow** owns prompts, model calls, retries, and completion policy;
- the **mission** owns only its selected data, components, and task tools.

Mission code cannot call the workflow model or re-enter the evaluation
boundary. Giving the workflow a model therefore does not give generated code
that authority.

## Start with the shipped loop

A thin workflow entry can delegate to the shipped loop:

```clojure
(ns app.agent)

(defn run [input]
  (agent.core/run (get input "task") {"max_turns" 6}))
```

Application authors normally generate this scaffold or start from an example;
they do not write each mission program the model produces. Configure the loop
through its documented options and keep the mission tool surface smaller than
the workflow surface.

## Replace policy without replacing enforcement

The Kernel owns capabilities, limits, evaluation, cleanup, and evidence. Agent
behavior lives in ordinary replaceable components. After the default loop works,
an application may introduce new component IDs for:

- system and correction prompts;
- feedback formatting;
- retry and continuation policy;
- completion and failure rules;
- specialist routing; or
- a complete alternative loop.

Changing those components cannot grant a new model, tool, credential, endpoint,
or higher limit. The host and application authority rules still apply.

## Compose specialists deliberately

One trusted workflow may call the loop several times with different named
missions. Use sequential stages when a later specialist depends on earlier
output. Use bounded parallel calls only for independent work, and size shared
provider and evaluation limits for the complete fan-out.

Do not automatically retry an indeterminate write. Keep effectful stages
explicit and reconcile an unknown outcome before continuing.

## Inspect and improve

Every agent run produces a canonical trace. Opt-in private inspection can also
retain prompts, responses, generated source, and tool payloads. Use replay to
hold model responses fixed while comparing a prompt or prelude candidate, then
promote a change only after evaluating its evidence.

Use the [agent library reference](../agent-library-reference.md) for exact entry
functions, options, outcomes, turn protocol, feedback, retry behavior, and
concurrency limits. See [Customize agent components](components-and-preludes.md)
for dependency and replacement rules, and [Evaluate changes with
replay](evaluating-with-replay.md) for the comparison workflow.
