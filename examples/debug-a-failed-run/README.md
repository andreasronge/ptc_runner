# Improve a debugging workflow

An agent repairs a broken navigation helper, then uses the improved workflow
to investigate an application and propose a separately validated repair.

## Run the story

Start with a fresh materialized example and an OpenRouter environment file:

```console
ptc init debug-a-failed-run --example debug-a-failed-run
sh debug-a-failed-run/run-self-improvement.sh /absolute/path/to/.env
```

The self-improvement hosts select `openrouter:google/gemini-3.8-flash`. Change
that model in `self-host.json` and `self-improver-host.json` to compare another
model. Keep credentials outside the example.

The script runs five stages:

1. Capture the application failure and a debugging-workflow failure.
2. Ask an agent to inspect the debugging trace and repair its helper.
3. Check that helper on two different captured applications, without model calls.
4. Use the improved workflow to navigate generated code, source, and dependencies.
5. Propose the application repair and run three validation cases.

A successful run ends with:

```text
Completed: helper checks, trace navigation, and three application validation cases. Artifacts: self-improvement-results
```

The starting bug is intentional: `debug.start/context` chooses the first
relationship, although its contract requires a complete source relationship.
This gives the example a reproducible failure. The correcting agent receives
that workflow's captured evidence and must propose the edit itself. No
application-specific answer is included in its prompt.

The script stops when a stage fails. Keep its artifacts to investigate that
stage; use a new initialized directory for another full run.

## Inspect what happened

Read the helper proposal through PTC:

```console
ptc repl --project debug-a-failed-run/self-improver.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 6000 \
  -e '(let [r (first (get (analysis/runs {"status" "ok"}) "items"))] (get-in (analysis/open (get r "run_id")) ["result" "value"]))'
```

Use `self-debugger.ptc-project.json` to inspect the investigation, or
`self-repair.ptc-project.json` for the application proposal. Discover the
collections through `analysis/open`, then read `turns`, `generated_sources`,
`prelude_sources`, and `capability_calls` with `analysis/read`.

The stage projects enable private inspection in the Viewer.

All proposals, checks, and validated results are also retained under
`self-improvement-results`. The source files remain unchanged; later runs
select the candidate descriptors explicitly.

## Why the workflow uses small edits

`repair.edit/propose` accepts exact before/after fragments and copies the frozen
source hash and unchanged bytes itself. Missing or repeated fragments return
an error the agent can correct. This prevents source-copy mistakes from being
mistaken for successful improvements. The candidate still has to compile and
pass independent checks.

The helper check compares actual source pages on pricing and fulfillment
captures. The application cases check the observed order and two inputs that
the repairing agent did not receive. These checks provide evidence for this
example, not a general debugging success rate.

## One recorded run

A fresh run with Gemini 3.8 Flash completed the full chain in 21 model calls
for a reported $0.087639. Model choice affected earlier investigation tests;
this is evidence for the example, not a general success-rate claim.

See [the annotated walkthrough](WALKTHROUGH.md) for the critical observations,
exact generated code excerpts, checks, and model-comparison limits.

## Smaller examples

The same directory retains the original pieces for individual experiments:

| Project | Purpose |
| --- | --- |
| `debugger.ptc-project.json` | Walk the captured dependency graph without a model. |
| `debugger-agent.ptc-project.json` | Let an agent choose which trace and source records to read. |
| `repair-agent.ptc-project.json` | Propose a repair from a host-built incident packet. |
| `target-ambiguous.ptc-project.json` and matching agents | Exercise a case with no contract distinguishing the conflicting expectations; the correct decision is abstention. |
| `target-workflow-control.ptc-project.json` and matching agents | Exercise a defect in the workflow connecting two missions. |

For the checkout-only suite runner, use `mix help ptc.repair`; the repair folder
contains component and workflow suites. Standalone users can materialize a
proposal with `ptc materialize --from-result` and select its descriptor on
explicit `ptc run` cases, as the script does.

See `ptc docs debug` for evidence boundaries and the example's edit
helper contract, `ptc docs repl` for private analysis, and
`ptc docs components` for candidate checks.
