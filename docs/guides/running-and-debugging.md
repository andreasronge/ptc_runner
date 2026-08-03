# Running and debugging

The Kernel line currently runs from a repository checkout through Mix. The
planned standalone macOS command and Docker image will delegate to the same
manifest, execution, result, and trace paths.

## Commands

| Command | Purpose |
| --- | --- |
| `mix ptc.run MANIFEST` | Run the manifest's qualified entry and print public JSON |
| `mix ptc.run MANIFEST --host-config HOST.json` | Install the provider aliases a provider-bearing manifest selects |
| `mix ptc.run MANIFEST --mission INPUT.json` | Run with a confined alternate input object |
| `mix ptc.run MANIFEST --output VALUE.json` | Write only the validated result value |
| `mix ptc.run MANIFEST --trace TRACE.jsonl` | Persist bounded canonical events after the run |
| `mix ptc.run MANIFEST --inspect RUN.inspection.jsonl` | Also write the owner-only private artifact |
| `mix ptc.run MANIFEST --component-override-descriptor D.json` | Compile one selected component from verified replacement source |
| `mix ptc.repl` | Start the direct transactional PTC-Lisp REPL |
| `mix ptc.repl -e EXPR -l SETUP.clj` | Run repeatable expressions with optional setup |
| `mix ptc.repl --manifest MANIFEST` | Reuse a manifest's workflow bundle and capabilities |
| `mix ptc.repl --profile PROFILE --resource NAME=DIR` | Query an immutable trace or inspection capture |
| `mix ptc.viewer --trace-dir DIR` | Browse canonical JSONL traces locally |

`mix help ptc.run`, `mix help ptc.repl`, and `mix help ptc.viewer` list the
installed options for each command.

A provider-bearing manifest requires `--host-config`. Add `--check` to assemble
and discover those providers, print a safe resolved view, and close everything
without invoking the workflow or calling a model — see
[Host configuration](host-configuration.md#verify-an-installation).

A fresh Mix invocation safely configures and starts a selected optional
provider application only after provider activity begins. A later `ptc.run`
invocation in the same VM reuses an already-running application as host-owned,
so task chaining and `iex -S mix` do not require restarting the VM.

## Run a manifest

```console
mix ptc.run ptc.json
mix ptc.run ptc.json --trace traces/run.jsonl
mix ptc.run ptc.json \
  --trace traces/run.jsonl \
  --inspect traces/run.inspection.jsonl
```

Normal traces use a `.jsonl` suffix. A run whose effective event policy is
private requires the reserved `.private.jsonl` suffix:

```console
mix ptc.run private-ptc.json \
  --trace traces/run.private.jsonl \
  --private-output results/run.private.json
```

The command checks this rule after assembly determines the effective run class
but before workflow execution or model activity. A normal run may not use the
reserved private suffix.

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
`mkdir` and `id` executables on `PATH`; it fails closed with
`result_persistence_failed` or `inspection_persistence_failed` when that
authority or mode-at-create primitive is unavailable. Publication validates
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

The current 0.x `--mission PATH` option replaces the manifest input file. Its
name is historical and is planned to become `--input` without a compatibility
alias before the standalone command contract is released.

### Replace one component's source

`--component-override-descriptor` compiles one already-selected component from
different source. It is host command authority: a manifest cannot name an
override and a generated program cannot observe one. The descriptor carries
exactly four fields:

```json
{
  "component_id": "my.agent",
  "base_source_hash": "sha256:<64 lowercase hex>",
  "source_hash": "sha256:<64 lowercase hex>",
  "path": "candidate.clj"
}
```

Both hashes use that `sha256:`-prefixed form. `path` resolves against the
descriptor's own canonical directory and may not escape it. The descriptor is
at most 64 KiB and the candidate source at most 1 MiB. Standalone command
diagnostics authorize descriptor paths against this exact four-field schema:
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

The named component must already be selected; an override replaces source and
never introduces a component. Its declared dependencies are preserved, so a
candidate cannot quietly acquire a new one. If the same ID is selected into
both the workflow and the mission, the run fails as an ambiguous target rather
than replacing both. Normal dependency, export, signature, and capability
validation still applies: an override changes which source compiles, never what
compilation permits.

The `run-started` event records the component ID and both hashes, never the
candidate source, so a trace names the base as well as the candidate. Nothing
here writes: producing candidate source and promoting it are separate steps
outside this command.

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

Current Mix failures are intended for people working from the repository.
Failures returned by the shared preparation and runtime path render only the
closed diagnostic catalog or a bounded sequence of code atoms; they never
inspect a rejected runtime term. Stable JSON command errors and exit codes are
release work for the shared standalone `ptc` frontend.

### Stable standalone process contract

The planned standalone `ptc` command treats stdout as its only machine
channel. On every ordinary or caught path it writes exactly one V1 JSON command
envelope followed by one newline:

- success exits `0`;
- a classified failure exits with the primary diagnostic's exact
  `PtcRunner.Kernel.DiagnosticCatalog` status, one of `2` through `7`; the
  catalog is authoritative because codes within one phase may intentionally
  have different statuses; and
- a caught unexpected failure writes the closed `internal/internal_error`
  envelope and exits `70`.

The envelope schema is `priv/schemas/ptc-command-envelope-v1.schema.json`.
The command never renders an inspected exception, arbitrary callback result,
credential, private value, provider response, selector, or filesystem path into
either public stream.

With `--trace-dir DIR`, the command-generated `run_ref` is also the complete
trace stem. A normal trace is exactly `<run_ref>.jsonl`; a private trace is
exactly `<run_ref>.private.jsonl`. The envelope's `artifact_class` selects which
suffix callers use, so they can locate the file without a published path.
Normal discovery excludes the private suffix; private-aware discovery accepts
and classifies it explicitly.

Stderr is not a second framing channel. The wrapper may write only bounded,
fixed, code-owned launcher messages there. The packaged boot profile configures
no Logger or SASL console handler before the command core starts. Optional
applications may not install one; the pinned packaged dependency audit and
provider-free/optional-application fixtures enforce that condition. Child
stderr is captured behind its provider boundary. Expected command diagnostics
remain inside the stdout envelope.

The pinned audit also inventories reachable same-VM writes that bypass those
handlers: `IO.warn`/`:standard_error`, direct descriptor-2 operations, and known
NIF or dependency writes. A route that can interpolate a selector, endpoint,
credential, rejected value, callback reason, exception, report, or other
arbitrary term is unsupported until it is removed or captured behind a closed
code-owned boundary. The audit fails closed when a pinned dependency revision
changes or introduces an unclassified stderr or descriptor route.

The release wrapper reserves the caller's stdout as descriptor 3, redirects
ordinary descriptor 1 to the null device before BEAM startup, and treats
descriptor 3 as code-owned envelope authority. Child processes and ports must
not inherit it. Immediately before writing, the wrapper verifies that
descriptor 3 still names the captured startup destination; it never falls back
to another descriptor.

This is not OS-enforced isolation inside one VM: trusted same-VM native code
could still name, duplicate, close, or write descriptor 3, and an identity
check cannot detect an injected write. Each supported packaged target therefore
has a pinned, focused inventory of reachable NIF/native routes that can target
numeric descriptors. If that inventory cannot establish that no reachable
route targets descriptor 3, or dependency drift invalidates it, the release
requires an outer framing process before claiming one-envelope output.

If the startup-destination identity check fails, or if the caller closes stdout
and the descriptor write fails, the writer stops without retrying on stderr or
another descriptor. The wrapper exits `74` within 5,000 milliseconds, measured
from identity-mismatch detection or the failed descriptor-3 write to observed
process exit. No valid envelope is promised on either transport failure.

`SIGINT`, `SIGTERM`, VM abort, OOM, and failure before the command boundary are
outside the V1 envelope and stderr-content contract. They may produce no
envelope or VM/OS emergency output, and the OS or shell determines their
status. Packaged tests characterize termination and child behavior but do not
promote one observed signal status to a portable guarantee. A deployment that
requires a bounded signal response, application bootstrap, or child-tree
cleanup must use the separately triggered outer supervisor design.

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
mix ptc.run examples/kernel-tutorial/03-file-agent/ptc.json \
  --host-config examples/kernel-tutorial/ptc-host.json \
  --trace tmp/inspection/run.jsonl \
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
packaging is released.

See [`ptc_viewer/README.md`](../../ptc_viewer/README.md) for the Viewer's HTTP
API, configuration, and programmatic start/stop.

## Test a workflow

Keep a deterministic fixture in normal tests. Compare the stable business
value and semantic error classification rather than timestamps, generated run
IDs, or remaining milliseconds.

Build the checks in three layers:

1. Exercise pure transformations in `mix ptc.repl`.
2. Run fixed manifest inputs with `mix ptc.run` and assert `.value` with `jq`.
3. Put live-provider checks behind an explicit flag and assert a narrow
   contract, not prose wording.

Layer 2 needs no test framework:

```console
actual="$(mix ptc.run examples/kernel-tutorial/01-orders/ptc.json | jq -c '.value')"
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
