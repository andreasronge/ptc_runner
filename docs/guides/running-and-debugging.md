# Running and debugging

Use `mix ptc` in a source checkout and `bin/ptc` from the `ptc_runner`
release. Both frontends share the command grammar and runtime path. Run
`mix ptc help COMMAND` or `bin/ptc help COMMAND` for the exact accepted
switches.

## Choose a command

| Command | Purpose |
| --- | --- |
| `ptc init DIRECTORY` | Publish a validated minimal application without replacing an existing target |
| `ptc validate MANIFEST or PROJECT` | Load and compile without executing the workflow |
| `ptc run MANIFEST or PROJECT` | Execute the application entry |
| `ptc run MANIFEST --env-file FILE` | Load environment-backed credentials from this exact file |
| `ptc doctor [MANIFEST or PROJECT]` | Report application and provider readiness |
| `ptc models PROJECT.json` or `--host-config HOST.json` | List public installed model-alias declarations |
| `ptc transcript RUN_ID ...` | Publish one correlated private model transcript |
| `ptc repl` | Open a direct, manifest-backed, or analysis session |
| `mix ptc.materialize ...` | Gate model-authored source as a candidate component |
| `mix ptc.viewer PROJECT.json` | Browse a project's captured traces in a source checkout |

Help is generated from the same declarations as the strict parser, so use
`mix ptc help COMMAND` as the canonical command and option reference.

A provider-bearing manifest needs a host configuration. A project document can
remember that path and its environment file. Before running it, active provider
checks can make real requests and may incur cost:

```console
mix ptc doctor ptc-project.json --connect
```

Plain doctor reports `readiness: "unverified"` when its local checks pass.
Missing provider commands, unreadable replay fixtures, and other attributable
local failures produce failed check rows, `readiness: "failed"`, and a nonzero
exit without activating a provider. Successful active checks report `ready`;
an attributable active failure also reports `failed` and exits nonzero. A
manifest or package rejected during application validation is likewise
reported as a failed `application` check instead of an internal command error.
Complete readiness reports, including `readiness: "failed"`, are written to
stdout. Failed reports retain their nonzero exit status; failures that cannot
produce a complete report are written to stderr.
`--show-model-selectors` adds only safe selectors.

## Run a manifest

For normal local use, keep stable paths in a project document:

```console
mix ptc run ptc-project.json
mix ptc.viewer ptc-project.json
```

The project form creates its fixed owner-only artifact layout as needed. See
[Project configuration](project-configuration.md). Direct manifest invocation
remains the explicit low-level form below.

The trace directory must already exist:

```console
mkdir -p traces
mix ptc run ptc.json
mix ptc run ptc.json --trace-dir traces
mix ptc run ptc.json \
  --env-file .env \
  --host-config ptc-host.json \
  --trace-dir traces \
  --inspect traces/run.inspection.jsonl \
  --envelope results/command.json
```

Useful run switches are:

- `--input INPUT.json` replaces the manifest input with another normal object.
- `--private-input INPUT.json` does the same and classifies the run as private.
- `--output VALUE.json` publishes a normal result value without replacing an
  existing file.
- `--private-output VALUE.json` publishes a private result at owner-only mode
  and keeps it off stdout.
- `--trace-dir DIR` writes `<run_ref>.jsonl` or
  `<run_ref>.private.jsonl` according to the run's artifact class.
- `--inspect FILE` writes sensitive execution evidence to an owner-only
  `.inspection.jsonl` file.
- `--envelope FILE` atomically adds the stable V2 command envelope.

The command envelope reports the run reference and artifact class, not artifact
paths. Output, trace, inspection, and envelope destinations must be distinct.
All publications are no-replace and recheck their destination at commit time.

For runs that produce a validated terminal event batch, `execution.usage`
includes `llm_usage` grouped by alias and installation revision,
`llm_usage_by_model` grouped by an attested public resolved model, and
`unattributed_model_calls`. Rows report call counts, usage-presence counts, and
summed token and `total_cost` values. A row includes `total_cost` only when
every successful call has valid usage that reports cost; otherwise the
aggregate cost remains unknown and is omitted, not reported as zero.
`llm_usage_state: "unavailable"` pairs all three
aggregate fields with `null` when terminal evidence cannot be validated, while
preserving other known usage. Non-empty `events_dropped` means an available
summary covers retained evidence and may not be complete.

Artifact publication currently requires a Unix host with POSIX-compatible
`mkdir` and `id`; trace append also needs `sh` and either `lockf` or `flock`.
Private artifacts and newly created traces require trusted ancestry, safe
ownership, and restrictive modes. Preflight refuses unsafe or unwritable
destinations before provider acquisition, while descriptor-based publication
checks close later filesystem races.

`--inspect` is an explicit host development authority. It may contain prompts,
model responses, generated source, capability arguments and results, MCP
payloads, prints, and detailed failures. Do not publish it with normal traces.

### Evaluate replacement component source

Use `--component-override-descriptor` to evaluate one already-selected
component without installing it. `mix ptc.materialize` creates a verified,
owner-only candidate and descriptor from model-authored source. The
[replay evaluation guide](evaluating-with-replay.md) owns the complete workflow
for holding model responses fixed, gating effect changes, and comparing a
baseline with that candidate. Run `mix help ptc.materialize` for the exact task
options.

## Read results and failures

A successful normal run prints the compact JSON result value. A private run
does not print its value. The V2 envelope records the result class, artifact
states, bounded usage, retained-memory counts, and the closed diagnostic when
one exists.

Capability failures normally enter PTC-Lisp as recoverable envelopes so the
workflow can correct, retry, degrade, or fail. Parser, compiler, timeout, heap,
source, result, quota, provider, and event failures retain bounded Kernel
classifications.

One-shot public diagnostics come from a closed catalog. They never render an
arbitrary exception, rejected value, provider response, credential, or private
payload. A provider subject appears as `provider/<alias>/<operation>` with its
workflow or mission occurrence when known.

Component compile failures with a provable location print the logical component
name and the envelope's half-open byte range, for example `at main.clj bytes
[45,58)`. The same canonical offsets remain available in `error.span` when
`--envelope` is requested. An unknown namespace is a separate closed diagnostic:
the compiler carries the rejected namespace and canonical sorted namespace list
as structured detail, and the command boundary rebuilds the public list and JSON
hint after validating that detail. It never forwards the compiler-rendered
string. For a shipped namespace such as `kernel/`, select its library and add
the component dependency as described in
[Select a shipped prelude](components-and-preludes.md#select-a-shipped-prelude).

### Use the standalone process contract

For machine integration, name an envelope file instead of parsing stdout:

```console
bin/ptc run ptc.json --envelope command-envelope.json
```

The standalone streams are human presentation channels and may also contain
output from applications or children. The envelope is an atomic, no-replace
file with schema `priv/schemas/ptc-command-envelope-v2.schema.json`. Its status
and exit-code relationship is sealed by the same command contract.

After arguments parse, an ordinary or caught command outcome publishes one
requested envelope. Invalid arguments and VM/OS termination can produce none.
If envelope publication itself fails, the standalone command exits `74` and
cannot report that failure through the missing envelope. Success exits `0`;
classified failures use their diagnostic catalog status; caught internal
failures use `70`.

`run`, `validate`, `doctor`, `models`, and `init` accept `--envelope`.
`repl`, `transcript`, help, and version do not. A private run envelope omits the
result value. Build the runtime-included release with:

```console
mix deps.get
MIX_ENV=prod mix release ptc_runner
_build/prod/rel/ptc_runner/bin/ptc --version
```

The release includes ERTS. Like `mix ptc`, it reads only a dotenv file named by
`--env-file`; without that flag, credentials come from the inherited process
environment or other trusted host-document bindings.

### Diagnose a failed run

The command reports a closed phase/code pair. If a workflow deliberately calls
`fail`, its value is not copied into the command diagnostic. The Kernel API and
canonical `run-stopped` event retain only a safe taxonomy:

- a map whose `kind` is recognized retains that readable kind;
- an authenticated `agent.core` turn-limit failure additionally retains the
  fixed `agent_turns` name and effective integer ceiling from 1 through 128;
- an unknown map kind retains only a one-way fingerprint;
- a string or other non-map retains no detail.

Prefer a framework classification such as:

```clojure
(fail {:kind "assertion-failed" :detail "private explanation"})
```

The public evidence retains `assertion-failed`, not the private explanation.
The Runner adds the fixed `agent_turns` fields only after the shipped agent's
private runtime route has authenticated the exhaustion failure.

For exact authorized detail, capture inspection evidence:

```console
mix ptc run ptc.json \
  --trace-dir traces \
  --inspect private/run.inspection.jsonl
```

Each inspection artifact includes the frozen component sources. It adds
execution prints and any provider-backed private activity that occurred. A
failure can add detailed `execution-error` evidence. Read it only through an
authorized private sink.

To debug compilation with the manifest bundle, use manifest mode:

```console
mix ptc repl -m ptc.json
```

`-l` dynamically evaluates setup code and does not accept component-only forms
such as `ns` or `defn-`.

## Use workflow REPL sessions

Start a scratch session or attach the manifest's frozen workflow environment:

```console
mix ptc repl
mix ptc repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc repl --manifest ptc.json --host-config ptc-host.json
mix ptc repl --manifest ptc.json --trace traces/repl.jsonl
```

Successful definitions and three-value history persist for one session; failed
forms preserve prior state. Manifest providers are acquired once and reused.
Private manifest sessions require an attached terminal and
`--private-terminal`. The [Kernel REPL guide](kernel-repl.md) covers all modes,
input forms, privacy gates, JSON Lines, bounds, and cleanup.

## Query canonical traces

Canonical traces contain bounded operational events, not prompts, model
responses, capability payloads, or generated source. Query one immutable
directory capture through the fixed public profile:

```console
mix ptc repl \
  --profile run-analysis-v1 \
  --resource traces=traces \
  -e '(analysis/runs {})' \
  -e '(analysis/open "run-id")'
```

Public analysis supports `runs`, `open`, and `read`; the public `activity`
collection contains canonical events. `open` advertises the private collections
but they require a correlated inspection snapshot and private authority.
The [TraceLog contract](../trace-log-contract.md) defines event schemas,
sanitization, filtering, pagination, and source classes. The
[Kernel REPL guide](kernel-repl.md) covers longer investigations.

## Inspect a private model conversation

Capture canonical and inspection artifacts in separate trusted locations. The
credential-free
[Kernel inspection lab](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-inspection-lab)
creates a correlated pair without a live model.

For one transcript, avoid a REPL:

```console
mkdir -p tmp/transcript
mix ptc transcript RUN_ID \
  --traces tmp/traces \
  --inspection tmp/inspection \
  --private-unattended \
  --private-output tmp/transcript/conversation.private.json
```

The command reserves an owner-only destination before capture. Trace,
inspection, and output directories must be pairwise physically separate: no
directory may equal, contain, or be contained by either of the others.
Ambiguous, incomplete, changed, unsupported, or oversized evidence fails
without a partial output.

Use `private-run-analysis-v1` when you need several correlated questions or
custom PTC-Lisp analysis. Its results can include exact messages, generated
source, effective components, capability payloads, prints, diagnostics, and
terminal values. The attached-terminal and unattended switches are accident
guards, not access control; treat every downstream sink as private.

To walk the same capture from an ordinary application rather than a session,
[Debug a failed run](debugging-a-failed-run.md) installs it as a snapshot
provider and follows typed evidence links with the shipped `debug.nav` prelude.

## Browse with the development Viewer

From a source checkout:

```console
mix ptc.viewer ptc-project.json
```

The project document supplies the trace root and optional inspection root, plus
the port, browser-opening preference, REPL setting, and private-data grant. The
Viewer binds to loopback, pins the selected data, and can open a bounded
analysis REPL over an immutable capture. It is a development path dependency,
not part of the published Hex package. See the
[Viewer documentation](https://github.com/andreasronge/ptc_runner/tree/main/ptc_viewer)
for its complete command and HTTP API.

## Test a workflow

Use deterministic fixtures for normal tests. Assert the business value and
semantic error classification, not timestamps, run references, or remaining
milliseconds.

One shell-level check can use the stable envelope:

```console
artifact_dir="$(mktemp -d)"
envelope="$artifact_dir/command-envelope.json"
mix ptc run examples/kernel-tutorial/01-orders/ptc.json --envelope "$envelope"
actual="$(jq -c '.result.value' "$envelope")"
test "$actual" = \
  '{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}'
```

Test scripted model responses before a small live-provider boundary. The
[replay evaluation guide](evaluating-with-replay.md) shows the deterministic
path; the [Quickstart](quickstart.md) keeps one deliberately small live check.

## Next steps

- [Kernel REPL](kernel-repl.md) covers session and analysis modes.
- [Manifests and capabilities](manifests-and-capabilities.md) defines the
  application boundary these commands enforce.
- [Host configuration](host-configuration.md) defines provider installation.
- [Building agents](building-agents.md) explains the agent policy producing
  the runs.
