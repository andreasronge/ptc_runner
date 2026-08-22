# Customize agent components

Replace shipped prompts, policies, libraries, or complete agent loops when the
shipped behavior no longer fits.

Most applications select shipped libraries
and do not copy their source:

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

## Trial a replacement safely

Selecting `agent.core` also selects its `agent.prompt` dependency. A verified
component override can trial another prompt for one invocation without changing
`ptc.json`. The active bundle remains immutable throughout the run; a later
invocation compiles and checks the candidate before it can become active.

The standalone executable can run a prepared override descriptor but does not
create one. Candidate creation is currently a source-checkout workflow. Use
[Evaluate changes with replay](evaluating-with-replay.md#evaluate-the-candidate-without-installing-it)
to compare a prepared candidate, and use the repository's
[embedding guide](https://github.com/andreasronge/ptc_runner/blob/main/docs/maintainers/embedding.md#materialize-candidate-source)
when creating the descriptor.

Each component declares its direct namespace dependencies. Selecting a library
installs its immutable dependency closure, but does not add tools. Mission tools
still come only from providers installed in `ptc-host.json` and selected for
that mission in `ptc.json`.

Keep reusable components narrow:

- expose a small documented public surface;
- declare signatures where model-written calls benefit from validation;
- keep prompt-visible helpers focused on the task contract;
- separate workflow policy from mission-only task functions; and
- use a new component ID for a permanently customized prompt or loop.

Use the [components-and-preludes reference](../reference/component-contracts.md)
for namespaces, dependency rules, visibility, signatures, shipped library
selection, compilation, and provider-selection boundaries. The
[agent library reference](../agent-library-reference.md) documents the exact
shipped loop entries and options.
