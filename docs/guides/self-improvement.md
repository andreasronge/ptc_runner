# Let an agent improve its own workflow

Run a debugging workflow that repairs its own navigation helper, the component
that reads a failed run's captured evidence before any model call. The repaired
helper then diagnoses and fixes an application. You end with a checked candidate
for each fix and the source files you started with.

## Run the example

Initialize a fresh copy and run the script with your OpenRouter environment
file:

```console
ptc init debug-a-failed-run --example debug-a-failed-run
sh debug-a-failed-run/run-self-improvement.sh /absolute/path/to/.env
```

The script captures two failures, lets an agent repair the helper, checks that
helper on two captures without a model, and then diagnoses and repairs the
application. A successful run ends with:

```text
Completed: helper checks, trace navigation, and three application validation cases. Artifacts: self-improvement-results
```

Model runs vary. The script stops at the first failed stage and leaves its
artifacts in `self-improvement-results`.

## Read the proposed edit

Print the component the agent chose and its explanation:

```console
ptc repl --project debug-a-failed-run/self-improver.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended \
  -e '(let [r (first (get (analysis/runs {"status" "ok"}) "items"))] (select-keys (get-in (analysis/open (get r "run_id")) ["result" "value"]) ["component_id" "cause"]))'
```

```text
{"cause" "debug.start/context blindly selected the first relationship from generated_sources without checking rel, state, or filters, attempting to follow an unavailable relationship" "component_id" "debug.start"}
```

Add "candidate_source" to the key list to print the replacement source. The
example README explains what navigation means, shows what the agent saw before
it wrote that edit, and inspects the application fix the same way.

See [debug navigation](../reference/debug-navigation.md) for the evidence
contract and [components](../reference/component-contracts.md) for how a
candidate is checked.
