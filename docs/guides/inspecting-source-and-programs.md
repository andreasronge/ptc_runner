# Inspect source and generated programs

The model's narration states intent; the admitted PTC-Lisp program is the
executable decision you can inspect.

That program shows the functions, tools, data, and return or failure path that
were actually chosen. Reviewing it helps debug a surprising result, check
authority use, accept or reject a candidate, and improve a prompt.

Inspection does not mutate the active bundle or promote a replacement. Use an
explicit inspect, edit, replay, and compare cycle instead.

## How do I choose a retrieval surface?

| Need | Start here | Details |
| --- | --- | --- |
| One attached definition | `(source agent.prompt/render)` | [REPL](../reference/repl.md) and [function](../function-reference.md) references |
| One attached component and its direct dependencies | `(component "agent.prompt")` | [Source inspection](../reference/source-inspection.md) and [component](../reference/component-contracts.md) references |
| Programs a nested loop admitted before the workflow ends | `run-outcome` with `"retain_programs"` | [Agent library](../agent-library-reference.md) and [source inspection](../reference/source-inspection.md) |
| Exact programs and component source from a completed run | `analysis/read` on private inspection | [Debug navigation](../reference/debug-navigation.md) |

## What is public versus private?

Public traces carry identities, hashes, dependency projections, and outcomes,
but not source. Host logs and telemetry are not source-export surfaces. Exact
historical source requires explicitly enabled private inspection.

Use the [source-inspection reference](../reference/source-inspection.md) for
the full selection matrix, return shapes, limits, and privacy rules.
