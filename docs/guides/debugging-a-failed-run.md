# Improve a debugging workflow

Repair a debugging workflow from its failed trace. Then use the improved
workflow to navigate application code and validate an application repair.

## Run the example

Initialize a fresh example directory:

```console
ptc init debug-a-failed-run --example debug-a-failed-run
```

This creates the example applications and `run-self-improvement.sh`.
Run the script with your OpenRouter environment file:

```console
sh debug-a-failed-run/run-self-improvement.sh /absolute/path/to/.env
```

The script captures two failures, asks an agent to repair its navigation
helper, checks the helper on two applications, and investigates the original
application. A second repair step proposes an application edit and tests it on
three inputs.

A successful run ends with:

```text
Completed: helper checks, trace navigation, and three application validation cases. Artifacts: self-improvement-results
```

The helper's starting defect is seeded for the example. Model runs can vary;
the script stops when a stage fails.

## Read the proposed improvement

Inspect the helper proposal through PTC:

```console
ptc repl --project debug-a-failed-run/self-improver.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 6000 \
  -e '(let [r (first (get (analysis/runs {"status" "ok"}) "items"))] (select-keys (get-in (analysis/open (get r "run_id")) ["result" "value"]) ["component_id" "cause" "candidate_source"]))'
```

This prints the selected component, explanation, and replacement source.
The example README explains how to inspect the investigation and final repair.
Candidates and validation results remain in `self-improvement-results`;
the original source files remain unchanged.

See [debug navigation](../reference/debug-navigation.md) for the workflow stages
and [components](../reference/component-contracts.md) for candidate checks.
