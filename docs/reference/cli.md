# Command-line reference

> **Audience:** application authors and operators who need the complete `ptc`
> command and process contract.

Every installation exposes the same `ptc` command grammar and runtime path.
Run `ptc help COMMAND` for the exact switches accepted by an installed version.

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
| `ptc viewer PROJECT.json` | Browse a project's captured traces in a local web UI |
| `ptc serve GATEWAY.json` | Serve compiled applications as MCP tools over stdio |

Help is generated from the same declarations as the strict parser, so use
`ptc help COMMAND` as the canonical command and option reference.

A provider-bearing manifest needs a host configuration. A project document can
remember that path and its environment file. Before running it, active provider
checks can make real requests and may incur cost:

```console
ptc doctor ptc-project.json --connect
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
ptc run ptc-project.json
ptc viewer ptc-project.json
```

The project form creates its fixed owner-only artifact layout as needed. See
[Project configuration](project-files.md). Direct manifest invocation
remains the explicit low-level form below.

To inspect one mission with the same project paths but without starting the
workflow, name it at invocation time:

```console
ptc repl --project ptc-project.json --mission review
```

The project document remains the only path/configuration file the operator
normally supplies; mission declarations continue to live only in `ptc.json`.

The trace directory must already exist:

```console
mkdir -p traces
ptc run ptc.json
ptc run ptc.json --trace-dir traces
ptc run ptc.json \
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

Atomic publication may reserve owner-only sibling paths named
`.ptc-private-*` or `.ptc-private-result-*`. They normally disappear at commit
or cleanup, but an abruptly terminated process can leave one behind. Because a
completed reservation can contain private prompts, responses, source, or a
result, ignore both patterns as well as the configured artifact root. New
projects created by `ptc init` include all three patterns in `.gitignore`.

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
component without installing it. A trusted build step creates the owner-only
candidate and descriptor from model-authored source. The
[replay evaluation guide](../guides/evaluating-with-replay.md) owns the complete workflow
for holding model responses fixed, gating effect changes, and comparing a
baseline with that candidate. Candidate creation is not currently a standalone
command; the source-checkout tool belongs to the maintainer documentation.

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

Environment files fail before provider acquisition with a cause-specific code:
`environment_file_not_found`, `environment_file_not_regular`,
`environment_file_unreadable`, `environment_file_too_large`, or
`environment_file_invalid_utf8`. The code identifies whether to create the
named `--env-file`/project file, change its permissions, or repair its bytes;
the public envelope still does not publish a host filesystem path.

When an agent turns a provider failure into workflow failure, the command
retains one bounded class when the adapter can prove it:
`llm_authentication_failed`, `llm_payment_required`, `llm_rate_limited`,
`llm_model_not_found`, `llm_tool_calling_unsupported`, `llm_request_invalid`,
`llm_access_denied`,
`llm_timeout`, `llm_provider_unavailable`, or the non-retryable fallback
`llm_provider_failed`. No response body is retained.
The failing model alias remains attributable through usage/provider evidence;
run `ptc doctor PROJECT --connect` for a minimal provider check and use private
inspection only when authorized detail is necessary.

Component compile failures with a provable location print the logical component
name and the envelope's half-open byte range, for example `at main.clj bytes
[45,58)`. The same canonical offsets remain available in `error.span` when
`--envelope` is requested. An unknown namespace is a separate closed diagnostic:
the compiler carries the rejected namespace and canonical sorted namespace list
as structured detail, and the command boundary rebuilds the public list and JSON
hint after validating that detail. It never forwards the compiler-rendered
string. For a shipped namespace such as `kernel/`, select its library and add
the component dependency as described in
[Select a shipped prelude](component-contracts.md#select-a-shipped-prelude).

### Use the standalone process contract

For machine integration, name an envelope file instead of parsing stdout:

```console
ptc run ptc.json --envelope command-envelope.json
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
`repl`, `transcript`, `viewer`, help, and version do not. A private run
envelope omits the result value. Installation, packaging, and container
commands live in the [installation documentation](../installation/standalone.md),
not in this process-contract reference.

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
ptc run ptc.json \
  --trace-dir traces \
  --inspect private/run.inspection.jsonl
```

Each inspection artifact includes the frozen component sources. It adds
execution prints and any provider-backed private activity that occurred. A
failure can add detailed `execution-error` evidence. A raised capability
callback additionally records its bounded exception class, message, and
formatted stacktrace while the canonical trace retains only the closed
`provider_error / exception` category. Exception text and stacktrace paths can
contain sensitive data and are not reliably redactable; read the artifact only
through an authorized private sink.

To debug compilation with the manifest bundle, use manifest mode:

```console
ptc repl -m ptc.json
```

`-l` dynamically evaluates setup code and does not accept component-only forms
such as `ns` or `defn-`.

## Use workflow REPL sessions

Start a scratch session or attach the manifest's frozen workflow environment:

```console
ptc repl
ptc repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
ptc repl --manifest ptc.json --host-config ptc-host.json
ptc repl --manifest ptc.json --trace traces/repl.jsonl
```

Successful definitions and three-value history persist for one session; failed
forms preserve prior state. Manifest providers are acquired once and reused.
Private manifest sessions require an attached terminal and
`--private-terminal`. The [Kernel REPL guide](repl.md) covers all modes,
input forms, privacy gates, JSON Lines, bounds, and cleanup.

An interactive session on a terminal runs under the Erlang line editor, so the
usual editing keys work — `Ctrl+A`/`Ctrl+E`, word motion, `Ctrl+K`/`Ctrl+U`
and yank, arrow-key history, and `Ctrl+R` reverse search. Two keys behave
differently there than in a plain terminal reader:

- `:quit` leaves the session. `Ctrl+D` deletes the character under the cursor
  instead of ending input, because the editor binds it that way and offers no
  end-of-input binding to rebind it to.
- `Ctrl+C` opens the BEAM break menu, as it does in `iex`. Press `c` to return
  to the prompt or `a` to abort the command.

A direct session keeps its submitted lines between runs, under
`ptc/repl-history` in the user cache directory, so the previous session's
expressions are one arrow key away. A manifest session can carry a private
event policy, so it edits and recalls within the session but writes nothing to
disk.

Analysis profile sessions (`--profile`) read under the source limit that mode
enforces, which the line editor cannot drive. They keep the plain reader, and
with it `Ctrl+D` as end of input; `:quit` works there too. Every
non-interactive form — `-e`, a script argument, `-`, or redirected input —
reads exactly as before.

## Query canonical traces

Canonical traces contain bounded operational events, not prompts, model
responses, capability payloads, or generated source. Query one immutable
directory capture through the fixed public profile:

```console
ptc repl \
  --profile run-analysis-v1 \
  --resource traces=traces \
  -e '(analysis/runs {})' \
  -e '(analysis/open "run-id")'
```

Public analysis supports `runs`, `open`, and `read`; the public `activity`
collection contains canonical events. `open` advertises the private collections
but they require a correlated inspection snapshot and private authority.
`analysis/runs` defaults to a compact projection containing run ID, status,
duration, LLM calls, evaluations, terminal reason, and completeness flags. Pass
`{"view" "full"}` when selecting by the complete metadata record:

```clojure
(analysis/runs {"status" "error"})
(analysis/runs {"status" "error" "view" "full"})
```

When a project already declares its artifact root, reuse it instead of
repeating resource paths:

```console
ptc repl --project ptc-project.json \
  --profile run-analysis-v1 \
  -e '(analysis/runs {})'
```

The public profile derives `traces`; the private profile derives both `traces`
and `inspection` when those artifact classes are enabled. An explicit
`--resource NAME=DIR` overrides only that derived resource.

The [TraceLog contract](../trace-log-contract.md) defines event schemas,
sanitization, filtering, pagination, and source classes. The
[Kernel REPL guide](repl.md) covers longer investigations.

## Inspect a private model conversation

Capture canonical and inspection artifacts in separate trusted locations. The
credential-free
[Kernel inspection lab](https://github.com/andreasronge/ptc_runner/tree/main/examples/kernel-inspection-lab)
creates a correlated pair without a live model.

For one transcript, avoid a REPL:

```console
mkdir -p tmp/transcript
ptc transcript RUN_ID \
  --traces tmp/traces \
  --inspection tmp/inspection \
  --private-unattended \
  --private-output tmp/transcript/conversation.private.json
```

The command reserves an owner-only destination before capture. Trace,
inspection, and output directories must be pairwise physically separate: no
directory may equal, contain, or be contained by either of the others. A
rejection names the two conflicting switches and their physical relationship,
and discloses no path. Ambiguous, incomplete, changed, unsupported, or
oversized evidence fails without a partial output.

Use `private-run-analysis-v1` when you need several correlated questions or
custom PTC-Lisp analysis. Its results can include exact messages, generated
source, effective components, capability payloads, prints, diagnostics, and
terminal values. The attached-terminal and unattended switches are accident
guards, not access control; treat every downstream sink as private.

To walk the same capture from an ordinary application rather than a session,
[Debug a failed run](debug-navigation.md) installs it as a snapshot
provider and follows typed evidence links with the shipped `debug.nav` prelude.

## Browse traces in the Viewer

```console
ptc viewer ptc-project.json
```

The project document supplies the trace root and optional inspection root, plus
the port, browser-opening preference, REPL setting, and private-data grant. The
Viewer pins the selected data and can open a bounded analysis REPL over an
immutable capture. `--port` overrides the project's port; `0` asks the
operating system for a free one. The command runs in the foreground until
`Ctrl+C`, and opens a browser only when the project asks for it *and* a
terminal is attached.

The Viewer ships inside the standalone release and the container image. It is
not part of the published Hex package, where `ptc doctor` reports it as an
unavailable optional companion and `ptc viewer` says so rather than failing
obscurely. See the
[Viewer documentation](https://github.com/andreasronge/ptc_runner/tree/main/ptc_viewer)
for its complete HTTP API.

### Expose it deliberately, or not at all

The Viewer has no authentication and can display private inspection records
when the project grants them, so it binds `127.0.0.1` and reaches nothing else.
`--listen 0.0.0.0` is the only way to change that, it accepts no other address,
and it prints a warning when used. Authenticated remote Viewer hosting is not a
goal of this command.

A container is the one place the wildcard is routine, because it is not an
exposure decision there. Inside a container `127.0.0.1` is the container's own
loopback, while a published port forwards to the container's external
interface, so a loopback bind refuses every connection a `-p` mapping delivers.
Binding `0.0.0.0` *inside the container's network namespace* is what makes the
mapping reachable, and the host-side exposure decision moves to the publish
rule:

```console
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  -p 127.0.0.1:4123:4123 \
  -v "$PWD:/work" \
  ptc:dev viewer /work/ptc-project.json --listen 0.0.0.0
```

The `127.0.0.1:` prefix on `-p` is what keeps this equivalent to a loopback
bind. Writing `-p 4123:4123` instead publishes an unauthenticated trace browser
to every host that can reach the machine. The command cannot enforce that
prefix; the operator must write it. The user mapping preserves access to the
mounted project's owner-only artifacts; do not run this form from a root shell.

## Test a workflow

Use deterministic fixtures for normal tests. Assert the business value and
semantic error classification, not timestamps, run references, or remaining
milliseconds.

One shell-level check can use the stable envelope:

```console
artifact_dir="$(mktemp -d)"
envelope="$artifact_dir/command-envelope.json"
ptc run examples/kernel-tutorial/01-orders/ptc.json --envelope "$envelope"
actual="$(jq -c '.result.value' "$envelope")"
test "$actual" = \
  '{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}'
```

Test scripted model responses before a small live-provider boundary. The
[replay evaluation guide](../guides/evaluating-with-replay.md) shows the deterministic
path; the [Quickstart](../guides/quickstart.md) keeps one deliberately small live check.

## Next steps

- [Kernel REPL](repl.md) covers session and analysis modes.
- [Manifests and capabilities](application-manifest.md) defines the
  application boundary these commands enforce.
- [Host configuration](host-installation.md) defines provider installation.
- [Building agents](../guides/building-agents.md) explains the agent policy producing
  the runs.
