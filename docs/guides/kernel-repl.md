# Kernel REPL

`mix ptc.repl` provides two deliberately different PTC-Lisp session modes:

- direct and manifest-backed sessions are workflow scratchpads;
- `log-analysis-v1` is a fixed mission session for querying an immutable
  capture of canonical traces.

Both modes retain successful definitions and exact `*1`, `*2`, and `*3`
history for one command. Failed forms preserve the previously committed state.
A successful evaluation is installed before its terminal event is recorded; if
that fail-closed event write fails, the returned session reflects the committed
continuation and is terminally closed instead of exposing a competing stale
copy.
They do not share authority: selecting a profile is mutually exclusive with a
manifest.

## Direct workflow sessions

Start an interactive session, repeat expressions, load setup code, or evaluate
one script:

```bash
mix ptc.repl
mix ptc.repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc.repl -l setup.clj
mix ptc.repl script.clj
mix ptc.repl - < script.clj
```

Use the same strict manifest as `mix ptc.run` to attach a frozen workflow
bundle, workflow capabilities, limits, input, labels, and event policy:

```bash
mix ptc.repl --manifest ptc.json
mix ptc.repl --manifest ptc.json -e '(workflow/helper data/input)'
```

The direct REPL does not accept an ambient capability catalog or arbitrary
profile configuration. Providers and component sources are selected only by
the manifest and trusted provider registry.

Elixir hosts using `PtcRunner.Kernel.ReplSession` directly must keep each
session in the process that created it. That process performs every evaluation
and the final close or abort. Sending the struct to another process does not
transfer its continuation or cleanup authority; `eval/2`, `close/1`, and
`abort/2` return `{:error, :session_owner_mismatch}` without changing the
session. The public value contains an opaque ID resolved through a shared table
only the creator can read; closed entries are deleted. It contains no owner PID,
token, continuation value, or raw run-state, configuration, sink, or provider
capability. The internal owner binds the run state to the configured event and
optional inspection sinks. Each `eval/2` result is an inert observation
projection; its memory is not the authoritative continuation and must not be
threaded back into the session.
Preflight errors preserve that committed public memory view, and projection is
validated before continuation commit. Each bounded worker starts a small
monitor-only watchdog before running the workload. The watchdog cancels the
worker when the creator exits, without changing its trap-exit behavior or
holding an unbounded workload copy, before retained resources are closed.

Every workflow session emits canonical Kernel events. Persist them as bounded,
append-only JSONL with:

```bash
mix ptc.repl --trace trace.jsonl
mix ptc.repl --manifest ptc.json --trace trace.jsonl
```

Private event policies require an explicit private manifest selection; the
REPL requires the reserved `.private.jsonl` suffix and restricts the file to
owner read/write permissions before appending event data. Normal directory
grants and the Viewer do not discover private-suffixed traces.

## Log-analysis mission sessions

Select the code-owned profile and supply its required trace resource:

```bash
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces
```

The `traces` value must name one normal directory of canonical sanitized JSONL
files. The task captures it immutably when the session starts. The caller
cannot select the profile's component, capabilities, limits, mission data,
labels, persistence policy, or result projection.

`log-analysis-v1` installs the shipped `log.core` component, whose exported
namespace is `log`. It grants only:

- `trace-list-runs` through `log/runs`;
- `trace-get-run` through `log/run`;
- `trace-list-turns` through `log/turns`;
- `trace-counters` through `log/counters`.

Ordinary bounded mission introspection such as `(tool/runtime-usage {})` and
`(tool/cap-list {})` is also available. Filesystem, network, LLM, agent,
workflow, MCP, private-inspection, and nested evaluation authority is absent.

One session can build up an investigation interactively:

```clojure
(def runs (log/runs {}))
(def items (get runs "items"))
(def ok-runs (filter #(= "ok" (get % "status")) items))
(map #(select-keys % ["run_id" "duration_ms" "mission_capability_calls"])
     ok-runs)
(def slowest (first (sort-by #(get % "duration_ms") > items)))
(log/turns (get slowest "run_id") {"limit" 100})
```

Loaded files, repeated `--eval` forms, positional scripts, stdin, and
interactive forms all use the same mission continuation and aggregate budget.

Each of those source inputs is bounded by the profile's
`subordinate_source_bytes` limit before evaluation. Oversized load files,
scripts, stdin, and accumulated interactive forms are rejected without first
reading an unbounded source into the Mix task.

```bash
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  -e '(def runs (log/runs {}))' \
  -e '(count (get runs "items"))'
```

`return` and `fail` are per-form outcomes in this human session. They do not
close it. A terminal deadline or Kernel budget prevents later forms; normal
close still finalizes the session trace with the authoritative terminal reason.

### Separate analysis traces

Terminal profile sessions never write their analysis trace into the captured
input tree. Supply an existing physically separate output directory:

```bash
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --session-trace-dir tmp/analysis-traces \
  -e '(log/counters {})'
```

Without `--session-trace-dir`, the task creates a private `0700` directory
under the operating system temporary directory. On close it reports the
absolute `<log-analysis-id>.jsonl` path. The file is published atomically,
never appended, and contains the profile ID and effective digest. Evaluated
source and exact trace-query payloads are not copied into canonical events.

The output directory cannot be the input directory, an ancestor or descendant
of it, or the same physical directory through symlinked parents.

### JSON Lines for coding agents

Coding agents can avoid PTY and prompt handling by repeating `-e` with
`--format jsonl`:

```bash
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --session-trace-dir tmp/analysis-traces \
  --format jsonl \
  -e '(def runs (log/runs {}))' \
  -e '(count (get runs "items"))'
```

Every task-emitted stdout line is one JSON object. Records use schema version 1
and, when their corresponding lifecycle stage is reached, appear in this order:

1. one `session-started` record after successful session construction;
2. one `evaluation` record per accepted source, containing `index`,
   `input_kind`, and the bounded `LogAnalysisSession` result projection;
3. one `session-closed` record only after successful close and persistence,
   containing the persisted `trace_path`;
4. a final `command-error` for an unsuccessful command, with category `cli`, `setup`,
   `evaluation`, `lifecycle`, `persistence`, or `frontend`.

Validation and setup failures can therefore produce only `command-error`;
persistence failure follows any started/evaluation records without claiming a
successful `session-closed` record.

The task adds no raw source field or independent source copy. Returned values,
prints, and bounded evaluator messages remain intentional public feedback and
may naturally contain text also present in a program.

JSONL is non-interactive only. Any command error makes the Mix process
unsuccessful. To collect feedback from later expressions after a recoverable
form error, use `--continue-on-error` with at least two `-e` arguments:

```bash
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=tmp/tutorial-traces \
  --format jsonl \
  --continue-on-error \
  -e '(def runs (log/runs {}))' \
  -e 'missing-name' \
  -e '(count (get runs "items"))'
```

Later forms see the state committed before the failed form. The session closes
and persists normally, but the final process status remains non-zero because a
requested evaluation failed.

Inspect the safe static contract without capturing traces or starting a
session:

```bash
mix ptc.repl --describe-profile log-analysis-v1
mix ptc.repl --describe-profile log-analysis-v1 --format jsonl
```

The description lists the required resource, component, namespace,
capabilities, fixed limits, and policies. It contains no path, snapshot,
callback, process identifier, source, or credential.

For a manifest entry run rather than a REPL session, use
`mix ptc.run MANIFEST --trace PATH`.
