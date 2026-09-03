# AGENTS.md

This project runs on the `ptc` executable. Ask the installed binary for the
exact contract instead of guessing; its answers always match its own version
and need no network. Inside this repository the same commands are `mix ptc …`.

## Find the exact contract

- `ptc help` lists every command; `ptc help COMMAND` gives its switches.
- `ptc docs` lists every shipped document; read `ptc docs agent-guide` first.
- `ptc repl --project ptc-project.json --inspect-only -e '(doc "name")'`
  documents one function, and `-e '(apropos "term")'` searches the available
  language surface. Without `--inspect-only` the REPL asks for credentials.

## Files here

- `ptc.json` — the application: workflow, input, providers, missions, limits.
- `workflow.clj` — the workflow entry (`dabstep.workflow/run`): two blind
  derivations, one review, and the decision, all in workflow code.
- `review.clj` — shared by both workflows: the reviewer prompt, the filter that
  keeps successful REPL steps, and the deterministic comparison.
- `payments.clj` — the shared analysis/recheck/review mission component. It
  grants exactly two prompt-visible functions, `fraud-definition` and
  `read-page`; the raw MCP read is mapped `"model_visible": false`.
- `ptc-project.json` / `ptc-host.json` — live paths, artifacts, and the
  installed providers (two OpenRouter models plus the pinned filesystem MCP
  server). Pass the project document to commands so they do not depend on the
  current directory.
- `ptc-project.replay.json` / `ptc-host.replay.json` — the same application
  against `replay.jsonl`, so it runs with no model credential.
- `reviewer.ptc.json` and the `ptc-project.reviewer*.json` projects — fixed
  wrong-metric and off-by-one sessions for live or replayed reviewer checks.
- `input.schema.json`, `result.schema.json`, `inputs/*.json` — the contracts
  and two shipped model assignments: DeepSeek analyzers with a Luna reviewer,
  or Luna for all three stages.
- `record-replay.sh` — writes a replay fixture from the model exchanges a run
  recorded. Read the limitation below before relying on it.
- `fetch-data.sh` — downloads and checksum-verifies `data/payments.csv` and
  the reference files. It does not reshape the data.
- `evidence/` — committed run records. Read `README.md` before citing them.

## Working loop

```console
./fetch-data.sh
ptc validate ptc-project.json
ptc run ptc-project.replay.json --input inputs/deepseek.json --envelope out.json
```

Parse `out.json` rather than scraping stdout. The result value carries the
answer, whether the three measurements agreed, the top country each stage
found, and the reviewer's problems. Keep credentials in an exact environment
file passed with `--env-file`; never place a secret in `ptc.json`, in a
component, or in a prompt.

## Analyzing a run

Never parse traces, inspection records, or run results with `jq`/Python — go
through `ptc`, which knows the query vocabulary the raw files do not expose.
Both resources are required, and `--run` keeps the profile from loading every
run in the directory:

```console
ptc repl --profile private-run-analysis-v2 --private-unattended \
  --resource traces=.ptc/traces --resource inspection=.ptc/inspection \
  --format jsonl -e '(analysis/runs {})'
ptc repl --profile private-run-analysis-v2 --private-unattended \
  --resource traces=.ptc/traces --resource inspection=.ptc/inspection \
  --run RUN_REF --format jsonl \
  -e '(analysis/counters {"run_id" "RUN_REF"})' \
  -e '(analysis/read "RUN_REF" {"collection" "generated_sources" "mission_name" "review"})' \
  -e '(analysis/read "RUN_REF" {"collection" "execution_prints"})'
```

Collection filters are top-level keys of the options map, not a nested
`filters` map. `ptc repl --describe-profile private-run-analysis-v2` prints the
contract, and `(analysis/open "RUN_REF")` lists the collections with their
filters. Workflow `println` output appears only in the private
`execution_prints` collection; it is not on `ptc run` stdout, in the envelope,
or in the trace. Use `ptc transcript RUN_REF` for one run's private
transcript, and send its `--private-output` outside `.ptc/` — `ptc` owns that
whole directory and writing into it makes later runs fail
`envelope/publication_failed`.

Runs recorded before the fixed-point cost migration (`0de15a10`) that reported a
model cost no longer load, by design — 0.x keeps no read compatibility for a
superseded representation. Delete stale artifacts rather than working around
them. A killed run can leave empty `.ptc-private-*/artifact` files behind;
they are isolated (#1668) but never cleaned, so delete them too.

## Recording a replay fixture

`./record-replay.sh ARTIFACT_ROOT RUN_REF [RUN_REF ...] > fixture.jsonl` reads
every model exchange of the named runs through the analysis profile and
writes one fixture line per distinct request hash. `reviewer-replay.jsonl`
was written this way from two live Luna runs.

Exact matching means a recorded session replays only if nothing the model saw
depends on the machine or the server process. Two things do: `ptc-fs-mcp`
signs each `next_cursor` with a per-process key over a state digest that
includes the file's inode, so a program that prints a page puts a value in the
conversation that never recurs; and a heap kill reports the environment
baseline in bytes, which differs from run to run. Every run in the integrated
cohort printed a cursor on an exploratory turn, so `replay.jsonl` for the full
workflow is assembled instead: the final program of each stage from one live
Luna run, keyed to the hashes a placeholder fixture missed on. Read a miss's
hash from the failed replay run with
`(analysis/read RUN {"collection" "model_exchanges"})`; the item whose result
is not `ok` carries it.
