# Kernel REPL

`mix ptc.repl` provides deliberately different PTC-Lisp session modes:

- direct and manifest-backed sessions are workflow scratchpads;
- `log-analysis-v2` is a fixed mission session for querying an immutable
  capture of canonical traces; and
- `inspection-analysis-v2` is a fixed private mission session for correlating
  canonical traces with exact private inspection evidence.

All modes retain successful definitions and exact `*1`, `*2`, and `*3`
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

The planned stable manifest mode adds `--host-config HOST.json` and resolves it
through the same bounded trusted-installation path as `mix ptc.run`. A manifest
that selects a provider requires this option; a provider-free manifest may omit
it. Direct sessions and code-owned profile modes reject it. The current REPL
does not yet accept this option; these rules record the release contract rather
than a currently usable command combination.

An interactive session also accepts a few meta-commands:

```text
:doc <name>       Show core function documentation
:find <pattern>   Search the available function surface
:help             List the session commands
```

The full language surface is in the
[PTC-Lisp specification](../ptc-lisp-specification.md) and
[function reference](../function-reference.md).

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

The planned stable manifest-backed frontend will treat a private manifest
result as interactive authority, not ordinary stdout. It will require an
attached terminal and the explicit `--private-terminal` grant during
destination preflight, after manifest classification but before audited-local
checks or opening a provider session. It will reject `--eval`, `--load`,
positional scripts, stdin, `--format jsonl`, and detached execution at that same
boundary with `provider_activity: false` and no provider work. Returned private
values and prints may reach only that authorized terminal; they never enter the
JSONL stream or an unauthorized stdout sink. The current manifest mode does not
yet accept this grant; this paragraph records the release contract, not a
currently usable option combination.

## Log-analysis mission sessions

Select the code-owned profile and supply its required trace resource:

```bash
mix ptc.repl \
  --profile log-analysis-v2 \
  --resource traces=tmp/tutorial-traces
```

The `traces` value must name one normal directory of canonical sanitized JSONL
files. The task captures it immutably when the session starts. The caller
cannot select the profile's component, capabilities, limits, mission data,
labels, persistence policy, or result projection.

`log-analysis-v2` installs `cap`, `log.core`, and `log.analysis`. It grants
only:

- `trace-list-runs` through `log/runs`;
- `trace-get-run` through `log/run`;
- `trace-list-turns` through `log/turns`;
- `trace-counters` through `log/counters`.

The four `log/*` functions return one bounded page. Use the matching analysis
functions when you need the complete selected result:

```clojure
(log.analysis/all-runs {"limit" 50} 10)
(log.analysis/all-turns "run-id" {"limit" 100} 20)
```

The final argument is an explicit page bound. Results contain `items`, `pages`,
`complete?`, and the source `snapshot_hash`. `complete?` is `true` only when
the source was exhausted; a page-bound stop returns the collected prefix with
`complete? false`. Invalid or rejected source queries fail the form instead of
returning an error map that can be mistaken for an empty result.

Ordinary bounded mission introspection such as `(tool/runtime-usage {})` and
`(tool/cap-list {})` is also available. Filesystem, network, LLM, agent,
workflow, MCP, private-inspection, and nested evaluation authority is absent.

One session can build up an investigation interactively:

```clojure
(def runs (log.analysis/all-runs {"limit" 50} 10))
(def items (get runs "items"))
(def ok-runs (filter #(= "ok" (get % "status")) items))
(map #(select-keys % ["run_id" "duration_ms" "mission_capability_calls"])
     ok-runs)
(def slowest (first (sort-by #(get % "duration_ms") > items)))
(log.analysis/all-turns (get slowest "run_id") {"limit" 100} 20)
```

Loaded files, repeated `--eval` forms, positional scripts, stdin, and
interactive forms all use the same mission continuation and aggregate budget.

Each of those source inputs is bounded by the profile's
`subordinate_source_bytes` limit before evaluation. Oversized load files,
scripts, stdin, and accumulated interactive forms are rejected without first
reading an unbounded source into the Mix task.

```bash
mix ptc.repl \
  --profile log-analysis-v2 \
  --resource traces=tmp/tutorial-traces \
  -e '(def runs (log/runs {}))' \
  -e '(count (get runs "items"))'
```

`return` and `fail` are per-form outcomes in this human session. They do not
close it. A terminal deadline or Kernel budget prevents later forms; normal
close still finalizes the session trace with the authoritative terminal reason.

## Private inspection mission sessions

Use the private profile only on an attached terminal, and explicitly authorize
that terminal as the private result sink:

```bash
mix ptc.repl \
  --profile inspection-analysis-v2 \
  --resource traces=tmp/tutorial-traces \
  --resource inspection=tmp/tutorial-inspection \
  --session-trace-dir tmp/analysis-traces \
  --private-terminal
```

The profile checks both terminal attachment and `--private-terminal` before it
opens either source directory. Its `traces`, `inspection`, and analysis-trace
directories must be physically separate, including through ancestors and
symlink aliases. Inspection capture validates every private artifact against
the corresponding run in the immutable canonical trace capture; malformed,
replaced, uncorrelated, or oversized input rejects the whole private source.

`inspection-analysis-v2` installs both core query components, both analysis
layers, and their shared `cap` dependency. Alongside the ordinary `log/*`
functions, it exports one-page private queries:

- `inspection/runs`;
- `inspection/model-exchanges`;
- `inspection/capability-calls`;
- `inspection/generated-sources`;
- `inspection/effective-preludes`; and
- `inspection/provider-exchanges`.

Each collection returns an opaque `next_cursor` for a later page. The
`inspection.analysis/*` namespace provides bounded whole-result variants:

- `inspection.analysis/all-runs`;
- `inspection.analysis/all-model-exchanges`;
- `inspection.analysis/all-capability-calls`;
- `inspection.analysis/all-generated-sources`;
- `inspection.analysis/all-effective-preludes`; and
- `inspection.analysis/all-provider-exchanges`.

For example:

```clojure
(def runs (inspection.analysis/all-runs {"limit" 20} 10))
(def run-id (get (first (get runs "items")) "run_id"))
(inspection.analysis/all-model-exchanges run-id 10)
(inspection.analysis/all-generated-sources run-id 10)
(inspection.analysis/all-provider-exchanges run-id 10)
```

Exact model messages, generated source, capability arguments/results,
effective preludes, and MCP request/response bodies may appear on the
authorized terminal. They are private data: do not paste or redirect them to a
public sink.

The initial private frontend is intentionally interactive-only. It rejects
`--eval`, `--load`, positional scripts, stdin, `--format jsonl`, and
`--continue-on-error`. Its separate canonical analysis trace records only safe
profile identity, hashes, sizes, timing, outcomes, and usage. It never records
the evaluated REPL source, returned private value, prints, or retained REPL
history.

### Separate analysis traces

Terminal profile sessions never write their analysis trace into the captured
input tree. Supply an existing physically separate output directory:

```bash
mix ptc.repl \
  --profile log-analysis-v2 \
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
  --profile log-analysis-v2 \
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
   `input_kind`, and the bounded `AnalysisSession` result projection;
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
  --profile log-analysis-v2 \
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
mix ptc.repl --describe-profile log-analysis-v2
mix ptc.repl --describe-profile log-analysis-v2 --format jsonl
```

The description lists the required resources, complete component closure,
callable namespaces, capabilities, fixed limits, and policies. It contains no path, snapshot,
callback, process identifier, source, or credential.

## Next steps

- [Running and debugging](running-and-debugging.md) owns the run command,
  result shape, trace capture, private inspection capture, and the Viewer. For
  a manifest entry run rather than a REPL session, use
  `mix ptc.run MANIFEST --trace PATH`.
- [Manifests and capabilities](manifests-and-capabilities.md) documents the
  manifest that `--manifest` sessions attach to, and the trace and inspection
  snapshot providers these profiles read.
- [Components and preludes](components-and-preludes.md) explains the core and
  analysis components these profiles install, dependency closure, and how to
  package your own analysis functions the same way.
- Hosts driving `PtcRunner.Kernel.ReplSession` programmatically should read
  [Embedding in Elixir](embedding-in-elixir.md) for its ownership rules.
