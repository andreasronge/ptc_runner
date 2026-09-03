# Viewer demo journeys

This maintainer lab runs from a source checkout; it is not a shipped example.
Five small manifest runs against the trusted `deepseek` model alias that
together produce enough varied trace data to exercise `ptc_viewer` by hand:
a mixed-status run picker, multi-turn model dialogue with error feedback and
recovery, real token/cost usage, bulk mission capability calls,
limit-exceeded events, and error-outcome runs. Requires
`OPENROUTER_API_KEY` in `.env`; the script selects that exact file with
`--env-file`. A full pass costs a few cents (≤ ~15 model calls). The script
enforces each journey's intended outcome class, checks
the advertised evidence (limit-exceeded events for journey 03, loop-limit
and heap-budget error feedback for journeys 04/05), and fails on missing
artifacts, so a passing run is a real smoke check.

```console
scripts/labs/viewer-demo/run.sh            # outputs to tmp/viewer-demo
scripts/labs/viewer-demo/run.sh /path/out  # or an explicit directory
```

The script regenerates the granted `files/` root, launches
`ptc-fs-mcp@0.1.0` through `ptc-host.json`, runs each journey with
`--trace-dir` and `--inspect` into one owner-only project artifact root, writes
each trace and inspection artifact under its generated run-reference filename,
the project document beside it, and prints the `mix ptc viewer` command that
opens it. Node.js, `npx`, and `jq` are required; the first run may download the
MCP package. A rerun removes only the generated artifacts recorded by the prior
pass, so the Viewer continues to contain exactly the five current journeys. That
project grants the Viewer the private inspection artifacts, so treat the
browser tab as a private sink.

## Journeys

| Journey | Design | Viewer surfaces exercised |
| --- | --- | --- |
| `01-recovery` | The task names `demo.files/parse-lines`, which does not exist, then instructs recovery via `demo.files/read-page`. Expect an `:unbound_var` evaluation error, a tool-role correction message, and a successful second turn. | Multi-turn dialogue, error feedback then recovery, source-hash verification, ok status. |
| `02-bulk` | The task calls `demo.files/sum-values`, which itself reads `index.txt` plus all 30 listed record files (31 `workspace.read` calls, just under the installed per-name quota of 32) and computes a sum the model cannot fabricate (3255). | Long capability lists in the transcript, per-call private payloads, deterministic bulk event volume (~76 events), ok status. |
| `03-limits` | Same task, but the manifest lowers `mission_capability_calls_per_name` to 6, so `sum-values` exhausts the quota mid-evaluation and the model receives the failure as feedback. | `limit-exceeded` events, error feedback turns, quota-error envelopes in private payloads. |
| `04-loop-limit` | The task calls `demo.files/spin-forever`, an unbounded `loop`/`recur`. The host enables `evaluation_loop_iterations` and this manifest narrows it to 1,000, so the activation fails with `:loop_limit_exceeded`. | Error-outcome runs in the picker, `:loop_limit_exceeded` feedback turns, `explicit_failure` terminal reason. |
| `05-memory` | The task calls `demo.files/exhaust-memory`, which doubles a string until the in-evaluator heap budget rejects it. A second turn retains that feedback in the dialogue; the dedicated workflow entry then fails the demo even if the model turns the failure into a successful prose result. | `:memory_exceeded` error feedback, error-outcome run, heap-budget message in the dialogue. |

The bulk read volume and journey 03's quota trigger are deterministic (the
reads happen inside the mission prelude, not at the model's discretion); turn
counts and journey 03's final status depend on how the model reacts to the
failure feedback.

## Known coverage gaps

These journeys cannot produce runs above 100 canonical events per run (the
installed per-name mission quota bounds capability volume), so the viewer's
multi-page turn fetching and the partial-run labeling are exercised only by
the synthetic fixtures in `ptc_viewer/test/ptc_viewer/dialogue_render_test.exs`.
Connector (MCP) fingerprints and zero-token scripted models are covered by
`scripts/labs/inspection-lab` instead.

Canonical `timeout` and process-level `memory_exceeded` evaluation statuses
are not reachable here: pure computation hits the deterministic loop and heap
budgets first (journeys 04/05), and a wall-clock evaluation timeout requires
a deliberately slow mission capability, which this demo does not grant.
