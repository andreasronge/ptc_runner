# Debug a failed run

> **Audience:** application authors and operators diagnosing a run from its
> immutable trace and, when explicitly retained, private inspection evidence.

Start with the public evidence:

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

If the run was configured to retain private inspection, authorize the private
profile separately and write unattended output to an owner-controlled file.
Private inspection is for questions that public evidence cannot answer; it is
not the default debugging path.

The checked-in debugging example demonstrates another useful pattern: one
ordinary PtcRunner application can navigate a frozen failed capture through the
shipped `debug.nav` library without gaining filesystem, network, model, or
nested-evaluation authority.

```console
ptc init debug-a-failed-run --example debug-a-failed-run
ptc run debug-a-failed-run/target.ptc-project.json
ptc run debug-a-failed-run/debugger.ptc-project.json
```

The same example optionally closes the loop: a phased repair agent proposes a
complete component replacement or abstains, and the host validates a proposal
against its own held-out cases with `mix ptc.repair` before any human promotes
it. The README materialized beside the example walks both arms; the validation
contract is documented in the repository's maintainer guide on embedding.

Use the [debug-navigation reference](../reference/debug-navigation.md) for the
complete evidence graph, typed links, collections, resources, pagination,
private-authority rules, and model-assisted navigation contract. The
[TraceLog and run-analysis reference](../maintainers/trace-log-contract.md) owns
the canonical event schema.
