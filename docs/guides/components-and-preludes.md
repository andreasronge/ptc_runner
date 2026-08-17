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
