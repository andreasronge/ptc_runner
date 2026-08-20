# Customize agent components

> **Audience:** advanced application authors replacing shipped prompts,
> policies, libraries, or complete agent loops.

Most applications select shipped libraries and do not copy their source:

```json
{
  "workflow": {
    "components": [
      {"id": "app.agent", "path": "agent.clj", "dependencies": ["agent.core"]},
      {"library": "agent.core"}
    ],
    "entry": "app.agent/run"
  }
}
```

The shipped `agent.core` loop is a replaceable library, not Kernel behavior.
Start with it, then introduce a custom component under a new ID when the
application needs different prompts, feedback, retry policy, continuation, or
completion rules.

## Trial a different core prompt

Selecting `agent.core` also selects its `agent.prompt` dependency. A component
override can therefore trial a replacement prompt without changing the
application manifest. The replacement keeps the installed component ID and
dependencies and must provide the three functions `agent.core` calls:

```clojure
(ns agent.prompt "Application prompt policy." {:visibility :discoverable})

(defn initial-state [cfg]
  {:turns-remaining (get cfg "max_turns")})

(defn render {:effect :read} [_state]
  "Use run_ptc_lisp to solve the task. Return the completed value; do not answer in prose.")

(defn transition [state event]
  (assoc state :turns-remaining (get event :turns-remaining)))
```

In a source checkout, save that source as `custom-agent-prompt.clj`, then
materialize and run the candidate:

```console
mkdir -p private
mix ptc.materialize ptc.json \
  --workflow \
  --component agent.prompt \
  --source custom-agent-prompt.clj \
  --out private/agent-prompt-candidate

mix ptc run ptc.json \
  --component-override-descriptor private/agent-prompt-candidate/descriptor.json
```

The descriptor binds the candidate bytes to the exact installed
`agent.prompt` source they replace. The override applies to this invocation
only; project files do not store component overrides. See [Evaluate changes
with replay](evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
for the descriptor fields and replay comparison.

The active bundle cannot be replaced during its run. A workflow may return
candidate source as its result, but materialization and execution happen in a
later host invocation so the replacement is compiled, hashed, and validated
before it becomes active.

Each component declares its direct namespace dependencies. Selecting a library
installs its immutable dependency closure, but does not grant tool authority.
Mission tools still come only from providers installed by the operator and
selected for that mission.

Keep reusable components narrow:

- expose a small documented public surface;
- declare signatures where model-written calls benefit from validation;
- keep prompt-visible helpers focused on the task contract;
- separate workflow policy from mission-only task functions; and
- use a new component ID for a permanently customized prompt or loop.

Use the [components-and-preludes reference](../reference/component-contracts.md)
for namespaces, dependency rules, visibility, signatures, shipped library
selection, compilation, and authority boundaries. The
[agent library reference](../agent-library-reference.md) documents the exact
shipped loop entries and options.
