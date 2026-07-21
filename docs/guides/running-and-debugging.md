# Running and debugging

The Kernel line currently runs from a repository checkout through Mix. The
planned standalone macOS command and Docker image will delegate to the same
manifest, execution, result, and trace paths.

## Run a manifest

```console
mix ptc.run ptc.json
mix ptc.run ptc.json --trace traces/run.jsonl
mix ptc.run ptc.json \
  --trace traces/run.jsonl \
  --inspect traces/run.inspection.jsonl
```

`--inspect` is a host opt-in development feature. It writes a separate bounded
owner-only artifact containing sensitive execution details. Do not publish it
with normal traces.

The current 0.x `--mission PATH` option replaces the manifest input file. Its
name is historical and is planned to become `--input` without a compatibility
alias before the standalone command contract is released.

## Understand results and errors

A successful command prints a JSON projection containing:

- `value` — the public workflow result;
- `usage` — remaining time, capability calls, evaluations, protocol errors,
  closure state, and dropped events;
- `evaluation_memory` — counts and retained byte totals, never retained values.

Capability failures normally cross into PTC-Lisp as recoverable envelopes. The
workflow decides whether to retry, correct, degrade, or fail. Parser, compiler,
timeout, heap, source, result, quota, provider, and event failures retain
bounded classifications at the Kernel boundary.

Current Mix failures are intended for people working from the repository and
may contain inspected Elixir terms. Stable JSON command errors and exit codes
are release work for the shared standalone `ptc` frontend.

## Use workflow REPL sessions

Start a direct session or reuse a manifest's frozen workflow environment:

```console
mix ptc.repl
mix ptc.repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc.repl --manifest ptc.json
mix ptc.repl --manifest ptc.json --trace traces/repl.jsonl
```

Definitions and the three most recent ordinary successful values persist for
one session. Failed forms keep the previously committed state. See the
[Kernel REPL guide](kernel-repl.md) for scripts, stdin, JSONL output, resource
limits, and lifecycle details.

## Query canonical traces

Normal traces contain bounded operational events and omit prompts, model
responses, capability arguments/results, and generated source. Query an
immutable directory capture through the fixed log-analysis profile:

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=traces \
  -e '(log/runs {})' \
  -e '(log/counters {})'
```

Useful functions are:

```clojure
(log/runs {})
(log/run "run-id")
(log/turns "run-id" {"limit" 100})
(log/counters {})
```

The captured files, session code, results, and analysis trace have independent
byte ceilings. The profile has no access to private inspection data or to the
active run that produced the traces.

## Use private inspection deliberately

Pass both output paths when exact development diagnostics are required:

```console
mkdir -p tmp/inspection
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --trace tmp/inspection/run.jsonl \
  --inspect tmp/inspection/run.inspection.jsonl
```

The inspection path is selected by the host command, not by the manifest or
PTC-Lisp. Capture is fail closed and the file uses owner-only permissions.
Canonical trace queries never join its payloads into ordinary results.

The credential-free [Kernel inspection lab](../../examples/kernel-inspection-lab/README.md)
creates correlated canonical and inspection artifacts without a live model.

## Development Viewer

From the repository root, after creating the trace directory:

```console
mix ptc.viewer --trace-dir tmp/inspection \
  --inspection-file tmp/inspection/run.inspection.jsonl
```

The Viewer binds to loopback, pins the selected inspection file, and can enable
a bounded log-analysis REPL over an immutable trace capture. It is currently a
development/test path dependency and is not included in the published Hex
package. Treat this command as source-checkout tooling until standalone Viewer
packaging is released.

See [`ptc_viewer/README.md`](../../ptc_viewer/README.md) for the Viewer's HTTP
API, configuration, and programmatic start/stop.

## Test a workflow

Keep a deterministic fixture in normal tests. Compare the stable business
value and semantic error classification rather than timestamps, generated run
IDs, or remaining milliseconds.

Live provider tests are separate and credentialed:

```console
mix test test/ptc_runner/kernel/tutorial_examples_e2e_test.exs --include e2e
```

Do not make correctness depend on an unconstrained natural-language completion.
