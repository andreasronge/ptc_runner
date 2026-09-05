# Repair showcase verification

Maintainer record for the 2026-09-04 refresh of `examples/debug-a-failed-run`.
The final example leads with a model-authored debugging-helper improvement,
then navigation and independently validated application repair. See
[the completed chain and packaging evidence](recovery-story/README.md).
The experiments below explain the choices; they are retained development
records rather than the current operator instructions.

## Repair measurements

Runtime: main at `ef72c0e9`, version 0.14.0. Three model runs per incident,
one frozen failed capture per incident, `openrouter:deepseek/deepseek-v4-flash`,
temperature 0, cache disabled. The repair manifest and prompt were unchanged.
The initial runs used the checkout frontend; capture analysis and subsequent
candidate trials used `ptc 0.14.0 (ef72c0e9, clean)` on PATH.

| Incident | Expected decision | Observed | Model calls per run |
| --- | --- | --- | --- |
| Component defect | propose `pricing.rule` in mission `pricing` | 3/3 | 1, 1, 1 |
| Ambiguous charges | abstain | 3/3 | 1, 1, 1 |
| Workflow routing | propose workflow `main` | 3/3 | 1, 2, 1 |

All six proposals passed materialization and every case in their respective
three-case host-owned validation suite. The suites include the observed case
and two cases absent from the model's incident packet. One workflow proposal
needed a second turn after generating an unnecessary analysis program; it
then completed through the terminal action. Do not describe every run as a
first-call success.

Observed runtime was 27–94 seconds per repair run and reported cost was
$0.000326–$0.001087. These are fixture checks, not estimates of general repair
reliability. Three samples from one capture do not establish robustness to
unseen failure shapes.

The standalone materialize-and-run path passed for a workflow proposal.
Reusing its descriptor with `next-order.json` returned
`reservation:order-204` for `east-depot`. The deterministic integration test
also checks that a candidate memorizing the original answer passes the
observed case but fails both independent cases. It verifies the installed
workflow source remains unchanged.

## Reproduce and inspect through PTC

Use an executable containing the refreshed example, and an environment file
outside the materialized directory:

```sh
: "${ENV_FILE:?Set ENV_FILE to your OpenRouter environment file}"
ptc init debug-a-failed-run --example debug-a-failed-run
mkdir -p debug-a-failed-run/review
for suffix in '' -ambiguous -workflow-control; do
  ptc run "debug-a-failed-run/target${suffix}.ptc-project.json"
  # Each target exits 5 by design; record the failure before continuing.
  for sample in 1 2 3; do
    ptc run "debug-a-failed-run/repair-agent${suffix}.ptc-project.json" \
      --env-file "$ENV_FILE" --progress \
      --private-output "debug-a-failed-run/review/repair${suffix}-${sample}.private.json"
  done
done
```

Use `mix help ptc.repair` for the checkout suite command and the suites in
`examples/debug-a-failed-run/repair-agent/`; use a new candidate and validation
directory for each proposal. The ambiguous reports have no
candidate. Keep every outcome; do not replace a failed sample with a retry
when reporting rates.

Discover the analysis interface through `ptc help repl` and `ptc docs repl`.
This query obtains verdicts from the correlated capture, without parsing logs
or inspection records outside PTC. Change the project to inspect another arm:

```sh
ptc repl \
  --project debug-a-failed-run/repair-agent-workflow-control.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 12000 \
  -e '(mapv (fn [r]
        (let [o (analysis/open (get r "run_id"))]
          (merge
            (select-keys (get o "run")
              ["run_id" "status" "terminal_reason" "llm_calls" "llm_spend" "duration_ms"])
            (select-keys (get-in o ["result" "value"])
              ["decision" "component_id" "cause" "target_environment"]))))
        (get (analysis/runs {}) "items"))'
```

For a failed investigation, select its run with `--run RUN_ID`, discover
collections through `(analysis/open "RUN_ID")`, and read `execution_errors`
and `turns`. `ptc transcript RUN_ID` successfully exported a complete repair
conversation to a sibling private output directory in this verification.

## Friction encountered

- The navigation example's 20-turn budget could exceed the default 256 retained
  events. All three initial component investigations hit the event ceiling;
  one had already generated the correct final diagnosis. The current runtime
  kept the captures and reported `event_capture_limit_exceeded`, making this
  diagnosable through PTC. The example now requests 1,024 events, within the
  installed default ceiling of 4,096.
- A navigation project whose artifact parent directory did not exist failed
  with `envelope/publication_failed`. That diagnostic did not explain the
  missing parent. Reproduce without a model by changing the deterministic
  target project's `artifacts.root` to `missing-artifact-parent/.ptc`, leaving
  that parent absent, and running `ptc run PROJECT`. The two new navigation
  variants now ship their artifact parent directories. Improving that
  diagnostic is a possible follow-up.
- `ptc docs repl` claimed `--project` conflicted with `--profile`, while its
  analysis examples combined them. The combination worked on PATH; this
  refresh corrects the reference and generated page.
- The full validation runner is checkout-only `mix ptc.repair`; root help
  correctly has no `ptc repair`. Standalone users can materialize and run
  candidates, but cannot run that suite through an equivalent stable command.
  Exposing the existing suite workflow remains a possible follow-up.

The broad nightly suite additionally needs `examples/dabstep-fraud/fetch-data.sh`
to be run from that example directory. Worktree initialization did not fetch
its dataset; the four replay regressions initially failed with
`mcp_transport_error`. `ptc doctor ... --connect` identified the failing
`payments_data` provider but only reported `provider_unavailable`. Fetching
the pinned dataset supplies the required MCP root.

The event-budget change does not guarantee completion or correct attribution.
Navigation can still exhaust its turn or model-output budget. A source-backed
report is a claim; the host-owned validation remains the acceptance evidence.

## Navigation investigation

### Model comparison findings

Each row contains three samples per incident. Counts measure the expected
decision and named component, not every assertion in the explanation.

| Configuration | Component | Workflow | Ambiguous abstention | Expected verdicts |
| --- | --- | --- | --- | --- |
| DeepSeek, original 2,048-character observations | 3/3 | 2/3 | 2/3 | 7/9 |
| DeepSeek, 8,192-character observations | 3/3 | 3/3 | 0/3 | 6/9 |
| DeepSeek, 8,192 characters plus consolidation | 3/3 | 3/3 | 2/3 | 8/9 |
| Gemini 3.8 Flash, same larger-window configuration | 3/3 | 3/3 | 3/3 | 9/9 |
| DeepSeek, focused-source helper with original 2,048 characters | 2/3 | 1/3 | 1/3 | 4/9 |

Every other outcome was unfinished rather than a completed wrong-component
verdict. One consolidated DeepSeek abstention nevertheless asserted that
constant charges violate the docstrings, which do not establish that rule.
Its abstention was appropriate but that extra claim was unsupported. Gemini's
three abstentions correctly identified the missing pricing contract.

Gemini 3.8 Flash produced the expected verdict in all nine trials: three
component diagnoses, three workflow diagnoses, and three abstentions on the
ambiguous incident. Its explanations identified the actual contract violation
or the missing contract; checking only the named component would be weaker.
It used 9–14 calls, took 20–41 seconds, and reported $0.031–$0.055 per run.
These are three samples of each frozen incident, not a general reliability
estimate. Provider latency and caching can affect both time and reported cost.

The workflow's shortest Gemini trace shows genuine navigation: list runs,
open the failed run, inspect execution errors and explicit failure values,
read generated programs, follow source relationships, read component and
workflow sources, inspect activity, then diagnose the incorrect reservation
identifier. The agent was not given a preassembled incident packet.

All Gemini runs finished before the six-turn consolidation threshold would
activate. This supports a model effect rather than crediting the wrap-up
reminder. At the same 8,192-character setting, DeepSeek's workflow runs took
14–18 calls without consolidation and 14–18 with it; consolidation did not
show a clear benefit in these small samples.

The larger observation budget eliminated preview truncation in the inspected
DeepSeek cells. It did not eliminate unfinished ambiguous investigations.
Gemini still encountered one truncated preview in two component trials, so
8,192 characters is not a universal fix for bulky evidence pages.

DeepSeek's larger-window runs took 140–376 seconds without consolidation and
125–518 seconds with it, at reported costs of $0.0031–$0.0088 across both arms.
The unconsolidated ambiguous failures were two model-output truncations and
one turn-limit failure. Consolidation left one model-output truncation. These
small samples suggest the reminder helps completion on that fixture, but do
not establish a general success-rate improvement.

The recommended next showcase shape is navigation, source-backed diagnosis,
repair proposal, independent validation, then reuse on a new input. Preserve
the ambiguous case: declining to patch without enough evidence is part of
the demonstration. Keep the packet-based repair path as a cheap comparison.
Do not promote the focused-source helper into a shipped prelude solely on its
smaller page size; its live comparison is separate below.

`run-navigation.py` prepares independent cells from an already captured
example. It copies the same evidence bytes into a new experiment directory,
then uses the installed `ptc` for validation and execution. It never parses a
trace, inspection record, or model result. Environment files remain external.

```sh
python3 scripts/labs/debug-repair-showcase/run-navigation.py \
  debug-a-failed-run tmp/navigation-comparison --env-file "$ENV_FILE" \
  --variant deepseek-8k --variant deepseek-8k-consolidate \
  --variant gemini-8k-consolidate --samples 3 --jobs 6
```

All cells keep the example's 20-turn prompt and result contract, request 1,024
retained events, and use a 4,096-token output budget. `deepseek-8k` changes only
the observation limit to 8,192 characters. The consolidation variant adds
`consolidate_at_turns_remaining: 6`. Gemini uses that same configuration with
`openrouter:google/gemini-3.8-flash`. The provider alias remains `deepseek` in
all cells to avoid changing the prompt's API vocabulary; `ptc models PROJECT`
shows the actual selector.

Analyze a cell using the supplied PTC-Lisp query:

```sh
ptc repl \
  --project tmp/navigation-comparison/deepseek-8k-workflow.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 16000 \
  scripts/labs/debug-repair-showcase/analyze-navigation.clj
```

The query counts feedback containing a truncated-preview warning and programs
containing `println`, alongside outcome, decision, model calls, time, and cost.
These counts describe presentation friction; they do not automatically judge
whether a diagnosis is correct. It reports whether the turn page was complete.

### Focused source-page prototype

`debug.view.clj` is a lab-only wrapper around `debug.nav/read` and
`debug.nav/follow`. It removes redundant item bookkeeping from generated and
prelude source pages. Source text, hashes, identities, typed relationships,
and page metadata remain unchanged. Other collections pass through intact.
It does not gather evidence automatically or decide which component is wrong.

The optional `deepseek-2k-view` variant selects that wrapper with the original
2,048-character observation budget and no consolidation. Its task tells the
model to use the focused read/follow functions, while leaving raw navigation
available. This measures the complete helper interface, including that short
instruction, rather than isolating a renderer change.

The deterministic `probe.ptc.json` compares both a source page and a followed
relationship against raw navigation. Supply the target run ID in a JSON input
object, and a host configuration installing that target's capture:

```sh
ptc run scripts/labs/debug-repair-showcase/probe.ptc.json \
  --host-config tmp/navigation-comparison/deepseek-8k-workflow.host.json \
  --input probe-input.json --private-output probe-result.private.json
```

The workflow-control probe preserved exact source, links, and page metadata.
Its generated-program page shrank from 2,135 to 1,849 characters, fitting the
2,048-character default. The programs themselves total only 152 characters.
This display-size improvement did not translate into better live performance:
the helper produced the expected verdict in 4/9 trials, with five turn-limit
failures. Eight runs used all 20 calls; the other used 18. Runs took 78–350
seconds and reported $0.0032–$0.0062 each. Every run still encountered truncated
previews (2–7 feedback messages). Source-page projection alone leaves other
large pages and model state-management mistakes unresolved. Keep this wrapper
in the lab rather than promoting it to the shipped prelude API.

One live helper trial exposed a separate problem: after inspecting the open
page, DeepSeek overwrote a saved variable from `*1` after its previous program
had already replaced history with a projection. It then spent several turns
probing the wrong value. The current agent prompt already documents retained
results and persistent definitions. A future domain-blind prompt comparison
could explicitly encourage binding a capability result and projecting it in
the same program, keeping that binding for later navigation, and batching
independent reads. This is an observed model-use problem, not evidence that
PTC lacks persistent state or needs automatic evidence gathering.

### Next self-improvement experiment

Use a failed navigation run as the input to a separate investigation. Have
the investigator cite the turns where evidence was lost or repeatedly fetched,
propose a domain-blind instruction or interface change, and retain the original
configuration as the control. Evaluate on new incidents, including a workflow
handoff error and an underdetermined case, before adopting the change. Measure
grounded verdicts, unfinished runs, calls, time, and cost; a shorter transcript
alone is not success. The current measurements identify candidates for this
experiment but do not demonstrate that automatic self-improvement has occurred.

The follow-up [coached navigation experiment](self-improvement/README.md) is now
complete: one Gemini-authored addendum was tested unchanged against the original
DeepSeek task on three new incidents. Both arms produced 4/9 supported answers;
the candidate was not adopted. That record includes the isolated training
capture, frozen input hashes, failures, and concrete follow-up API hypotheses.

The subsequent [navigation interface comparison](interface-testing/README.md)
tested documentation and recoverable-link variants on 27 new live runs.
Supported answers were 4/9 for control, 3/9 for docs, and 5/9 for recovery.
Neither targeted failure recurred, so the score difference does not establish
a recovery benefit. The deterministic recovery probe passed; neither variant
was adopted. All arms failed to abstain on unspecified metadata precedence.

The [one-decision replay](decision-replay/README.md) then tested twelve next
actions for $0.007155. Both recoverable-error messages led to working navigation
in all three samples. The ambiguity reminder produced more inspection, not a
verdict; an unchanged request also produced one invalid, incomplete abstention.
This supports cheap local screening without claiming end-to-end improvement.

The [bounded continuation](decision-continuation/README.md) gave those unfinished
ambiguity trials one final turn after restoring their captured state. Five new
calls cost $0.002858. The control finished with one supported abstention and two
unsupported diagnoses; the reminder finished with one unsupported diagnosis and
two missing actions. The incomplete control program recovered after PTC's parse
feedback, but the requirement reminder was not adopted.
