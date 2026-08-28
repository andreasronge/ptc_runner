# AGENTS.md

This project runs on the `ptc` executable. Ask the installed binary for the
exact contract instead of guessing; its answers always match its own version
and need no network. Inside this repository the same commands are `mix ptc …`.

## Find the exact contract

- `ptc help` lists every command; `ptc help COMMAND` gives its switches.
- `ptc docs` lists every shipped document; read `ptc docs agent-guide` first.
- `ptc repl --project ptc-project.json -e '(doc "name")'` documents one function, and
  `ptc repl --project ptc-project.json -e '(apropos "term")'` searches the available language surface.

## Files here

- `ptc.json` — the application: workflow, input, providers, missions, limits.
- `workflow.clj` — the workflow entry (`dabstep.workflow/run`), a thin wrapper
  over the shipped `agent.core` loop.
- `payments.clj` — the `analysis` mission component. It grants exactly two
  prompt-visible functions, `fraud-definition` and `read-page`; the raw MCP
  read is mapped `"model_visible": false`.
- `ptc-project.json` / `ptc-host.json` — live paths, artifacts, and the
  installed providers (two OpenRouter models plus the pinned filesystem MCP
  server). Pass the project document to commands so they do not depend on the
  current directory.
- `ptc-project.replay.json` / `ptc-host.replay.json` — the same application
  against `replay.jsonl`, so it runs with no model credential.
- `input.schema.json`, `result.schema.json`, `inputs/*.json` — the contracts
  and the two shipped inputs.
- `fetch-data.sh` — downloads and checksum-verifies `data/payments.csv` and
  the reference files. It does not reshape the data.
- `evidence/` — committed run records. Read `README.md` before citing them.

## Working loop

```console
./fetch-data.sh
ptc validate ptc-project.json
ptc run ptc-project.replay.json --input inputs/luna.json --envelope out.json
```

Parse `out.json` rather than scraping stdout. Keep credentials in an exact
environment file passed with `--env-file`; never place a secret in `ptc.json`,
in a component, or in a prompt.

## Analyzing a run

Never parse traces, inspection records, or run results with `jq`/Python — go
through `ptc`, which knows the query vocabulary the raw files do not expose.
Both resources are required:

```console
ptc repl --profile private-run-analysis-v1 --private-unattended \
  --resource traces=.ptc/traces --resource inspection=.ptc/inspection \
  --format jsonl -e '(analysis/runs {})'
```

`analysis/open`, `analysis/read`, and `analysis/counters` take a run id from
that listing; `ptc repl --describe-profile private-run-analysis-v1` prints the
contract. Use `ptc transcript RUN_REF` for one run's private transcript, and
send its `--private-output` outside `.ptc/` — `ptc` owns that whole directory
and writing into it makes later runs fail `envelope/publication_failed`.

Runs recorded before the fixed-point cost migration (`0de15a10`) that reported a
model cost no longer load, by design — 0.x keeps no read compatibility for a
superseded representation. Delete stale artifacts rather than working around
them. A damaged file used to block healthy runs in the same directory; #1668 is
fixed on `main`, so a damaged artifact is now isolated. See the reverification
note in `evidence/current-main-smoke.json`.
