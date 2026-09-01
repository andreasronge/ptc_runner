# Debug a failed run

Follow a failed run from its immutable trace into private inspection only when
the trace cannot answer the question.

## What failed?

Start with the trace:

```console
ptc viewer ptc-project.json
```

Or query it with the fixed analysis profile:

```console
ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {"status" "error"})'
```

Use the run ID to open its activity, terminal reason, evaluations, tool use,
limits, and completeness flags. Public traces deliberately omit prompts,
responses, generated source, and tool payloads.

If the run retained private inspection, authorize that profile separately and
write unattended output to an owner-controlled file. That path is not the
default. For live attached source, see
[Inspect source and generated programs](inspecting-source-and-programs.md).

## Can another run inspect the failure?

The checked-in debugging example demonstrates another useful pattern: one
ordinary PtcRunner application can navigate a frozen failed capture through the
shipped `debug.nav` library without gaining filesystem, network, model, or
nested-evaluation access.

```console
ptc init debug-a-failed-run --example debug-a-failed-run
ptc run debug-a-failed-run/target.ptc-project.json
ptc run debug-a-failed-run/debugger.ptc-project.json
```

The same example optionally closes the loop: a repair agent proposes a
complete replacement or abstains, and a later `ptc run` can try that
candidate through `--component-override-descriptor` without editing a
file. The README materialized beside the example walks the path.

## Where is the complete evidence contract?

Use the [debug-navigation reference](../reference/debug-navigation.md) for the
complete evidence graph, typed links, collections, resources, pagination,
private-inspection rules, and model-assisted navigation contract. The
[TraceLog and run-analysis reference](../maintainers/trace-log-contract.md) owns
the event schema.
