# Running and debugging

The Kernel command surface runs through `mix ptc` in a source checkout and
through the runtime-included `ptc_runner` release's `bin/ptc` entrypoint. Both
frontends use the same parser, preparation, execution, result, trace, and
rendering paths.

## Commands

| Command | Purpose |
| --- | --- |
| `mix ptc help [COMMAND]` | Show root or per-command help generated from the accepted declarations |
| `mix ptc --version` | Show the packaged command version |
| `mix ptc init DIRECTORY` | Atomically publish the validated two-file application scaffold |
| `mix ptc validate MANIFEST` | Validate and compile a manifest without running its workflow |
| `mix ptc run MANIFEST` | Run the manifest's qualified entry and render its public result |
| `mix ptc run MANIFEST --host-config HOST.json` | Install the provider aliases a provider-bearing manifest selects |
| `mix ptc run MANIFEST --input INPUT.json` | Run with a confined alternate input object |
| `mix ptc run MANIFEST --output VALUE.json` | Write only the validated result value |
| `mix ptc run MANIFEST --trace-dir DIR` | Persist bounded canonical events under the command run reference (`DIR` must already exist) |
| `mix ptc run MANIFEST --inspect RUN.inspection.jsonl` | Also write the owner-only private artifact |
| `mix ptc run MANIFEST --envelope ENVELOPE.json` | Atomically publish the machine-readable V2 command envelope |
| `mix ptc run MANIFEST --component-override-descriptor D.json` | Compile one selected component from verified replacement source |
| `mix ptc doctor [MANIFEST]` | Inspect application and provider readiness without running the workflow |
| `mix ptc doctor MANIFEST --host-config HOST.json --connect` | Perform active provider connectivity checks |
| `mix ptc models --host-config HOST.json` | List the host document's installed model aliases |
| `mix ptc.materialize MANIFEST --workflow --component ID --out DIR --source S.clj` | Publish model-authored source as a gated candidate component |
| `mix ptc repl` | Start the direct transactional PTC-Lisp REPL |
| `mix ptc repl -e EXPR -l SETUP.clj` | Run repeatable expressions with optional setup |
| `mix ptc repl --manifest MANIFEST [--host-config HOST.json]` | Reuse a manifest's workflow bundle and one provider session |
| `mix ptc repl --profile PROFILE --resource NAME=DIR` | Query an immutable trace or inspection capture |
| `mix ptc.viewer --trace-dir DIR` | Browse canonical JSONL traces locally |

`mix ptc init DIRECTORY` creates the exact two-file scaffold documented in
[Getting started](getting-started.md#create-a-minimal-application).
Initialization validates the scaffold before filesystem access and publishes
the completed directory atomically without replacing an existing directory or
symlink. A refused initialization leaves the filesystem untouched and names the
condition that stopped it: `publication/initialization_target_exists` for an
existing target, `publication/initialization_parent_missing` or
`publication/initialization_parent_unusable` for the parent directory, and
`publication/initialization_failed` when no safe public cause can be disclosed.
Every failure reported before publication can be retried once its condition is
resolved.

Run `mix ptc help COMMAND` or `bin/ptc help COMMAND` for help generated from the
same per-command declarations the strict parser accepts.

A provider-bearing manifest requires `--host-config`. Use the standalone
`ptc doctor MANIFEST --host-config HOST.json --connect` operation when active
provider connectivity must be checked without running the workflow.
Use `--show-model-selectors` when doctor should also print safe model selectors;
endpoint-bearing `openai-compat:` selectors remain omitted.

Doctor results carry an explicit `readiness`. Plain doctor is `unverified`: it
performs local checks but leaves provider-active rows skipped. A successful
`--connect` report is `ready`. When an active diagnostic identifies one report
row, doctor exits nonzero but still renders the JSON report with `readiness:
"failed"`; the named envelope, when requested, also retains the complete
diagnostic. Other pending rows say `not_verified_due_to_failure`, which means no
sealed evidence was retained for them. Unattributable operation failures,
cleanup failures, owner failures, and internal invariants remain ordinary fatal
diagnostics rather than synthesized health findings.

A fresh Mix invocation safely configures and starts a selected optional
provider application only after the active provider lifecycle begins. A later `ptc run`
invocation in the same VM reuses an already-running application as host-owned,
so task chaining and `iex -S mix` do not require restarting the VM. For ReqLLM,
the fresh command-owned start configures its default HTTP/1 Finch pool as one
shard sized from the installed `live_provider_tasks` ceiling. A manifest may
narrow its own effective limit but does not resize that VM-lifetime pool. Later
host-owned commands keep the already-running application's configuration, so
an embedding that changes installed ceilings in one VM owns the corresponding
aggregate pool-capacity policy.

## Run a manifest

`--trace-dir` writes into an existing directory; it does not create one. Create
it first:

```console
mkdir -p traces
mix ptc run ptc.json
mix ptc run ptc.json --trace-dir traces
mix ptc run ptc.json \
  --trace-dir traces \
  --inspect traces/run.inspection.jsonl
```

The command creates `<run_ref>.jsonl` for a normal run and the reserved
`<run_ref>.private.jsonl` form for a private run:

```console
mix ptc run private-ptc.json \
  --trace-dir traces \
  --private-output results/run.private.json
```

The envelope reports the run reference and artifact class without publishing a
destination path.

Configured result, trace, and inspection destinations must be pairwise
distinct after resolving their existing parent-directory identity; final names
are Unicode case-folded and normalized so the rule remains safe on
case-insensitive filesystems. Deterministic destination conflicts and
filesystem-invalid or deterministically unwritable destinations are rejected
before provider acquisition; each persistence path still uses its own
publication checks to close races after preflight.

Snapshot capture failures report the source kind, measured retained bytes, and
configured retained-byte ceiling when the decoded trace or inspection catalog
is too large. Workflow timeouts likewise name the effective limit
(`workflow_timeout_ms` or the remaining `run_duration_ms`), its value, and
whether compilation or execution exhausted it.

`--inspect` is a host opt-in development feature. It writes a separate bounded
owner-only artifact containing sensitive execution details. Do not publish it
with normal traces. Artifact publication through `--output`,
`--private-output`, or `--inspect` requires a Unix host and POSIX-compatible
`mkdir` and `id` executables on `PATH`; command preflight reports the matching
artifact destination as unavailable when that authority or mode-at-create
primitive is unavailable. Publication validates
both lexical and resolved physical ancestry and rejects an untrusted owner or a
group/other-writable directory without sticky-directory protection, because
another tenant could otherwise replace the private temporary directory before
the artifact is opened. A final parent must also grant create access to the
effective owner, group, or other permission class.

Destination preflight reports an untrusted ancestor under its own reason —
`result_destination_unsafe`, `inspection_destination_unsafe`, or
`trace_destination_unsafe` — rather than the generic persistence or
unavailability failure, because the remedy differs: an untrusted ancestor names
a directory whose owner or mode an operator can correct, while a missing `id`
or `mkdir` names an unusable host. Result publication shares that preflight, so
`--output` and `--private-output` report `result_destination_unsafe` too when a
destination turns unsafe after preflight; trace appends and inspection
publication keep their single closed reason.

Ancestry is validated for every result and inspection destination whatever its
class, for every private trace, and for a normal trace that must still be
created. An existing normal trace is validated for writability only. The
append-lock directory under `TMPDIR` is validated separately and reports
`source_unavailable` for any fault, including an untrusted ancestor of its
own.

Private trace creation uses the same host primitives and ancestry checks. A
missing trace requires both `mkdir` and `id` and is published at mode `0600`
before use. An existing private trace requires `id`, must already be mode
`0600`, owned by the current process authority or root, and writable by the
effective authority; its parent needs traversal but not create access. The
append retains its permission-checked descriptor. Every trace append also
requires `sh` and either `lockf` or `flock` for its cross-runtime lease. The
per-authority lease directory is owner-only; its first creation additionally
requires `mkdir`, while later appends validate its type, owner, and exact mode
without changing permissions through an unresolved path.

`--input PATH` replaces the manifest input file. `--private-input PATH` uses
the same confined JSON shape and classifies the complete run as private before
provider activity; the two options are mutually exclusive.

### Replace one component's source

`--component-override-descriptor` compiles one already-selected component from
different source. It is host command authority: a manifest cannot name an
override and a generated program cannot observe one. The descriptor carries
four required fields and one optional provenance object:

```json
{
  "component_id": "my.agent",
  "base_source_hash": "sha256:<64 lowercase hex>",
  "source_hash": "sha256:<64 lowercase hex>",
  "path": "candidate.clj",
  "provenance": {
    "run_id": "run-2026-08-03-0001",
    "prompt_hash": "sha256:<64 lowercase hex>",
    "authored_at": "2026-08-03T09:15:00Z",
    "accept_widened_effect": false
  }
}
```

`provenance` is a closed object: unknown keys are refused, and `authored_at`
must parse as RFC 3339 in UTC. It records **who authored** a candidate and is
**operator-asserted, verified by nothing** — a `run_id` is a claim about
origin, not evidence of it. There is no model-id field, because a descriptor is
a published artifact and does not carry provider configuration; an
adapter-attested public execution model may be reached through the run id's
canonical provider snapshot, while private targets remain intentionally absent.
Provenance is deliberately
kept out of content identity, so adding it never changes
`application_content_digest`.

Both hashes use that `sha256:`-prefixed form. `path` resolves against the
descriptor's own canonical directory and may not escape it. The descriptor is
at most 64 KiB and the candidate source at most 1 MiB. Standalone command
diagnostics authorize descriptor paths against this exact schema — the four
required fields plus the optional `provenance` object described below:
duplicate or unknown fields report the safe parent pointer, while an invalid
declared field can report its public field pointer.
Crossing either byte ceiling, or the descriptor JSON depth/node ceiling, is
reported as a document-limit failure with fixed component-override provenance.

Verification is two-sided and happens before the source reaches the compiler.
`source_hash` proves you are compiling the bytes you believe you extracted;
`base_source_hash` proves those bytes were derived from the component that is
installed now, so source written against a since-changed base is rejected
rather than compiled against the wrong baseline. The file is opened once and
the bytes that were hashed are the bytes that compile — the path is never
reopened, so a file replaced mid-run cannot substitute different source.

The named component must already be selected in the descriptor's exact
workflow-or-mission target; an override replaces source and never introduces a
component. Its declared dependencies are preserved, so a candidate cannot
quietly acquire a new one. Normal dependency, export, signature, and capability
validation still applies: an override changes which source compiles, never what
compilation permits.

The `run-started` event records the component ID, both hashes, the resolved
environment, and any asserted provenance — never the candidate source — so a
trace names the base as well as the candidate. Nothing here writes: producing
candidate source is a separate step, described next.

### Promote model-authored source into a component

A model can author a working library inside a run: source handed to
`kernel/eval-source` may contain `def`/`defn`, and those definitions persist
for the life of the run. But a runtime `defn` dies with the run — it is not in
the frozen bundle, not covered by a component source hash, and absent from
`mission_inventory`. `mix ptc.materialize` closes that loop by turning authored
bytes into a candidate a later run can evaluate.

```bash
mix ptc.materialize ptc.json --workflow --component my.helper --out private/candidate \
  --source authored.clj --origin-run-id run-2026-08-03-0001
```

Source comes from `--source` (raw bytes) or from `--from-result PATH
--result-pointer /json/pointer`, because `mix ptc run --output` writes a JSON
result artifact rather than raw Lisp. The pointer must resolve to one string;
anything else is refused rather than coerced.

Use `--workflow` for a workflow component or `--target-mission NAME` for one
exact declared mission. The selector is required and becomes the descriptor's
closed qualified target; the task never infers a target from a component ID.

`--out` must not exist. It is created exclusively at mode 0700 with both files
at 0600 before any content is written, because a candidate extracted from a
private artifact must not be declassified by publishing it. The exclusive
create — not a rename — is the no-clobber guarantee, since POSIX `rename` may
replace an existing empty directory.

The candidate is then re-acquired through the descriptor just written, which is
the exact path a run takes, and gated:

| Criterion | Question |
| --- | --- |
| G1 | Does it resolve to one environment and compile? |
| G2 | Does every prompt-visible export declare a signature and docstring? |
| G3 | Does any export reach further than the base it replaces? |
| G4 | Are declared dependencies unchanged? (preserved by construction) |

A criterion reports `blocked` rather than `fail` when it could not run at all —
a candidate that does not compile has no export table for G2 and G3 to read.

G2 is promotion policy, not something the runtime enforces: the inventory
projects `nil` docstrings and contracts without objection, which is exactly why
an export promoted without them would compile, ship, and be useless to the next
run's model.

G3 compares per export, never against an application-wide union of capability
names. If a base export `A` requires `read-tool` and `B` requires `write-tool`,
`A` gaining `write-tool` adds no name outside the union while materially
widening `A`. A widening is refused unless you pass `--accept-widened-effect`,
which is recorded in the report and in the descriptor's provenance.

The gate does **not** check capability grants. Real capability names exist only
after provider acquisition, so a candidate naming a capability no provider
grants passes here and fails at run-time assembly, which stays authoritative.
The gate narrows the distance to that failure; it does not remove it.

Promotion only ever *replaces* a selected component. To have a model author a
new library, declare a placeholder component first, with the dependency surface
the generated component may consume and a **stub for every export its consumers
call** — a component declaring nothing cannot be depended on, and the base
application would not compile. The model then rewrites it, and both hash checks
still apply.

Promotion itself stays an explicit human decision. `mix ptc.materialize`
produces evidence and refuses unfit candidates; it never installs one.

## Understand results and errors

A successful normal `run` prints the compact JSON result value. Its command
envelope additionally contains:

- `value` — the public workflow result;
- `usage` — remaining time, capability calls, evaluations, protocol errors,
  closure state, and dropped events;
- `evaluation_memory` — counts and retained byte totals, never retained values.

Capability failures normally cross into PTC-Lisp as recoverable envelopes. The
workflow decides whether to retry, correct, degrade, or fail. Parser, compiler,
timeout, heap, source, result, quota, provider, and event failures retain
bounded classifications at the Kernel boundary.

Mix and release failures use the same bounded human renderer. Failures returned
by the shared preparation and runtime path render only the closed diagnostic
catalog, their validated provider subject when present, or fixed argument
guidance; they never inspect a rejected runtime term. A provider subject renders
as `provider/<alias>/<operation>` and adds `at workflow[<index>]` or
`at mission[<index>]` when the failing occurrence is known. Name `--envelope`
when a caller also needs the stable JSON result and exit status in a file.
Envelope publication is additive: it never redirects, suppresses, or replaces
the command's normal terminal rendering.

### Stable standalone process contract

One-shot stdout and stderr are UTF-8 streams. The runtime-included release
writes their rendered text through its Unicode-mode terminal devices, so
non-ASCII help, diagnostics, and JSON result strings retain their exact bytes.
This presentation contract does not change the raw-byte treatment required by
child stdio transports.

When `--envelope` names a destination, the standalone `ptc` command additionally
writes one V2 JSON command envelope there. When the arguments parse, every
ordinary or caught path produces exactly one envelope — except a failure to
publish the envelope itself, which exits `74` with no envelope, described below:

- success exits `0`;
- a classified failure exits with the primary diagnostic's exact
  `PtcRunner.Kernel.DiagnosticCatalog` status, one of `2` through `7`; the
  catalog is authoritative because codes within one phase may intentionally
  have different statuses; and
- a caught unexpected failure writes the closed `internal/internal_error`
  envelope and exits `70`.

The envelope schema is `priv/schemas/ptc-command-envelope-v2.schema.json`.
One-shot command presentation never renders an inspected exception, arbitrary
callback result, credential, private value, provider response, selector, or
filesystem path into either public stream. The long-lived REPL has its own
documented projections; notably, a profile session reports the path of its
successfully published analysis trace.

The shared command core implements every one-shot command through
`PtcRunner.Kernel.CommandEngine`, while `ptc repl` shares the same parser and
then opens its long-lived session frontend. Shared run dispatch authorizes destinations,
executes provider-free and provider-backed work through one execution owner,
publishes immutable execution evidence, and returns a schema-valid normal or
private envelope; a private envelope never contains the result value. The Mix
task is a thin renderer over this boundary. Its adapter owns Mix application
bootstrap and adds only interactive `--authorize-mcp NAME` for the immediately
following run. A nonzero presentation raises a rescuable `Mix.Error` carrying
the diagnostic status; in its normal mode, the outer `mix` executable maps that
status to its process exit, while the task and shared adapter never exit or halt
their caller. `MIX_DEBUG=1` deliberately reraises Mix exceptions for debugging,
so the outer VM uses its generic exception status `1`; the exception still
carries the diagnostic status. Bootstrap failures use the same closed
private-safe run envelope as other internal failures; raw startup reasons and
argv paths are not rendered.

`models` reads one bounded host document and
returns the installed aliases in lexical order with only their public source,
revision, data-class, accepted-class, and destination declarations. Listing
models invokes no provider callback, credential or OAuth service, optional
application, process, port, or network operation.

With `--trace-dir DIR`, the command-generated `run_ref` is also the complete
trace stem. A normal trace is exactly `<run_ref>.jsonl`; a private trace is
exactly `<run_ref>.private.jsonl`. The envelope's `artifact_class` selects which
suffix callers use, so they can locate the file without a published path.
Normal discovery excludes the private suffix; private-aware discovery accepts
and classifies it explicitly. If entropy is unavailable, the command preserves
availability with the fixed fallback reference
`cmd-00000000000000000000000000`; on that exceptional path the reference still
names the command's artifacts but cannot distinguish concurrent commands.

The envelope destination is named by the caller and is separate from `--output`
and `--private-output`, which name the run's result artifact. The command opens
that destination itself and commits the envelope through the same owner-only
staging and atomic no-replace boundary as other artifacts, so no other writer
can interleave with it and an existing entry is never replaced.

The switch is `--envelope PATH`, separate from `--output` and
`--private-output`.

The command writes a short human rendering of the sealed outcome whether or not
an envelope destination is named. Without `--envelope` it writes no envelope;
with `--envelope` it additionally publishes the envelope file. A failure
renders the primary phase, code, and catalog message on stderr. A successful
normal `run` renders its result value on stdout; a successful private `run`
renders only its completion and artifact class, because the private envelope
omits the value and a private result still requires an authorized owner-only
sink. That rendering is projected from the outcome, obeys the same privacy
rules as the envelope, and is presentation rather than a contract: do not
parse it.

The destination names a file and only a file; there is no stdout spelling.
**Standalone stdout is not a machine channel** — it is shared with the runtime,
its optional applications, and their children — so a caller that needs the
envelope writes it to a file and reads that file.

The envelope destination is validated before any work begins, once the arguments
have parsed. It is resolved and compared against every artifact destination the
command could write — result, private result, inspection, both trace suffixes,
and the private-result recovery name derived from the run reference — under the
same resolved-parent-identity rule those artifacts use, so an alias such as
`out.json` against `./out.json` or a symlinked parent is rejected up front
rather than at commit. For `init` the envelope may also be neither the target
directory nor a path beneath it. A collision is an argument failure: it exits
`2` and produces no envelope, because the arguments were refused rather than
anything failing to publish.

`run`, `validate`, `doctor`, `models`, and `init` accept an envelope
destination. `repl` does not, and neither do `help` and `version`, which
complete without touching the filesystem.

Delivery begins at a successful parse. Once the arguments parse, every later
failure — including a recoverable startup failure — delivers its envelope to the
named destination. Rejected arguments produce no envelope: the command exits
`2`, the arguments phase's status, and writes one closed stderr line — naming an
unknown switch's accepted list where applicable, since a missing positional or
a malformed value names neither. A VM abort
produces no envelope either.

The command therefore requires no outer process wrapper, no private envelope
descriptor, and no interception of the runtime's own streams. The guarantee
comes from the destination, not from stream discipline: the core command modules
render no stream, but dispatch invokes runtime callbacks, the Mix authorization
notifier writes through `Mix.shell`, and starting an optional provider
application may emit output. Because the envelope is a file committed atomically
rather than a stream artifact, none of that can interleave with it. The release
entrypoint alone turns a sealed outcome status into a process exit.

Both process streams are consequently non-contractual. The command's own
rendering and diagnostics are closed and carry no private value, credential,
path, selector, or arbitrary term, but nothing constrains what the runtime, an
optional application, or a child writes there — neither content nor secrecy.
Capture those streams outside the command if a deployment needs a guarantee on
them.

If the envelope destination cannot be opened, staged, or committed, the failure
cannot be reported through the envelope. The command writes a bounded, fixed,
code-owned diagnostic to stderr and exits `74`. No valid envelope is promised on
that path.

`SIGINT`, `SIGTERM`, VM abort, OOM, and failure before the command boundary are
outside the V2 envelope contract. They may produce no envelope or VM/OS
emergency output, and the OS or shell determines their status. Distribution
tests characterize termination and child behavior but do not promote one observed
signal status to a portable guarantee. A deployment that requires a bounded
signal response, application bootstrap, or child-tree cleanup must use the
separately triggered outer supervisor design.

Build the runtime-included command from a source checkout with:

```console
mix deps.get
MIX_ENV=prod mix release ptc_runner
_build/prod/rel/ptc_runner/bin/ptc --version
```

The release includes ERTS, so the target machine does not need Erlang or
Elixir. The standalone runtime deliberately does not load `.env`; credentials
come only from bindings declared by the trusted host document. Signed downloads,
notarization, package-manager formulas, container images, and single-file
packaging remain separate distribution work.

### Diagnose a failed run

A failed run reports a phase and a code from the closed diagnostic catalog and
nothing else. That is deliberate — the public envelope never carries arbitrary
text — but it means a workflow that fails on purpose reports
`execution/workflow_failed`, "the workflow failed", and no trace of whatever the
workflow was trying to say.

**Your `fail` value decides how much survives in the Kernel API and canonical
trace.** The command envelope remains the fixed `execution/workflow_failed`
diagnostic described above. `PtcRunner.Kernel.run/2` and the canonical
`run-stopped` event instead pass the value through a failure taxonomy that
keeps a classification and discards everything else:

| `(fail …)` value | What `Kernel.Error.details` and `run-stopped` carry |
| --- | --- |
| a string, or any non-map | nothing |
| a map with a `kind` naming a known failure kind | that kind, readable |
| a map with any other `kind`, or none | a one-way fingerprint, not readable |

The known failure kinds are `invalid-input`, `invalid-prompt`,
`invalid-transcript`, `transcript-limit`, `turn-limit`, `model-program-failed`,
`non-retryable-evaluation`, `evaluation-unavailable`, `capability-unavailable`,
`llm-provider-error`,
`protocol-error`, `provider-error`, `capability-error`, `assertion-failed`, and
`unknown-action`.

So `(fail "the invoice total did not balance")` publishes nothing, while
`(fail {:kind "assertion-failed" :detail "the invoice total did not balance"})`
publishes only `failure_kind: "assertion-failed"`. Prefer the second shape. It
costs one key and it is the difference between a caller knowing what class of
thing went wrong and knowing only that something did. The same projection
survives when `pmap` or `pcalls` rejects a worker's `fail` control signal; the
parallel error remains the terminal reason while its safe failure taxonomy
identifies the underlying framework failure.

Input and result contract failures follow the same public/private split. Their
public classification may name schema-declared missing keys at a safe typed
path. At a closed-object path it may also name allowed keys and count undeclared
keys; an open-object path never classifies extension keys as undeclared. It
never names an undeclared submitted key or copies a submitted value. Use
private inspection when the exact rejected candidate is authorized and
necessary; normal command diagnostics and agent correction feedback remain
schema-derived and bounded.

**When provider-backed detail is needed**, rerun with `--inspect`:

```console
mix ptc run ptc.json --trace-dir traces --inspect traces/run.inspection.jsonl
```

Every inspection artifact holds the exact frozen component source in
`prelude-source` records. If the workflow calls `println`, its output lands in
an `execution-prints` record, whether the run succeeds or fails. Provider-backed
activity may add prompts, normalized model responses, generated subordinate
source, capability arguments and results, and MCP request and response bodies.
A failing run also adds an `execution-error` record with the detailed failure
fields; a provider-free success with no `println` calls adds no run-time record
beyond `prelude-source`. The artifact is owner-only and sensitive: read it, do
not publish it beside a normal trace, and see [Use private inspection
deliberately](#use-private-inspection-deliberately).

**To exercise the component compiler in a REPL**, load the manifest, not the
component as a setup file:

```console
mix ptc repl -m ptc.json
```

The `-l`/`--load` option dynamically evaluates a setup file and cannot load the
component-only `ns` and `defn-` forms. Manifest setup distinguishes malformed
syntax (`syntax_invalid`), undefined variables (`undefined_variable`), and
duplicate definitions (`duplicate_definition`). Other compiler rejections keep
the `compile_failed` fallback. Undefined-variable and duplicate-definition
messages name only bounded symbols found verbatim in the submitted component;
they are rebuilt from structured compiler detail rather than forwarded compiler
text. Malformed syntax carries the parser's byte position when one is provable,
including a zero-length span at end-of-file for an unclosed form. Other details
retain the fixed catalog message and a null span.

**To find the artifacts**, use the run reference. It appears in the command
envelope, and every artifact is named from it: `<run_ref>.jsonl` for a normal
trace and `<run_ref>.private.jsonl` for a private one.

## Use workflow REPL sessions

Start a direct session or reuse a manifest's frozen workflow environment:

```console
mix ptc repl
mix ptc repl -e '(def x 40)' -e '(+ x 2)' -e '(+ *1 1)'
mix ptc repl --manifest ptc.json
mix ptc repl --manifest ptc.json --host-config ptc-host.json
mix ptc repl --manifest ptc.json --trace traces/repl.jsonl
```

Definitions and the three most recent ordinary successful values persist for
one session. Failed forms keep the previously committed state. A manifest that
selects providers requires `--host-config`; it acquires those providers once
and reuses the session across expressions. Provider-free manifests omit the
host configuration and still use the same caller-death and sink owner. Private
manifest sessions are interactive-only and require both `--private-terminal`
and attached stdin/stdout terminals before provider activity can begin. See the
[Kernel REPL guide](kernel-repl.md) for scripts, stdin, JSONL output, resource
limits, and lifecycle details.

## Query canonical traces

Normal traces contain bounded operational events and omit prompts, model
responses, capability arguments/results, and generated source. Query an
immutable directory capture through the fixed log-analysis profile:

```console
mix ptc repl \
  --profile log-analysis-v2 \
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

Events pair evaluations by `evaluation_id` and capabilities by `capability_id`,
and carry environment, status, duration, labels, prelude component IDs and
hashes, limit events, and aggregate usage. The
[TraceLog contract](../trace-log-contract.md) defines the event schemas,
sanitization, filtering, pagination, and private sources. See the
[Kernel REPL guide](kernel-repl.md) for longer interactive investigations.

## Use private inspection deliberately

Pass both output paths when exact development diagnostics are required:

```console
mkdir -p tmp/inspection
mix ptc run examples/kernel-tutorial/03-file-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --trace-dir tmp/inspection \
  --inspect tmp/inspection/run.inspection.jsonl
```

The inspection path is selected by the host command, not by the manifest or
PTC-Lisp. Capture is fail closed and the file uses owner-only permissions.
Canonical trace queries never join its payloads into ordinary results.

The credential-free [Kernel inspection lab](../../examples/kernel-inspection-lab/README.md)
creates correlated canonical and inspection artifacts without a live model.

### Analyze what the model received and generated

Canonical traces answer *what happened* without retaining private content. The
inspection artifact answers *what the model saw and wrote*. It is created with
owner-only permissions and contains the full request, response, generated
source, and capability payloads. The log-analysis REPL cannot read or join this
private data by design; use the development Viewer below or the private
inspection profile in the [Kernel REPL guide](kernel-repl.md).

In one verified `03-file-agent` run, the request contained four relevant parts:

| Feed part | What the model received |
| --- | --- |
| System instructions | Call `run_ptc_lisp` exactly once per turn; ordinary results continue; successful definitions persist; failed definitions roll back; `return` completes; `fail` aborts; do not answer in prose. |
| Language summary | PTC-Lisp described as a bounded Clojure-like language, followed by its common forms, namespaces, JSON-map convention, exclusions, and short examples. |
| Available mission API | Only `(tutorial.files/read-text path)`, documented as a read effect from a string path to a string result. |
| User message and model tool | Read `brief.txt` through that wrapper and return its exact contents; one `run_ptc_lisp` tool accepting one required `program` string. |

The request did **not** contain the file contents, the provider credential,
unrestricted filesystem access, or the workflow's raw `llm-request` capability.
The model had to express the action through the one advertised mission
function. The provider reported 895 input tokens for that small feed; token
counts change with prompt or provider updates.

The model generated exactly this 47-byte program:

```clojure
(return (tutorial.files/read-text "brief.txt"))
```

It uses the prompt-visible wrapper rather than guessing a raw capability API,
passes the requested relative path for the host-confined provider to validate
beneath the granted root, and makes the first mission evaluation terminal with
`return`. It creates no definitions and no ordinary intermediate value, which
matches the public `defined_count: 0` and `history_count: 0`.

More complex agents use the same boundary across several turns, with inspection
recording each private request, response, and generated program while the
canonical trace retains only bounded operational evidence.

## Development Viewer

From the repository root, after creating the trace directory:

```console
mix ptc.viewer --trace-dir tmp/inspection \
  --inspection-file tmp/inspection/run.inspection.jsonl
```

The Viewer lists runs and renders paired workflow and mission evaluations,
capability calls, annotations, limits, usage metrics, and raw canonical event
metadata. Use `--port` to choose a port instead of the default 4123, and
`--no-open` when running on a remote machine.

The Viewer binds to loopback, pins the selected inspection file, and can enable
a bounded log-analysis REPL over an immutable trace capture. It is currently a
development/test path dependency and is not included in the published Hex
package. Treat this command as source-checkout tooling until standalone Viewer
packaging is released. If the selected inspection artifact uses an unsupported
schema, Viewer startup reports both the artifact version and the version
supported by the running PtcRunner build.

See [`ptc_viewer/README.md`](../../ptc_viewer/README.md) for the Viewer's HTTP
API, configuration, and programmatic start/stop.

## Test a workflow

Keep a deterministic fixture in normal tests. Compare the stable business
value and semantic error classification rather than timestamps, generated run
IDs, or remaining milliseconds.

Build the checks in three layers:

1. Exercise pure transformations in `mix ptc repl`.
2. Run fixed manifest inputs with `mix ptc run --envelope` and assert
   `.result.value` with `jq`.
3. Put live-provider checks behind an explicit flag and assert a narrow
   contract, not prose wording.

Layer 2 needs no test framework:

```console
envelope_dir="$(mktemp -d)"
envelope="$envelope_dir/command-envelope.json"
mix ptc run examples/kernel-tutorial/01-orders/ptc.json --envelope "$envelope"
actual="$(jq -c '.result.value' "$envelope")"
test "$actual" = \
  '{"order_count":3,"paid_count":2,"paid_total":335.75,"pending_ids":["A-101"]}'
```

For model workflows, test the protocol parser and feedback loop with scripted
responses first, then keep the live provider boundary in a small separate
credentialed test:

```console
mix test test/ptc_runner/kernel/tutorial_examples_e2e_test.exs --include e2e
```

That module is tagged `:e2e`, so ordinary runs exclude its live provider calls.
Do not make correctness depend on an unconstrained natural-language completion
unless the prompt restricts it to one token or one schema.

## Next steps

- [Kernel REPL](kernel-repl.md) — complete session modes, JSON Lines output,
  and private inspection analysis.
- [Manifests and capabilities](manifests-and-capabilities.md) — the event
  policy, contracts, and limits these commands enforce.
- [Host configuration](host-configuration.md) — the providers, credentials, and
  installed ceilings behind `--host-config`.
- [Building agents](building-agents.md) — the agent policy that produces the
  runs you are debugging.
