# Stable CLI and transport-neutral application plan

**Status:** proposed; implementation-ready after review.

This plan turns the remaining command-line work in
[`product-readiness.md`](product-readiness.md) into small implementation slices.
It also removes application-file acquisition from the execution core so the
same runtime can later accept a cloud-supplied application without requiring
application or artifact paths.

The plan deliberately does not make hostile same-user process containment,
multi-tenant service isolation, or transactional artifact storage prerequisites
for fixing the current CLI. Those are different trust boundaries and should be
designed from deployment evidence.

## Current evidence

The implementation already has most of the execution machinery:

- `PtcRunner.Kernel.RunBuilder` is the shared manifest-backed assembly path.
- `PtcRunner.Kernel.ProviderRegistry` separates preparation from acquisition.
- `PtcRunner.Kernel` executes compiled bundles without opening manifest files.
- `PtcRunner.Kernel.ConfinedFile` provides bounded directory-backed reads.
- `PtcRunner.Kernel.ResultArtifact`, `PtcRunner.Kernel.InspectionArtifact`, and
  `PtcRunner.Kernel.TraceLog` already own artifact formats and publication
  behavior.
- manifest, host-configuration, and result contracts already have bounded
  validators.
- `Mix.Tasks.Ptc.Run` owns the run option/error-rendering layer. The existing
  REPL also has non-interactive script/profile modes and a distinct JSONL
  streaming protocol; its manifest-backed mode calls `RunBuilder`.

The important gaps are therefore orchestration and boundaries, not a new
evaluator:

- inspected Elixir errors are not a stable machine protocol;
- validation, destination checks, provider preparation, credentials, and
  acquisition are not ordered as an explicit public contract;
- manifest loading and execution assembly are still coupled through paths;
- bundle identity does not cover dependency edges; and
- focused `validate`, `models`, `doctor`, and `init` commands do not exist.

## Decisions

### Ship the Elixir contract before native containment

Add one shared argv parser, command dispatcher, diagnostic projector, and
`CommandEngine` in Elixir. Both the standalone entrypoint and
`Mix.Tasks.Ptc.Run` delegate to them. The Mix task prepends the fixed `run`
command and does not maintain a second option table. The engine owns only
frontend concerns: argv, path-backed acquisition adapters, destination
preflight/publication, and envelope rendering. It returns a closed
`CommandOutcome` containing the envelope and exit status. Only the standalone
wrapper writes the exact process streams and exits; the Mix adapter returns or
raises through Mix conventions and never halts the caller's VM.

Add a separate path-free `RunCoordinator` with `prepare/2`,
`open_session/1`, and `execute/1`. `prepare/2` consumes a sealed `RunRequest`
plus a trusted host installation, compiles bundles, normalizes provider
selections, classifies the run, and returns a sealed prepared run. After a
frontend performs any destination preflight, `open_session/1` owns local/active
provider work and acquisition for both one-shot and REPL execution;
`execute/1` composes that operation with Kernel execution, result guarding,
cleanup, and terminal-event finalization. Both the CLI and a cloud embedding
use this coordinator; neither `RunCoordinator` nor `RunBuilder` accepts argv,
an application path, or an artifact destination.

The first standalone package should use the smallest supported BEAM packaging
that can carry the project and its dependencies. An OTP release with a
`bin/ptc` wrapper is the baseline; an escript is acceptable only if a packaging
spike proves that the dependency and optional-provider surface works without a
parallel runtime configuration. Packaging choice must not change the command
engine or envelope schema.

The standalone boot profile starts only the command core. Optional provider
applications are loaded but not started until the coordinator has entered the
active-provider boundary. Production and release configuration disables
implicit dotenv loading in `req_llm` and `llm_db`, and the standalone entrypoint
does not call `PtcRunner.Dotenv`. Local convenience credential loading must be
an explicit adapter inside the marked boundary, not an application-start side
effect. This makes the activity flag truthful even for `doctor` and failures
before command execution.

For the standalone `ptc` entrypoint, the caller's stdout is the machine channel
on ordinary and caught paths:

- success writes exactly one JSON envelope plus a newline to stdout and exits
  `0`;
- an expected failure writes exactly one JSON diagnostic envelope plus a
  newline to stdout and exits with its documented nonzero status; and
- a caught unexpected failure writes a bounded `internal_error` envelope plus
  a newline to stdout and exits `70`.

Stderr is explicitly not part of V1 framing, but its content is still a public
surface and must be secret-safe on every supported ordinary and caught path.
Before provider data exists, the standalone boot profile disables SASL progress
and crash-report output and removes every Logger console handler. Optional
applications may not install another console handler. Logger calls and OTP
reports can still be captured by non-console telemetry if a deployment
explicitly installs it, but the packaged command does not render their message,
metadata, exception, or report to stderr. The wrapper alone may write bounded,
closed code-owned stderr messages directly; it never renders inspected
exceptions, provider configuration, selectors, credentials, private values, or
arbitrary callback reasons. Shipped provider launchers capture child stderr
into a bounded private buffer and expose only closed launch status/codes. A
shipped provider or NIF that writes process stderr directly is unsupported
until it is wrapped by that capture boundary.

The standalone release wrapper preserves the caller's stdout as private
descriptor 3, redirects descriptor 1 to the null device before BEAM starts,
and reserves descriptor 3 by contract for the code-owned envelope writer. The
writer emits the single envelope through `/dev/fd/3`; ordinary BEAM,
dependency, port, and NIF stdout still targets descriptor 1 and is discarded.
This is not OS-enforced exclusivity inside one VM: trusted same-VM native code
could still name, duplicate, close, or write descriptor 3.
The command tree also runs under a dedicated bounded group leader that absorbs
arbitrary `stdio` requests, keeping unexpected command-descended output bounded
inside the VM instead of relying only on the null device.

This design is gated by a packaged spike on every supported macOS/Linux release
target. The spike must prove that descriptor 3 survives the release wrapper and
BEAM startup, `/dev/fd/3` writes reach the original caller stdout, the
descriptor is not inherited by provider launchers or other child ports,
caller-close/broken-pipe behavior is bounded, and the wrapper preserves the
documented command exit status. The implementation may use a post-start
close-on-exec transition or another release-specific mechanism, but a child
must never receive envelope authority. If any supported target cannot satisfy
all five checks, do not fall back to dependency-wide stdout auditing; introduce
the trigger-gated outer framing process before claiming exact standalone
framing.

Descriptor separation removes ordinary stdout behavior from the dependency
support audit, but it does not remove descriptor-authority or stderr secrecy
checks. Keep a focused, dependency-version-bound inventory of any same-VM code
or NIF that can enumerate inherited descriptors or write, close, duplicate, or
replace a numeric descriptor; every reachable route must be proven unable to
target descriptor 3. Immediately before envelope emission, validate that
descriptor 3 still has the captured startup identity and fail without writing
to another target if it was closed or replaced. If the inventory or identity
check cannot be implemented on a supported target, use the outer framing
process. The focused inventory also covers reachable secret-bearing stderr
routes: explicit
`:standard_error`/`IO.warn`, Logger/`:logger`, SASL/OTP reports, console-handler
installation, uncaptured child stderr, and known NIF/direct-file-descriptor
writes. Logger/SASL routes are acceptable only because the packaged profile
removes their console destination before optional code starts. A reachable
stderr call that can interpolate a selector, endpoint, credential, rejected
value, callback reason, exception/report, or other arbitrary term fails the
gate unless it is replaced by a closed non-writing/captured API. The inventory
fails when a pinned dependency revision changes, an optional application adds a
console handler, or a new secret-bearing stderr route appears without
classification. Mix and `:host_owned` modes do not claim exact framing.

In particular, the shipped ReqLLM adapter must not pass a caller-controlled
string selector through ReqLLM's warning-producing fallback resolution.
Phase-5 normalization constructs the reviewed structured provider/model value
through a non-warning API and acquisition reuses that sealed value. An
uncatalogued but otherwise allowed model either uses that structured path or is
rejected before acquisition; its raw selector is never passed to `IO.warn`.
Keep a dependency-version audit and packaged sentinel regression for this
assumption. A new same-VM provider/dependency stderr path is unsupported until
it is replaced with an audited non-writing/captured API.

A caller parses stdout only. A VM abort, OOM, uncatchable signal, failure before
the command boundary starts, or loss of descriptor 3 may produce no envelope.
Those cases are documented local CLI limitations, not a claimed security
boundary; OS/VM emergency diagnostics are outside the caught-path content
guarantee.

`Mix.Tasks.Ptc.Run` delegates parsing, defaults, validation order, and execution
to the same engine but does not promise exact process framing. Mix compilation,
application startup, and the Mix shell may emit before or around the task. Its
tests assert semantic/parser parity, while exact one-envelope subprocess tests
target the standalone package.

Remove the task's current unconditional `Mix.Task.run("app.start")`. The Mix
adapter may explicitly ensure only the command-core applications needed for
parsing and package construction. Provider OTP applications, including
`req_llm`/its included `llm_db`, are resolved through a host-supplied
`ProviderRuntime` gate immediately after the owner atomically marks activity; a
provider kind declares which application it needs.

The gate has three explicit ownership modes:

- `:standalone_vm` owns its whole short-lived VM, may lazily start a declared
  provider application in phase 8, and relies on VM shutdown after bounded
  provider-resource cleanup rather than trying to stop shared OTP applications
  individually;
- `:mix_cli` supports ordinary shell `mix ptc.run`: a process-global,
  serialized manager calls `Application.ensure_all_started/1` only after the
  marker, records which applications it started, transfers them to VM
  ownership, and deliberately leaves them running until that Mix VM exits. On
  its first ReqLLM start it atomically sets both `:req_llm` and `:llm_db`
  `:load_dotenv` configuration to `false` before
  `Application.ensure_all_started/1`, then records successful safe startup in
  its own serialized manager state. That record contains the actual
  `ReqLLM.Supervisor` PID and a live monitor; manager handling invalidates it on
  `DOWN`, and reuse atomically verifies that the currently registered root PID
  is the recorded live PID. If ReqLLM is already running, the manager accepts
  it only with that instance-bound safe-start record. Configuration values of
  `false` alone are not evidence: an application may already have loaded dotenv
  before those values were changed. A running application without the record,
  or a restarted instance whose PID does not match it, returns
  `provider_application_unavailable`; callers that intentionally inherit
  host-started ReqLLM must use `:host_owned`; and
- `:host_owned` is required for long-lived cloud embedding: provider
  applications must already have been started by the host's supervision tree,
  and the gate only checks their availability.

No mode stops a VM-global application per run. Repeated/concurrent Mix commands
reuse the already-started application, while a cloud host never delegates its
application lifecycle to a request. Provider sessions, ports, and child
processes remain per-run `ProviderResources`; application background processes
are VM/host-owned runtime infrastructure outside that graph.

If Mix dependency metadata still auto-starts an optional provider, adjust the
application/dependency topology (or extract a provider application) rather
than weakening the marker contract. Argument, host, application, bundle, and
destination failures therefore cannot start `req_llm` or load dotenv in either
frontend. A caught failure to start in standalone/Mix CLI mode, or an
unavailable host-owned application, maps to
`active_preflight/provider_application_unavailable` with activity true; it
does not fall through to `internal_error`.

`SIGINT` and `SIGTERM` are outside the V1 process contract. The CLI promises no
Elixir-level signal cleanup, termination deadline, numeric exit status, or JSON
envelope for either signal. `System.trap_signal/3` does not support `SIGINT`,
and a noninteractive BEAM process may ignore it; VM shutdown also cannot
promise that provider close callbacks run. Packaged tests characterize whether
the chosen release wrapper terminates/reaps the VM and whether
port/launcher ownership happens to leave a child behind, but those observations
are not promoted to V1 guarantees. A deployment requirement for reliable
signal response, or a reproducible child leak under that deployment's shutdown
mechanism, is a concrete trigger for the separate outer-supervisor plan.
Service/job cancellation is outside this plan.

An outer framing process becomes a separate, trigger-gated plan if any
supported release target fails the descriptor-3 survival, noninheritance,
broken-pipe, exit-status, focused descriptor-authority inventory, or
startup-identity checks, or if reliable signal response or child cleanup
requires it. Its initial scope is stream purity and child cleanup. Static-PIE
builds, fs-verity/IMA, macOS designated requirements, credential brokers,
filesystem allowlists, and same-UID adversary claims require their own
demonstrated deployment threat.

### Use one versioned, privacy-safe envelope

V1 envelopes contain exactly:

```json
{
  "schema_version": 1,
  "command": "validate",
  "status": "error",
  "run_ref": "cmd-77r2k6m4z9q1v8x3c5n0t4w6yb",
  "error": {
    "phase": "application",
    "code": "required_property_missing",
    "message": "the application manifest is missing a required property",
    "source": {"kind": "application", "name": "ptc.json"},
    "path": "/workflow/components/0/path",
    "span": null,
    "subject": null,
    "notes": [],
    "retryable": false,
    "provider_activity": false
  },
  "secondary_errors": []
}
```

Every envelope has `schema_version`, `command`, `status`, and `run_ref`.
`status` is the closed enum `ok` or `error`. Success has `result`; failure has
`error`. Every error object also has `subject`, defined below. `command` is the
closed enum `help`, `init`, `validate`, `run`, `doctor`, `models`, or
`unknown`.

A successful validation has the same framing:

```json
{
  "schema_version": 1,
  "command": "validate",
  "status": "ok",
  "run_ref": "cmd-77r2k6m4z9q1v8x3c5n0t4w6yb",
  "result": {
    "application_content_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "effective_application_digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "workflow_bundle_hash": "0000000000000000000000000000000000000000000000000000000000000000",
    "mission_bundle_hash": null,
    "provider_activity": false
  }
}
```

Every `run` envelope also has `artifact_state`, a closed map for `trace`,
`inspection`, and `result`; each value is `not_requested`, `not_written`,
`written`, `recovery_written`, `finalization_uncertain`, or `failed`.
These are terminal states with one exact interpretation:

| State | Terminal meaning |
| --- | --- |
| `not_requested` | No destination adapter of that class was selected. |
| `not_written` | An adapter was selected, but the command stopped or policy withheld it before any failure in that adapter's own phase-6 preflight/reservation or phase-12 publication attempt. No complete artifact is claimed. |
| `failed` | That adapter's phase-6 preflight/reservation or phase-12 write/sync operation was the attempted operation that failed, and neither a durable final artifact nor the durable recovery state below is claimed. |
| `written` | The requested final artifact and required containing-directory durability steps completed. |
| `recovery_written` | The complete private-result recovery artifact reached the durable state defined below, but the requested final name did not. |
| `finalization_uncertain` | The durable private-result inode exists, but a later link/unlink/directory-sync failure prevents the command from proving which derived name or names remain. |

A requested artifact withheld after another adapter fails remains
`not_written`; it does not inherit the other adapter's `failed` state. A
phase-6 rejection marks only the rejected adapter `failed`. Before
classification, requested adapters can be reported only as `not_written`, as
specified below.
`recovery_written` is valid only when `--private-output` requested an
owner-only destination and its complete recovery artifact and containing
directory were synced, but the requested final link was not completed because
a later trace, inspection, or result-publication step failed.
`finalization_uncertain` is valid only after that durable recovery publication
and a final-link operation succeeded, but a later directory-sync/unlink step
and its rollback could not establish whether the recovery name only, final
name only, or both names remain. These states follow destination class, not
flow class: an `artifact_class: "normal"` run may use either when its caller
selected `--private-output`. Both states contain no path; the authorized
directory plus `run_ref` derives every candidate basename.
Every successful or failed `run` envelope also has top-level `artifact_class`,
exactly `unclassified`, `normal`, or `private`. `unclassified` is required for
an error before phase 5 derives the effective flow class; in that state every
artifact is `not_requested` or `not_written`, never `written`,
`recovery_written`, `finalization_uncertain`, or `failed`. Once classified, the
value never changes.
Success is always classified. A classified value makes a written trace
basename unambiguous even when no success `result` exists. Non-`run` envelopes
omit both fields. The generated schema expresses these command/status variants
and the `unclassified` artifact-state restriction as closed `oneOf` branches
rather than making arbitrary extra fields optional.

Every `run` envelope also has a closed `execution` object:

- before Kernel execution starts: exactly `{"state":"not_started"}`;
- after it starts but a caught failure prevents a terminal Kernel outcome:
  exactly `{"state":"incomplete","usage":null-or-usage,
  "evaluation_memory":null-or-evaluation-memory}`; and
- after a terminal Kernel outcome: exactly
  `{"state":"finished","outcome":"ok-or-error",
  "diagnostic":null-or-diagnostic,"usage":usage,
  "evaluation_memory":evaluation-memory}`. `diagnostic` is exactly `null` for
  `outcome: "ok"` and the same closed, bounded diagnostic shape as top-level
  `error` for `outcome: "error"`.

The coordinator attempts the bounded usage and evaluation-memory snapshots
before rendering an `incomplete` caught-path envelope; JSON `null` means the
owner could not supply that snapshot. A VM abort may still produce no envelope.
A success always has `state: "finished"` and `outcome: "ok"`. Cleanup or
publication can turn the command into an error without rewriting the preserved
Kernel outcome: for example, a result collision after successful execution has
top-level error status, `execution.outcome: "ok"`, and
`execution.diagnostic: null`. If a later cleanup/internal/publication failure
replaces a terminal Kernel error as the primary diagnostic, the original
Kernel phase/code/subject remains in `execution.diagnostic`.

Every error envelope also has `secondary_errors`, an array of at most six
closed diagnostic objects using the exact top-level `error` shape. It is `[]`
for a failure with no displaced compound diagnostic. Every successful `run`
also includes `secondary_errors: []`; other command-success variants omit the
field. For a compound failure it contains every non-primary diagnostic that
reached a terminal classification, ordered by the precedence table below and
then by that phase's specified failure order, with no duplicate
phase/code/subject triple. It never contains an unclassified exception or
provider reason. `execution.diagnostic` remains the convenient terminal-Kernel
projection; when that same diagnostic is non-primary it also appears in
`secondary_errors`. Thus a result-contract failure or caught internal failure
followed by cleanup failure remains machine-visible even when Kernel execution
was successful or incomplete, and `doctor --connect` preserves a failed check
when later cleanup becomes primary.

`run_ref` is a command-boundary-generated `cmd-` plus the fixed-width
26-character
lowercase Crockford Base32 encoding of 128 bits of OS entropy. Treat the entropy
as one unsigned big-endian integer, prepend two zero padding bits, and emit the
most-significant five-bit group first. The exact alphabet is
`0123456789abcdefghjkmnpqrstvwxyz` (no `i`, `l`, `o`, or `u`), so the first
character is restricted to `0` through `7`. The accepted form is
`\Acmd-[0-7][0-9abcdefghjkmnpqrstvwxyz]{25}\z`; all-zero entropy encodes as 26
zeroes and 16 bytes of `0xff` encode as `7` followed by 25 `z` characters. It
is allocated at the standalone command boundary before argv parsing, is never
accepted from a manifest or caller, and is independent of manifest
`events.run_id` and `events.trace_id`. Every emitted envelope has one; if
entropy allocation fails before that boundary, the process may exit without an
envelope. When `--trace-dir` makes the CLI own event identity, both generated
event IDs are exactly `run_ref`; the resulting basename is therefore
`<run_ref>.jsonl` or `<run_ref>.private.jsonl`. `artifact_class` selects the
suffix after classification without putting a path in the envelope. An
unclassified failure has no trace artifact to locate. An explicit manifest
event ID is never copied into `run_ref`.

`error.phase` and `error.code` are the closed enums in the catalog below.
`message` is a bounded code-owned repair sentence, but is informational and may
be clarified within V1; clients branch only on phase/code. `source`, `path`,
and `span` retain safe provenance when available. `source` is JSON `null` or
exactly `{"kind": ..., "name": ...}`. Its closed `kind` enum is `host`,
`application`, `component`, `input_contract`, `result_contract`,
`external_input`, `component_override`, or `runtime`. `name` is the same
bounded portable logical name from either acquisition adapter. The host,
application, external-input, and override top-level documents use the fixed
public names `ptc-host.json`, `ptc.json`, `input.json`, and
`component-override.json`; component and contract names use their captured
portable logical names. Runtime errors use the fixed name `ptc-runtime`.
Provider failures have `source: null` because a safe provider alias belongs in
`subject`, not source provenance. No source contains an
absolute path, hostname, credential name, caller-selected private-input name,
candidate component name, or artifact path. The renderer accepts only a closed
diagnostic struct and never serializes inspected terms, exception text, stack
traces, rejected values, credentials, private input, provider exchanges,
generated source, arbitrary metadata, endpoints, or callback reasons.

`error.path` is also a role-aware public projection, not a raw JSON pointer
assembled from rejected keys. When non-null it is an RFC 6901 JSON Pointer:
the document root is the empty string, property segments use `~0`/`~1`
escaping, and array indices are decimal. Manifest, host, and override schema
errors expose only schema-declared property names and numeric indices; an
unknown or duplicate property reports its safe parent pointer. Credential and
private-input documents expose only fixed role-level pointers.

Do not ask the renderer to recover structure from the current flattened
dotted/indexed `ValueContract` strings. Change `ValueContract.classify/2` to
retain an internal typed path as a list containing only
`{:property, schema_declared_name}` and
`{:index, nonnegative_integer}`; the root is `[]`. Decode JSV's instance
pointer first, then walk it together with the exact schema node for that error
(including its selected or currently traversed tagged-union branch). A segment
is a property only when that node's `properties` declares it, and an index only
when that node is an array with an `items` schema. A property name declared
elsewhere in the contract does not authorize it at this location. At the first
unknown or structurally inconsistent segment, stop without retaining the
rejected segment or anything below it; the retained list is therefore the safe
parent path. If the error cannot be associated with a bounded schema path,
retain no path.

The diagnostic projector accepts only that typed representation. It renders
properties with RFC 6901 `~0`/`~1` escaping and indices as decimal segments; it
never parses dots, brackets, slashes, or decimal-looking text from a flattened
string.
Input- and result-contract paths therefore retain only locally declared
segments. If no safe projection exists, public `error.path` is `null`.

`error.span` is JSON `null` or exactly
`{"start_byte": nonnegative_integer, "end_byte": nonnegative_integer}`.
Offsets are zero-based into the exact UTF-8 bytes named by `source`,
`end_byte` is exclusive, and `start_byte <= end_byte <= byte_size(source)`.
Never combine a span with `source: null`; use `span: null` when a decoder or
runtime cannot prove the byte range. V1 deliberately does not expose
line/column coordinates.

`error.subject` is JSON `null` or an object with exactly `kind`, `name`,
`operation`, and `occurrence`. `kind` is `provider`; `name` is either a safe
installed alias or, for `provider_unknown`, the manifest alias that already
passed the same bounded alias validator. The closed operation enum is
`declaration`, `selection`, `local`, `application`, `credentials`,
`connectivity`, `acquisition`, `execution`, or `cleanup`. `occurrence` is JSON
`null` or exactly
`{"destination":"workflow|mission","index":nonnegative_integer}`. The index is
the zero-based position in that destination's manifest provider list. It is
non-null only when the failure is attributed to one selected occurrence;
installation-declaration, provider-application, credential-resolution, and
aggregate cleanup failures use `null`. Audited-local failures use the selected
occurrence they were checking.
Selection-validation failures use operation `selection`; selection,
connectivity, acquisition, or provider-execution failures use the occurrence
that failed when it is known. The locator contains no selection value or
manifest path.
Provider-specific diagnostics, including doctor failures, always carry this
subject. A run-wide cleanup failure involving more than one provider uses
`subject: null`; its public contract is the aggregate cleanup code rather than
an arbitrary first failure. Non-provider diagnostics also use `subject: null`.
No selector, endpoint, credential name, callback reason, or fingerprint enters
the subject.

V1 reserves `error.notes` but requires it to be exactly `[]`. This avoids a
second loosely specified discriminator; a future schema version can add a
closed note vocabulary.

The authoritative V1 diagnostic catalog is:

| `phase` | Allowed `code` values | Exit | `retryable` |
| --- | --- | --- | --- |
| `arguments` | `invalid_command`, `invalid_arguments`, `conflicting_arguments` | `2` | false |
| `host` | `host_unavailable`, `host_invalid`, `host_schema_invalid`, `installed_limit_invalid`, `installation_revision_missing` | `3` | false |
| `application` | `application_unavailable`, `invalid_json`, `duplicate_property`, `schema_violation`, `required_property_missing`, `reference_missing`, `document_limit_exceeded`, `contract_invalid`, `input_contract_failed`, `override_invalid`, `event_identity_conflict` | `3` | false |
| `bundle` | `bundle_invalid`, `bundle_limit_exceeded`, `compile_failed`, `entry_invalid` | `3` | false |
| `provider_declaration` | `provider_unknown`, `selection_invalid`, `selection_unverifiable`, `placement_denied`, `dependency_invalid`, `data_policy_denied` | `4` | false |
| `destination` | `invalid_destination`, `destination_exists`, `private_destination_required`, `recovery_reservation_failed` | `7` | false |
| `local_preflight` | `environment_unavailable`, `adapter_unavailable`, `launcher_unavailable` | `4` | false |
| `active_preflight` | `provider_application_unavailable`, `selection_rejected`, `selection_validation_failed`, `selection_validation_timeout`, `credential_unavailable`, `authentication_rejected`, `connectivity_rejected`, `connectivity_protocol_error`, `connectivity_unsupported`, `connectivity_outcome_unknown` | `4` | false |
| `active_preflight` | `connectivity_unavailable`, `connectivity_rate_limited` | `4` | true |
| `provider_acquisition` | `provider_unavailable` | `4` | false |
| `provider_acquisition` | `provider_protocol_error`, `provider_policy_changed` | `4` | false |
| `execution` | `workflow_failed`, `mission_failed` | `5` | false |
| `execution` | `runtime_limit_exceeded`, `run_timeout` | `6` | false |
| `execution` | `provider_failed` | `5` | false |
| `execution` | `event_capture_limit_exceeded`, `event_sink_unavailable`, `inspection_capture_limit_exceeded`, `inspection_sink_unavailable` | `7` | false |
| `result_cleanup` | `result_invalid`, `result_contract_failed`, `result_limit_exceeded`, `provider_cleanup_failed`, `provider_cleanup_timeout` | `7` | false |
| `publication` | `trace_publication_failed`, `inspection_publication_failed`, `result_publication_failed`, `recovery_cleanup_failed`, `destination_collision`, `initialization_failed` | `7` | false |
| `internal` | `internal_error` | `70` | false |

No adapter adds a code. Internal lower-level reasons map through one checked-in
catalog module whose rows contain phase, code, exit, retryability, and the
bounded default message. The envelope JSON Schema, renderer clauses, and
phase/code test fixtures are generated from that one module; generation fails
for a duplicate pair or a pair absent from this table. When activity may have
occurred, a failure not explicitly listed as retryable remains false because
the CLI cannot prove that retrying will not repeat an external effect.

Sink mappings are closed as well. A code-owned event or inspection record
rejected by its installed encoded, retained, or count bound maps respectively
to `event_capture_limit_exceeded` or
`inspection_capture_limit_exceeded`. Failure to claim, call, finalize, or read
a sink because its owner/process is unavailable or its protocol fails maps to
`event_sink_unavailable` or `inspection_sink_unavailable`. This mapping applies
whether capture fails before workflow evaluation, during execution, or while
finalizing terminal evidence; `execution.state` independently reports how far
Kernel execution progressed.

Initial exit classes are:

| Status | Meaning |
| --- | --- |
| `0` | success |
| `2` | invalid command or arguments |
| `3` | invalid host configuration, application, input, contract, or bundle |
| `4` | installed provider, credential, launcher, or environment unavailable |
| `5` | classified workflow or mission failure |
| `6` | enforced runtime limit |
| `7` | result, cleanup, trace, inspection, output, or initialization failure |
| `70` | caught unexpected internal failure |

The string code, not the numeric status or human message, is the primary
machine discriminator.

Command success results are closed:

- `help` has exactly `topic`, `usage`, and `notices`. `topic` is the closed
  enum `root`, `init`, `validate`, `run`, `doctor`, or `models`; `usage` is a
  non-empty ordered array of bounded code-owned usage lines; and `notices` is
  `[]` except that doctor help contains exactly
  `["doctor --connect may perform one or more real provider requests and may incur provider cost"]`.
- `init` is `{"created":["main.clj","ptc.json"]}` in that fixed order.
- `validate` has exactly `application_content_digest`,
  `effective_application_digest`, `workflow_bundle_hash`,
  nullable `mission_bundle_hash`, and `provider_activity: false`, as in the
  example above.
- A normal `run` result has exactly `result_class: "normal"` and `value`;
  `value` is an admitted JSON value.
- A private `run` result has exactly `result_class: "private"`, with no
  `value`. Run accounting lives only in the top-level `execution` object.
- `doctor` has exactly `checks` and `provider_activity`. `checks` is ordered and
  each item has exactly `name`, `status`, and `code`. Names and allowed
  status/code pairs are closed below.
- `models` has exactly `installations`, ordered by alias. Each item has exactly
  `alias`, `source`, required `installation_revision`, `data_class`,
  `accepts_data`, and `destinations`; `source` is one of the existing closed
  host source identifiers or `custom`, while class and destinations use the
  existing closed host enums. `custom` is produced only from a trusted
  programmatically injected installation catalog, never from a host JSON
  document.

Every non-null run `execution.usage` uses the same closed public projection:
exactly
`remaining_ms`, `capability_calls`, `subordinate_evaluations`,
`protocol_errors`, `evaluation_memory_bytes`, `evaluation_history_bytes`,
`evaluation_continuation_bytes`, and `events_dropped`. Capability/event maps
have bounded safe names and nonnegative integer counts. Every non-null
`execution.evaluation_memory` has exactly `defined_count`, `history_count`,
`memory_bytes`, `history_bytes`, and `bytes`, all nonnegative integers. Hashes
are lowercase 64-character SHA-256 hex; application digests carry the
`sha256:` prefix.

`artifact_state` is the sole publication authority; command results do not
duplicate it as booleans.

Doctor checks appear in this exact order: `runtime`, `application`, `viewer`,
then the applicable per-provider checks in installed-alias byte order. A
provider check name is exactly `provider/<alias>/local`,
`provider/<alias>/selection`, `provider/<alias>/credentials`, or
`provider/<alias>/connectivity`; aliases already exclude `/`. Within one alias,
the fixed order is local, selection, credentials, connectivity. Omit selection
when there is no application occurrence for that alias. Omit a credential
check when the descriptor declares no credential names. Omit a connectivity
check exactly when its connectivity mode is `none`; `acquisition` and `probe`
both include it. The only success-result pairs are:

| Check name | Allowed `status` / `code` |
| --- | --- |
| `runtime` | `pass` / `supported`; `warn` / `unsupported` |
| `application` | `pass` / `valid`; `skipped` / `not_requested` |
| `viewer` | `pass` / `available`; `warn` / `optional_unavailable` |
| `provider/<alias>/local` | `pass` / `available`; `skipped` / `application_required`; `skipped` / `active_check_required` |
| `provider/<alias>/selection` | `pass` / `declarative`; `pass` / `available`; `skipped` / `active_check_required` |
| `provider/<alias>/credentials` | `pass` / `available`; `skipped` / `requires_connect` |
| `provider/<alias>/connectivity` | `pass` / `available`; `skipped` / `requires_connect` |

A required local, selection, credential, or connectivity failure produces the
matching top-level diagnostic instead of inventing a warning check code. Thus
this table and the diagnostic catalog jointly close every doctor outcome.
`application_required` means an audited-local callback needs the final
post-selection context but no application was supplied. `active_check_required`
means either the custom provider's nominal local check is unverified phase-8
work or its selected occurrence requires active selection validation;
`doctor --connect` runs the applicable check after marking activity instead of
emitting the skipped pair.

No public surface emits or fingerprints the raw installed model selector. This
includes envelopes, `models`, `doctor`, normal traces, inspection indexes, and
provider snapshots copied into `run-started`. The current `openai-compat`
selector may contain a base URL, URL userinfo, or query credentials; even a
deterministic hash would expose equality and permit guessing of low-entropy
values.

Make `installation_revision` required for every installed provider and define
it as the host's bounded, non-secret public behavior identity. Restrict it to a
portable lowercase ASCII identifier matching exactly
`\A[a-z][a-z0-9._-]{0,127}\z` rather than accepting a URL or free-form text.
The host must change it whenever behavior not otherwise captured changes:
model or endpoint behavior, adapter/launcher build, MCP tool mappings/effects,
replay fixture set, snapshot-source policy, or another installed authority
detail.

Absence is always the phase-2 `host/installation_revision_missing` diagnostic,
including for `models` and for an installed provider the application does not
select. The host decoder maps that exact missing required field before generic
host-schema reporting and attaches the affected safe alias with provider
operation `declaration`; its source is `null` under the provider-diagnostic
rule. Phase 5 assumes every installed descriptor already carries a valid
revision and never owns this error. The generated host schema still marks the
field required, so schema, decoder, catalog, and command behavior agree.

Do not replace the existing runtime-captured evidence with that operator
revision. Public provider identity has two selector-safe projections. The
declaration projection contains alias, source, required revision, data policy,
and non-secret selected policy/ceilings. The acquisition projection contains
only bounded public facts observed while acquiring the selected provider: for
MCP, protocol/transport kind plus the discovered public tool
schema/description/effect hashes and safe server-info hash; for replay and
native trace/inspection sources, the captured content identity; and for every
source the existing algorithm-qualified `content_snapshot_hash` when one is
available. Canonical hashing of the acquisition projection produces a separate
`acquisition_identity_hash`. The public provider `snapshot_hash` covers both
projections. A content change therefore changes acquired/public evidence even
when the operator forgot to bump `installation_revision`, while the raw
selector, endpoint, command, path, credentials, and any hash derived from those
secret-bearing values stay internal. Citation-bearing snapshot query results
continue to copy `content_snapshot_hash` unchanged. The revision remains
operator attestation—the runtime cannot prove it describes a remote service or
local resource—but it covers behavior that acquisition cannot observe safely.

Publish the envelope as a generated JSON Schema. The renderer and subprocess
fixtures consume that schema rather than maintaining parallel handwritten key
sets.

### Make phase ordering an executable contract

`CommandEngine` and the path-free `RunCoordinator` jointly implement these
observable phases, with fixed ownership:

1. `CommandEngine` parses command arguments;
2. `CommandEngine`, or an embedding host adapter, loads or accepts the trusted
   host installation and installed limits;
3. an application adapter captures and validates application documents, input,
   contracts, and permitted component overrides; the frontend or embedding host
   also resolves a destination-free `ExecutionPolicy`, then seals both in a
   `RunRequest`;
4. `RunCoordinator.prepare/2` compiles immutable workflow and mission bundles
   and validates the selected entry;
5. `RunCoordinator.prepare/2` prepares provider declarations from inert
   descriptors, classifies the effective flow with no callback, credentials,
   process launch, network activity, or discovery, and computes the effective
   application digest from normalized selections;
6. `CommandEngine`, or the embedding host's publication policy, preflights
   every locally knowable result, inspection, and trace destination error;
7. `RunCoordinator.open_session/1` starts the event and optional inspection
   owners from the sealed `ExecutionPolicy`, then runs shared audited-local
   provider checks that perform no credential access, process launch, network
   activity, discovery, or unbounded callback;
8. `RunCoordinator.open_session/1` enters the active-provider boundary, runs any
   unverified/active preflight, and resolves credentials;
9. `RunCoordinator.open_session/1` acquires providers, including MCP discovery,
   and returns one owner-backed `ExecutionSession`;
10. `RunCoordinator.execute/1` assembles and executes the Kernel;
11. `RunCoordinator.execute/1` guards the result, validates its contract,
    projects it to the selected native/JSON policy, closes every acquired
    provider, and finalizes terminal events from the compound
    execution/contract/cleanup outcome; and
12. `CommandEngine`, or an embedding host persistence adapter, publishes the
    result only when cleanup succeeded, while permitting requested trace and
    inspection adapters to publish the terminal failure evidence needed to
    diagnose cleanup failure.

Phase 6 evaluates all pure destination checks without creating an artifact,
then chooses at most one diagnostic in this fixed order: trace, inspection,
result. Within a class, structural/authority invalidity precedes an occupied
destination. If any pure check fails, only the first class in that order is
`failed`; every later or otherwise valid requested class is `not_written`, and
no private recovery reservation is created. If all pure checks pass, phase 6
creates the private-result recovery reservation when requested. Reservation
failure is non-retryable `destination/recovery_reservation_failed`, marks
result `failed`, and leaves trace/inspection `not_written`.
Successful reservation is internal transient state: if the command later
stops before a valid result and cleanup removes the invocation-owned empty
reservation, result is `not_written`; failure to remove it is result `failed`
and adds non-retryable `publication/recovery_cleanup_failed`, whose bounded
message tells the caller to inspect the derived recovery name. This fixed
phase-6 order is independent of argv order and is shared by directory and
embedding publication policies.

One envelope has one primary diagnostic. Compound failures use this total
precedence, highest first:

| Precedence | Primary diagnostic |
| --- | --- |
| 1 | `result_cleanup/provider_cleanup_timeout` |
| 2 | `result_cleanup/provider_cleanup_failed` |
| 3 | a caught `internal/internal_error` from preparation, execution, or publication |
| 4 | the phase-11 result guard/contract/limit diagnostic |
| 5 | the terminal Kernel execution/provider diagnostic |
| 6 | the first phase-7–9 local/active/acquisition diagnostic |
| 7 | the first event/inspection sink activation, capture, or finalization diagnostic |
| 8 | the recovery-reservation cleanup diagnostic, otherwise the first phase-12 publication diagnostic in trace, inspection, result order |

Phases 1–6 stop before a compound outcome is possible; phase 6 performs the
ordered selection above and emits only that one diagnostic. Phases 7–9 may have
started sinks or provisional/provider resources, so their primary failure can
be accompanied by sink-finalization or rollback/cleanup failure. Cleanup is
highest because resource state and result withholding dominate a completed or
partially opened computation. A lower-precedence failure never replaces the primary
phase/code/subject: `execution` preserves the Kernel outcome,
`secondary_errors` preserves every displaced classified diagnostic up to the
closed six-entry maximum, and `artifact_state` records every publication
already written, failed, or withheld. The phase structure makes six
secondaries sufficient: at most one classified diagnostic from each
internal-catch, result-guard, Kernel-or-session-opening, event-sink,
inspection-sink, and publication category can accompany the primary cleanup
diagnostic. Within one row, the first failure in that phase's specified order
is primary. Publication still attempts only the evidence explicitly permitted
after the higher-precedence failure.

`recovery_cleanup_failed` exists only while unwinding an already classified
failure or cleanup outcome, so that earlier diagnostic remains primary under
the table and the recovery cleanup failure is retained in `secondary_errors`.
Reservation creation happens in phase 6 before compound work and therefore
emits `recovery_reservation_failed` as the sole primary diagnostic.

`RunCoordinator.prepare/2` accepts only a sealed request and trusted
installation and returns a sealed prepared run containing classification,
digests, normalized selections, execution policy, and an activity marker still
set to false.
`open_session/1` consumes that prepared run exactly once, owns provider
activity and phases 7–9, and returns a non-forgeable `ExecutionSession`
containing the live event/optional inspection owners, acquired owner-backed
resource graph, and complete Kernel configuration. It starts the sinks before
the first phase-7 check so both one-shot and REPL modes have the same event
lifecycle; any failed open closes the sinks and resource graph under the same
bounded owner. Its owner must either pass it to one-shot execution or transfer
it once to the REPL session owner; owner death or explicit close runs the same
bounded cleanup and sink finalization.
`execute/1` is the one-shot operation: it opens a prepared run through
`open_session/1`, runs phases 10–11, and returns a `RunOutcome` after cleanup.
An internal `execute_session/1` consumes an already-open session exactly once
for this composition; it is not a second acquisition path.

Neither operation knows argv, paths, destinations, or publication callbacks.
`CommandEngine` never reproduces compilation, selection, acquisition,
execution, or cleanup semantics. A cloud host calls the same `prepare/2` and
`execute/1`, with a memory application adapter and no file destinations.
`validate` calls `prepare/2` only. The manifest-backed Mix REPL calls
`prepare/2` and `open_session/1`, transfers the returned handle to
`ReplSessionOwner`, and evaluates its streaming/script modes without first
running a workflow. Its manifest mode accepts `--host-config HOST.json`,
resolves it into the same trusted installation used by `mix ptc.run`, and
requires it for a provider-bearing manifest; the option is rejected in direct
and code-owned profile modes. Provider-free manifests may omit it. The REPL
never calls `RunBuilder.load_and_build/2` or constructs an empty registry as a
parallel orchestration path. Decompose the current `RunBuilder` along this
boundary; any retained builder helpers are internal to the coordinator and
cannot become a second file-oriented orchestration path.

After `prepare/2` resolves classification, a private manifest REPL is allowed
only as an attached interactive session with explicit `--private-terminal`.
The flag is rejected for non-interactive `-e`/`--load` execution and when
stdin or stdout is not a terminal. Without that authorization the prepared
session is closed before evaluation and returns
`destination/private_destination_required`; no evaluated value or print reaches
stdout. With it, the attached terminal is the authorized private result/print
sink and private event persistence still requires the reserved private trace
form. Direct REPL and normal manifest sessions reject `--private-terminal`;
the existing code-owned private profile keeps its equivalent explicit-terminal
rule. This intentionally replaces the current behavior that prints a private
manifest result in script mode.

`ExecutionPolicy` contains exactly the resolved run/trace event identities,
whether private inspection capture is enabled, and the selected `native` or
`json` result projection. These values affect sink construction or result
guarding before publication, so they belong in the path-free request rather
than in a destination adapter. They contain no file path, object-store key, or
publication callback. `CommandEngine` generates its `run_ref` before parsing so
even argument failures can use it, then uses that value for event identities
when `--trace-dir` is selected. An embedding host may supply bounded explicit
identities and capture/projection policy. `open_session/1` starts event and
optional inspection owners from this sealed policy before recording any
session or execution evidence; phase 12 only persists the already-classified
outcome.

Standalone and Mix `validate`/`run` always seal `result_projection: :json`;
V1 exposes no CLI projection option. `validate` uses that same policy when
computing the effective application digest even though it does not execute or
project a result. The manifest-backed Mix REPL always seals
`result_projection: :native`: its trusted local, human-oriented Clojure
formatter and continuation history consume the bounded native/public
projection rather than the command envelope's JSON value. It exposes no
projection option and therefore intentionally has a different effective digest
from an otherwise identical `mix ptc.run`. `:native` is otherwise available
only to trusted embedding callers.

`validate` stops after phase 5. It proves package closure, compilation, entry
validity, provider declarations, placement, provider dependency/data-policy
compatibility, effective flow classification, and installed/effective
ceilings. It never invokes local or active preflight, a credential resolver,
provider acquisition, MCP discovery, or the network.

Destination preflight in phase 6 rejects an already occupied or invalid
destination before possible provider activity. It is not a cross-process
reservation guarantee: another process can race after preflight. Final
publication remains exclusive and no-clobbering; a late collision is a
non-retryable phase-12 failure because provider effects may already have
occurred. Do not add a 4,096-file lock pool, hidden staging hierarchy,
filesystem-type allowlist, or blanket FUSE/9p/virtiofs rejection in this slice.
The exception is the mandatory private-output recovery reservation described
below: it is needed to preserve the owner-only destination, not to strengthen
ordinary `--output` concurrency. If observed normal-output
workloads require spend-before-run reservations, design one bounded sidecar
lease per destination without exposing an empty/incomplete final artifact.

Keep current installed and manifest-narrowed runtime limits. Do not add an
arbitrary standalone five-minute ceiling. A future service may impose job
deadlines outside the shared engine.

Add three installed-only limits:

| Limit | Default | Accepted range | Effective application identity |
| --- | ---: | ---: | --- |
| `provider_cleanup_timeout_ms` | `5_000` | `100..30_000` | included |
| `selection_validation_timeout_ms` | `5_000` | `100..30_000` | included |
| `doctor_connectivity_timeout_ms` | `10_000` | `100..30_000` | excluded; doctor-only |

Applications cannot declare or narrow any of them. The first two are required
in the sealed execution limits and enter the effective-limit projection and
digest because they change run behavior. The doctor connectivity timeout is
required in the sealed command installation used by `doctor --connect` and
bounds both probe- and acquisition-backed connectivity checks, but ordinary
`run` never consumes it; it therefore does not enter application identity.
This doctor health-check deadline does not add or substitute for the normal
LLM provider timeout deferred to the separate model-boundary roadmap.

Replace the current one-list limit reflection with one checked-in
`LimitCatalog`. Every row has the exact name, scope
(`manifest_narrowable` or `installed_only`), compiled default, installed
default, minimum, maximum, and whether it participates in effective identity.
`Limits`, host decoding/schema generation, manifest decoding/schema generation,
and the effective-limit projector all consume that catalog. The host accepts
both scopes with each row's own range. The manifest accepts only
`manifest_narrowable` names and can only narrow their installed ceilings.
Adding a struct field without catalog metadata fails generation, so no
installed-only timeout can leak into the application schema and the host schema
cannot advertise the old generic 30-day range for these rows.

Cleanup derives reverse dependency layers from the sealed provider graph and
runs them under one monotonic deadline. Within a layer, it starts every closer
in a monitored worker, in reverse acquisition order, before waiting for any of
them. It divides the remaining deadline by the number of remaining layers so a
hung consumer cannot consume the time reserved to attempt a later provider
layer. At the end of a layer's slice, it terminates unfinished workers and
their owned trees, then advances to the next layer. Independent closers in one
layer may therefore overlap, while a provider never closes before a consumer
that depends on it has been attempted and bounded.

Before invoking acquisition, `ProviderResources.begin_acquisition/2` creates a
pending `AcquisitionLease` with its dependency resource IDs. The registry runs
the acquisition callback in a monitored worker owned by that lease and passes
it an opaque `ResourceRegistrar`. Every shipped process/port constructor must
use registrar-owned start/open operations that atomically register the root
before exposing it to callback code or proceeding to the next fallible step.
The supported acquisition contract forbids creating an unmanaged root and
reporting it later.

On an error, raise, exit, descriptor/result mismatch, or acquisition-worker
death, the resource owner rolls back every provisional root under the same
cleanup bound. Success commits the lease with its final idempotent closer,
dependency edges, and capabilities/exports; only a committed lease can return
capabilities to the coordinator. The final closer may perform graceful
protocol shutdown, but the owner always retains authority to force-terminate
the registered roots. Migrate the shipped LLM/replay builders, MCP transports,
trace/inspection snapshots, and the custom builder API to this lease contract.
Legacy custom callbacks that cannot satisfy it are unsupported and removed in
this intentional 0.x break. Custom builders are trusted same-VM host code: the
runtime can clean roots registered through the framework-owned constructors,
but it cannot prevent arbitrary Elixir code from spawning an unlinked process,
transferring a port, or hiding a resource in a closure. Registration is
therefore an explicit trusted-callback obligation, not a sandbox guarantee.
Hosted untrusted extensions require a later process/isolation boundary.

Any closer failure classifies the run as `provider_cleanup_failed`; expiry of a
layer slice with unfinished work classifies it as
`provider_cleanup_timeout`. Both outcomes withhold the result and continue only
with authorized terminal evidence publication. The same global deadline and
layer scheduling apply to ordinary completion, construction rollback,
acquisition rollback, caught failure, and controlling owner death while the VM
remains alive. OS signal shutdown is not included.

Make this one runtime contract, not CLI orchestration around the current
`close/0` list. Introduce a central owner-backed `ProviderResources` handle.
Each registered `ProviderResource` has a generated resource ID, dependency
resource IDs, one idempotent closer, and monitored process/port roots. The owner
validates the bounded acyclic graph, performs the scheduling above exactly
once, records the closed outcome, and also closes when its controlling owner
dies. `RunConfig` holds this handle instead of a list of functions.
`ProviderRegistry.acquire` must use the pending lease and registrar protocol
above and cannot return a raw process, port, closer, capability, or export from
an uncommitted acquisition.

`Kernel.run`, `RunBuilder` rollback, `Runner`, and `ReplSessionOwner` all call
or transfer ownership to this same resource owner; none retains a private
cleanup loop. Direct embedding constructors that
need provider resources must create/register through this API. Delete the
current public `ProviderRegistry.build/4` convenience contract that returns a
raw `close/0`. Its replacement requires a caller-owned `ProviderResources`
handle and returns only after acquisition has registered its closer and owned
roots with that handle. Migrate all direct callers, including embedding and
live E2E setup, rather than retaining a bypass for compatibility. This is an
intentional 0.x break of both `build/4` and the opaque
`provider_resources: [close/0]` option. Plain runs with no providers use an
empty handle. REPL session ownership transfers the handle with the rest of the
one-shot config so owner death cannot orphan it.

### Make provider activity monotonic

The command coordinator owns one monotonic `provider_activity` marker. It
changes from false to true immediately before:

- an unverified host callback;
- any active provider preflight;
- any credential resolution;
- optional provider application startup; or
- provider acquisition/discovery.

The transition and work authorization happen in one owner-process operation;
there is no separate read followed by update. Once true, the marker cannot be
reset by a later result or adapter. An ambiguous caught failure reports true.
A whole-VM crash may have no envelope.

Replace callback-derived preparation metadata with a sealed
`ProviderDescriptor` registered alongside each builder. It declares bounded
credential names, data policy, service dependencies, destination eligibility,
workflow-LLM identity, a closed connectivity mode, a closed selection-validation
mode, and a data-only `SelectionRules` value. The selection-validation mode is
exactly `declarative` or `active`: `declarative` means the generic IR completely
validates the selection in phase 5, while `active` means phase 5 can only
normalize the generic portion and the registered implementation must supply a
bounded `selection_validator` operation for phase 8. The connectivity mode is
exactly `none`,
`acquisition`, or `probe`: `none` means the provider has no meaningful remote
connectivity operation; `acquisition` means its normal bounded
acquisition/discovery is the connectivity operation; and `probe` requires a
separate bounded `connectivity_probe` implementation and a `probe_effect` of
exactly `metadata` or `completion`. `probe_effect` is absent for the other
connectivity modes. Phase 5 consumes only the descriptor and never looks up or
invokes the implementation. Shipped host decoding constructs it from the
validated host document; custom embeddings must provide one and cannot defer
those facts to a callback.

Provider registration rejects an extraneous probe or `probe_effect` for `none`
or `acquisition`, rejects a missing effect for `probe`, and rejects an
extraneous selection validator for `declarative`. For `active`, it requires the
registered implementation to supply `selection_validator`. For `probe`, the
phase-8 dispatcher validates that the registered provider implementation
supplies `connectivity_probe` immediately after atomically marking provider
activity and before resolving credentials or making a request. A missing
implementation maps to
`active_preflight/connectivity_unsupported`; it is not treated like legitimate
`none`. Shipped MCP descriptors use `acquisition`, shipped live-LLM
descriptors use `probe`, and local snapshot/replay descriptors use `none`.

`SelectionRules` is a sealed, non-executable IR rather than an arbitrary JSON
Schema or function. It contains exact allowed/required keys, per-key scalar or
unique-list type, defaults, integer ranges, enum/set membership, and these
closed cross-rules only: `subset_of`, `required_when_set_nonempty`, and
`ceiling_of_context_limit`. The descriptor also carries the finite named sets
those rules reference. The runtime supplies code-owned pure normalizers for the
closed shipped source identifiers `mcp`, `llm`, `llm_replay`,
`ptc_trace_snapshot`, and `ptc_inspection_snapshot`; for example, the MCP
normalizer checks `allow` against the installed public-tool set, requires it
for a write-capable installation, checks `model_visible` as a subset of the
allowed installed-visible set, and narrows timeout/result ceilings against
both installation and context. These are the existing host-document
identifiers; descriptor construction does not introduce shorter aliases.

A custom kind may use the generic IR only. If its selection cannot be
expressed by these rules, its descriptor declares `active` validation.
`prepare/2` then seals the normalized selection with
`validation_state: active_required`; it never stores the callback or an
arbitrary reason in the prepared run. `validate` recognizes that state and
returns `provider_declaration/selection_unverifiable` rather than claiming the
selection was validated. `run` and `doctor --connect` retain the state and
continue to the same phase-8 validator. Default `doctor` reports the applicable
active check as skipped and never invokes it.

After atomically marking provider activity and passing any required provider
application gate, but before credential resolution, connectivity, or
acquisition, phase 8 invokes every required validator in a total order over the
selected occurrences: installed-alias UTF-8 byte order, then `workflow` before
`mission`, then zero-based index within that destination's manifest provider
list. Thus an alias selected once in each environment is validated twice with
its distinct normalized selection and sealed destination context. Each
validator runs in a monitored worker bounded by
`selection_validation_timeout_ms`. The callback receives only the normalized
selection and sealed post-selection context and has exactly two admitted
returns: `:ok` or `{:error, :selection_rejected}`. Rejection maps to
non-retryable `active_preflight/selection_rejected`; raise, exit, or any other
return maps to non-retryable
`active_preflight/selection_validation_failed`; timeout maps to non-retryable
`active_preflight/selection_validation_timeout` after terminating its owned
worker tree. All three use the provider's `selection` subject with the
failing occurrence locator, expose no callback reason, and stop before
credentials or later provider work. Because the callback is trusted same-VM
custom code and may already have caused an external effect, none of these
outcomes is retryable.

No function, module name, MFA, captured term, regex, or caller-owned schema
enters `SelectionRules` or the prepared run. Decoder and constructor tests
prove the IR is bounded and that normalizing it performs no message send,
process/application start, file read, credential access, or network call.

The shipped installation path may classify a bounded, reviewed local-preflight
callback as `audited_local`. The same callback is used by `doctor` and `run`;
it may check decoded model configuration, loaded adapter availability, and
launcher/executable presence, but cannot read credential sources, launch a
process, perform discovery/network I/O, or start a provider application. A
check that cannot meet those rules belongs inside phase 8. Custom embedding
callbacks default to `unverified`, are never invoked by `validate` or before
destination preflight, and flip the marker before invocation.

Phase 7 invokes an `audited_local` callback once for every selected occurrence,
in installed-alias UTF-8 byte order, then `workflow` before `mission`, then
zero-based manifest index. Each invocation receives that occurrence's
normalized selection and final post-selection context. `doctor` and `run` use
the same order and stop at the same first failure, whose `local` subject carries
the failing occurrence. Doctor reports one alias-level local pass only after
all selected occurrences for that alias pass; no partial occurrence set can
produce a pass.

Provider staging uses two contexts:

- the phase-5 selection context contains the safe display identity,
  application content digest, final bundle hashes, input-authority class,
  internal execution-scope ID, selection destination (`workflow` or
  `mission`), and manifest-narrowed effective limits, but no effective
  application digest; and
- after every selection has been normalized, the engine derives the aggregate
  selected-provider data class, effective flow class, and effective event
  policy, then computes the effective application digest. The post-selection
  execution context adds that digest and those derived classes.

Destination and effective limits are required during preparation to validate
placement and narrow provider timeout/request/result ceilings. Neither context
contains an application directory, file reader, descriptor, source callback,
credential, or input value. Audited-local checks, active preflight, and
acquisition receive only the final post-selection context explicitly rather
than closing over an incomplete context. No provider callback runs while the
digest is unavailable, so the digest never depends on data produced by a
callback that itself received that digest.

### Fix bundle identity independently

`FrozenBundle.hash` currently covers ordered component IDs and source hashes but
not dependency edges. Rewiring the graph can therefore preserve the hash while
changing behavior.

Fix this before or alongside the CLI work. Hash the domain-separated canonical
V2 records defined below, including each component ID, source hash, and sorted
unique direct dependency IDs.
Add a regression in which IDs and source bytes remain identical while one
dependency edge changes; both the bundle hash and effective application digest
must change.

This is an existing correctness bug and does not depend on the standalone
frontend or transport-neutral package.

### Make application acquisition transport-neutral now

Introduce four internal values:

- `ApplicationPackage`: immutable application semantics and source closure;
- `ExecutionInput`: the selected normal/private input and its authority class;
- `ExecutionPolicy`: destination-free event identity, inspection-capture, and
  result-projection choices; and
- `RunRequest`: one sealed package/input/policy tuple consumed by
  `RunCoordinator.prepare/2`.

`ApplicationPackage` contains:

- the decoded manifest projection with the entire input declaration replaced
  by a fixed marker;
- local component bytes keyed by portable logical name;
- the shipped-library closure captured from the runtime's compiled library
  table;
- referenced input/result contract bytes; and
- the bounded safe component-override identities, each containing exactly
  `component_id`, `base_source_hash`, and candidate `source_hash`; and
- per-document/aggregate accounting plus content digests.

`ExecutionInput` contains the selected decoded value from an inline manifest
input, a manifest `{"path": ...}` input, or an explicit external override,
tagged `normal` or `private`. The explicit override replaces either manifest
form. The directory adapter resolves a manifest path under the same confinement
and bounds as other application references; the memory adapter resolves its
logical name from the supplied byte map. Construction removes the complete
manifest input declaration and selected input bytes from the package closure
after producing `ExecutionInput`. Input bytes, logical/path names, and input
digests therefore do not enter provider-visible application identity.

Provide two acquisition adapters over the same bounded constructors:

1. a confined-directory adapter for the CLI, Mix REPL, examples, and existing
   manifest-backed callers; and
2. an in-memory logical-name/bytes adapter for a trusted embedding or cloud
   frontend.

Both adapters accept raw bounded bytes, perform the same strict JSON and
semantic validation, resolve the same exact reference closure, reject unused
memory-map entries, and produce the same compiled bundle/application identity.
The memory adapter is not a serialized-package import and accepts no
caller-forged sealed structs.

Use portable lowercase ASCII logical names with `/` separators. A name is at
most `1_024` bytes, at most `16` segments, and matches exactly
`\A[a-z0-9][a-z0-9._-]{0,127}(?:/[a-z0-9][a-z0-9._-]{0,127}){0,15}\z`.
This rejects absolute, empty, `.`, `..`, Unicode, case-folding, and
normalization-dependent names. One package admits at most `512` captured
document records and `8_388_608` aggregate raw document bytes, including the
manifest, selected input before extraction, local/shipped component sources,
contracts, and override descriptor/source. Existing smaller per-role ceilings
still apply and may only narrow these aggregate caps. Both adapters count the
same records and bytes.

Accounting is incremental because references cannot be known before decoding
the manifest. First admit and decode the manifest under its own raw/depth/node
limits. Enumerate references and shipped-library dependencies through a
count-bounded work queue, rejecting the 513th unique record before resolving
it. Before reading or copying each referenced record, validate its logical name
and per-role ceiling, then read at most the lesser of that ceiling and the
remaining aggregate budget, plus one byte; that single extra byte detects
either overflow without allocating the declared size. Memory records apply the
same check to their already-supplied byte length. Charge the record exactly once before
parsing its schema or following its outgoing references. Closure expansion
therefore performs bounded name/edge bookkeeping, but no record that would
cross the byte/count cap is copied or recursively traversed.

All JSON-shaped boundaries use a depth limit of `64` and an aggregate node
limit of `100_000` per decoded document, enforced while normalizing duplicate
keys inside a bounded worker. The limits apply equally to manifests, host
configuration, input, contracts, override descriptors, provider configuration,
and result values; later validators must not recursively traverse a value that
did not pass this admission boundary.

Component overrides follow the same split: the directory adapter captures the
validated descriptor and candidate source; the memory adapter accepts bounded
descriptor/candidate bytes. One parser verifies exact keys, component identity,
base/candidate hashes, and source bounds. Override authority remains a separate
host argument to construction, but the verified candidate replaces the selected
source before the package, bundle hashes, and application digests are sealed.
Changing an override therefore changes the same identities as changing that
effective component source. The parser also seals the safe override identity
(`component_id`, `base_source_hash`, and candidate `source_hash`) into
`ApplicationPackage`; preparation carries it unchanged into bounded
`run-started` metadata so trace discovery can distinguish a candidate trial
from an ordinary run with the same effective source. Neither adapter retains
the descriptor path or candidate bytes in that metadata.

The directory adapter resolves/captures every referenced byte once, and
compilation/execution never reopen those paths. This prevents later phases from
observing a different file than acquisition captured, but it is not a
transactional multi-file snapshot: the trusted application directory must be
quiescent while its closure is acquired. Atomic deployment can provide that by
publishing an immutable versioned directory; a cloud frontend can instead
construct one in-memory request from its own versioned object. Do not claim
that independent confined reads detect a component changing between the
manifest and component reads.

The seal is an in-VM construction invariant like `FrozenBundle`, not a hostile
same-VM security boundary. A trusted embedding can read process memory and
process-global attestation keys; cloud tenant isolation belongs outside this
BEAM instance unless a later service design establishes a stronger boundary.

### Keep input out of application identity

Compute two domain-separated digests:

- `application_content_digest` identifies the captured application closure,
  including logical names, bytes, contracts, shipped libraries, and dependency
  edges, with manifest input replaced by a fixed marker; and
- `effective_application_digest` identifies the behaviorally relevant
  projection used in provider context, excluding annotations such as `$schema`,
  labels, and run/trace IDs while retaining entries, component/provider
  selections, final workflow/mission bundle hashes (therefore effective local,
  shipped-library, and override source identity), normalized `mission.data`,
  effective limits, contracts, dependency edges, input-authority class,
  effective event privacy policy, inspection-capture selection, result
  projection, and a code-owned `ptc_semantic_revision`.

Define the bytes now so these do not become implementation-dependent hashes.
All unsigned lengths below are big-endian. `JCS(value)` means RFC 8785 JSON
Canonicalization Scheme UTF-8 bytes. Because PTC-Lisp distinguishes integer
and float runtime values, identity-bearing semantic JSON uses `TJCS(value)`:
JCS over this recursively type-tagged tree:

- null is `["null"]`, a boolean is `["boolean", value]`, and a string is
  `["string", value]`;
- an integer is `["integer", canonical-base-10-string]`;
- a finite float is `["float64", sixteen-lowercase-hex-IEEE-754-bits]`;
- an array is `["array", [typed elements...]]`; and
- an object is `["object", [[key, typed-value]...]]`, with entries sorted by
  UTF-8 key bytes.

Tagging every node prevents a caller-authored object from colliding with a
numeric tag. It preserves arbitrary-size JSON integers, distinguishes `1` from
`1.0`, preserves negative zero and all finite binary64 values, and gives
equivalent decimal/exponent spellings one identity only when they produce the
same runtime float. Both byte adapters must retain whether a number token
produces an integer or float before constructing the runtime value; trusted
in-memory values derive the tag from the Elixir type. Non-finite floats are not
JSON and are rejected at a JSON-shaped boundary.

The shared recursive pass also rejects duplicate keys, excessive depth/nodes,
or invalid Unicode. Use one reviewed JCS encoder and one reviewed typed-tree
projector for identity only; ordinary artifact formatting remains unchanged.
Golden tests cover arbitrary-size integers, the `2^53` neighborhood, decimal
and exponent equivalence, `1` versus `1.0`, negative zero, and float-bit
stability through both byte adapters and the in-memory constructor.

`application_content_digest` is SHA-256 over:

```text
"ptc.application-content.v1\0" ||
u32(record_count) ||
for each record sorted by (kind_byte, UTF-8 name bytes):
  kind_byte || u32(name_bytes) || name || u64(payload_bytes) || payload
```

The closed record kinds are: `0x01` projected manifest, `0x02` effective local
component source, `0x03` shipped-library source, `0x04` input contract,
`0x05` result contract, `0x06` component dependency list, and `0x07` verified
component-override identity. The manifest record name is empty and its payload
is TJCS of the decoded manifest with the entire input declaration replaced by
`{"$ptc_input":"excluded"}`. Source and contract payloads are their exact
captured UTF-8 bytes. A local or shipped source record is named
`workflow/<component-id>` or `mission/<component-id>`, and its dependency and
override records use the same environment-qualified name. Contract records use
the fixed names `input` and `result`. These are portable logical names, never
filesystem paths. A dependency payload is TJCS of the sorted unique direct
dependency IDs; the IDs remain environment-local because cross-environment
component dependencies are not allowed. An override payload is TJCS of exactly
`{"base_source_hash":"sha256:<hex>","component_id":"<id>",
"source_hash":"sha256:<hex>"}` from the verified safe identity. Duplicate
`(kind,name)` records are invalid rather than last-write-wins. Environment
qualification makes two independently valid workflow/mission components with
the same ID and different source or edges representable. Different verified
bases overridden to the same candidate intentionally have different content
digests while retaining the same effective digest when all effective behavior
is otherwise identical.

`FrozenBundle.hash` changes in slice 0 to bare lowercase SHA-256 hex over the
following exact bytes:

```text
"ptc.frozen-bundle.v2\0" ||
u32(component_count) ||
for each component sorted by UTF-8 component-ID bytes:
  0x01 ||
  u32(component_id_bytes) || component_id ||
  u64(payload_bytes) || payload
```

There is exactly one V2 record kind, `0x01` component. `payload` is JCS of
exactly `{"dependencies":[...],"source_hash":"..."}`, with sorted unique direct
dependency IDs and the existing bare lowercase-hex source hash. Component IDs
and dependencies are UTF-8 strings. No field is nullable or omitted. It no
longer uses Erlang external-term encoding.

`effective_application_digest` is SHA-256 over
`"ptc.effective-application.v1\0" || u64(n) || TJCS(projection)`, where
`n` is the byte length of `TJCS(projection)`. The projection is literally:

```json
{
  "bundle_hashes": {
    "mission": null,
    "workflow": "<bare lowercase SHA-256 hex>"
  },
  "components": {
    "mission": [],
    "workflow": [
      {
        "dependencies": [],
        "id": "main",
        "source_hash": "<bare lowercase SHA-256 hex>"
      }
    ]
  },
  "contracts": {
    "input": "<contract behavior hash or null>",
    "result": "<contract behavior hash or null>"
  },
  "effective_event_policy": "normal",
  "entry": "main/run",
  "input_authority_class": "normal",
  "inspection_capture_enabled": false,
  "limits": {
    "capability_argument_bytes": 1,
    "capability_result_bytes": 1,
    "entry_source_bytes": 1,
    "evaluation_heap_words": 1,
    "evaluation_history_bytes": 1,
    "evaluation_memory_bytes": 1,
    "evaluation_timeout_ms": 1,
    "event_payload_bytes": 1,
    "live_provider_tasks": 1,
    "mission_capability_calls": 1,
    "mission_capability_calls_per_name": 1,
    "normal_event_bytes": 1,
    "normal_event_count": 1,
    "protocol_errors": 1,
    "provider_cleanup_timeout_ms": 1,
    "provider_heap_words": 1,
    "run_duration_ms": 1,
    "selection_validation_timeout_ms": 1,
    "subordinate_evaluations": 1,
    "subordinate_source_bytes": 1,
    "terminal_result_bytes": 1,
    "workflow_capability_calls": 1,
    "workflow_capability_calls_per_name": 1,
    "workflow_heap_words": 1,
    "workflow_timeout_ms": 1
  },
  "mission_data": {},
  "providers": {
    "mission": [],
    "workflow": [
      {
        "accepts_data": ["normal"],
        "config": {},
        "data_class": "normal",
        "installation_revision": "<portable lowercase revision>",
        "name": "<installed safe alias>",
        "source": "llm"
      }
    ]
  },
  "ptc_semantic_revision": "<lowercase identifier>",
  "result_projection": "json"
}
```

The positive `1` values and empty arrays/objects above show types, not defaults.
Every displayed key is always present. `effective_event_policy` is exactly
`normal` or `private`. It is derived after selection from the manifest-requested
policy, input-authority class, and aggregate selected-provider data class; it
is not merely the manifest field. `input_authority_class` independently records
`normal` or `private`, so switching input authority changes the effective
digest even if manifest/provider policy already made the event policy private.
`inspection_capture_enabled` is a JSON boolean and records whether the sealed
execution policy constructs the private inspection owner; changing it changes
failure behavior and data flow, so it changes the effective digest even when
event privacy is otherwise unchanged. `result_projection` is exactly `native`
or `json`; it is explicit because it
changes which terminal values are accepted and how they are guarded. The two
contract values are lowercase-hex strings or JSON `null`.
The workflow bundle hash is always lowercase hex. The mission bundle hash is
JSON `null` exactly when the mission component closure is empty and otherwise
lowercase hex, matching the existing absent-empty-bundle contract. Component
arrays contain the final local and shipped closure, sorted by UTF-8
component-ID bytes; their dependency arrays are sorted unique direct IDs.
Provider arrays retain manifest order. Every entry contains the installed safe
alias, closed descriptor source, required installation revision, declared data
class, accepted data classes, and phase-5 normalized selection config—not the
original spelling or raw installation configuration. `accepts_data` is sorted
in the closed data-class order, and every set-like array inside a normalized
config is sorted by that normalizer. The source is one of the shipped source
identifiers above or `custom` for a directly registered generic descriptor.
The revision attests to installed behavior not otherwise represented by the
safe projection, so changing selected adapter, model, endpoint behavior,
launcher, MCP mapping/effects, replay fixtures, snapshot policy, or other
installed authority requires a new revision and therefore changes the
effective digest.

A non-null contract behavior hash is SHA-256 over
`"ptc.contract-behavior.v1\0" || u64(n) || TJCS(schema)`. The existing contract
compiler first validates and normalizes the schema, thereby removing
`$schema`, `default`, and `x-*` annotations according to its retained
contract. The identity projection then performs a schema-aware traversal and
removes the `title` and `description` keyword only from maps visited as schema
objects. It traverses schema children through the accepted profile's schema
positions (`properties` values, `items`, and every branch of the accepted
root-only tagged-union `oneOf`) while preserving property-name keys literally
named `title` or `description`; it is not a generic recursive map-key filter.
`schema` is exactly that remaining normalized data; no decoded
pre-normalization annotations or compiler structs enter the hash. Here `n` is
the TJCS byte length. The identity admission pass checks this normalized
projection before typed projection. `mission_data` is the admitted decoded JSON
value. Numeric spellings have one identity only when they produce the same
integer/float runtime type and value, while a raw source/contract byte or
annotation change still changes the content digest but an annotation-only
change leaves the behavior hash and effective digest unchanged.

`ptc_semantic_revision` is the code-owned identifier
`sem1-<64 lowercase SHA-256 hex>`, computed once at application boot from an
exact generated semantic-build projection plus the actual BEAM runtime
projection. The generated part hashes one domain-separated, length-framed,
path-sorted closure of the evaluator, parser/compiler, built-in
registry/implementations, Java surface, runtime environment/dispatch, bundle
compiler, and other repository code that can change execution semantics
without changing captured application or shipped-library bytes. It also
contains the exact name, version, and lock checksum/content identity of every
runtime dependency shipped or accepted by the build, conservatively including
an optional dependency when compiled into the artifact.

The runtime part contains exact Elixir version, OTP release, ERTS version, and
BEAM system architecture. The final identifier is SHA-256 over a
domain-separated, length-framed TJCS projection of both parts. Thus the same
source release running on a behaviorally different BEAM/dependency set cannot
retain the same effective digest. A checked-in inventory owns the exact
included roots/files, runtime-dependency projection, and explicit non-semantic
exclusions. The inventory checker fails when a file or runtime dependency is
added under a designated semantic boundary without classification, and the
generated build-projection check fails when any included source/dependency
identity changes without regeneration.

This conservative identity may change for a refactor, comment, dependency
update, OTP patch, or target architecture even when observed behavior does not;
that is preferable to silently retaining identity across a behavior change. It
is not the package version. Documentation, tests, CLI adapters, and operational
packaging outside the designated semantic closure do not perturb application
identity. The inventory, generator, runtime projection, exact framing, and
current revision move into a retained maintainer contract when implemented.

Neither digest includes inline input, manifest-path input, external input
bytes, its declaration form, logical/path name, or its digest. The
input-authority class still participates in effective flow classification and
is also recorded explicitly in effective identity, so changing it always
changes the effective digest even when `effective_event_policy` was already
private. The content digest remains unchanged. Provider content remains
execution-scoped; this plan adds no cross-run provider/discovery/snapshot cache.

### Keep filesystem publication as an adapter

The execution core returns a classified result and terminal events without
requiring a path. CLI adapters may publish result, inspection, and trace files;
a cloud host may persist them inside its own authorized boundary.

Do not generalize the artifact system into an object-store interface now.
Retention, streaming, encryption, consistency, tenancy, and retry semantics are
unknown. Add a host-owned artifact-store boundary later when a concrete cloud
service needs it.

## Commands

Deliver:

1. `ptc --help`, `ptc help [COMMAND]`, and `ptc COMMAND --help`
2. `ptc validate ptc.json [--host-config HOST.json]`
3. `ptc run ptc.json [--host-config HOST.json] [--input INPUT.json |
   --private-input INPUT.json] [--trace-dir DIR] [--output PATH |
   --private-output PATH] [--inspect PATH]
   [--component-override-descriptor PATH]`
4. `ptc doctor [ptc.json] [--host-config HOST.json] [--connect]`
5. `ptc models --host-config HOST.json`
6. `ptc init DIRECTORY`

All three help forms normalize to `command: "help"` and return the closed help
result inside the ordinary one-envelope stdout contract. Root help lists the
five operational commands in the order above. Command help uses the
corresponding operational command as its topic; unsupported topics or
additional arguments are `arguments/invalid_arguments`. Help completes in
phase 1 and performs no host, application, destination, credential, provider,
or filesystem work. V1 does not define a version command or `--version`;
invoking it is `arguments/invalid_command`.

Because this is a 0.x library, rename `--mission`/`--private-mission` to
`--input`/`--private-input`, replace `--trace PATH` with generated
`--trace-dir DIR`, and remove `run --check` rather than adding compatibility
aliases.

Default `doctor` validates local runtime, host document, credential
declarations/references, optional application, optional Viewer presence, and
the same audited-local model/adapter/launcher checks phase 7 uses during a run.
It does not look up environment/file credential sources or use a decoded inline
literal after validating the host document. Because the current format stores
literal credentials inline, bounded host-document decoding necessarily reads
their bytes. Checks that require provider application startup, an unverified
callback, a process, discovery, or network access are reported as skipped by
default. `doctor --connect` enters the active boundary and flips
`provider_activity` before any such check or credential resolution.
`--connect` requires the application argument: connectivity and MCP discovery
must use the exact selected providers, placement, narrowed ceilings, and
write-capable MCP `allow` lists. It does not invent a separate
installation-wide discovery path.

The default-doctor applicability matrix is exact:

| Inputs | Application check | Provider checks |
| --- | --- | --- |
| neither host nor application | `skipped/not_requested` | none |
| application only | `pass/valid`; the application must select no providers or fail with `provider_declaration/provider_unknown` | none |
| host only | `skipped/not_requested` | every installed alias; local is `skipped/application_required`, selection is omitted, and declared credential/connectivity checks are `skipped/requires_connect` |
| host and application | `pass/valid` | selected aliases only, using their final occurrence contexts; unselected installations are declaration-validated but omitted |

All four rows still emit `runtime` and `viewer`. Host decoding and declaration
validation happen before any success envelope, so an invalid installed
descriptor is a top-level diagnostic even when its alias would be omitted from
the success checks. For host-only doctor, no audited-local callback is invoked:
without selection destination, effective limits, or application identity there
is no legal final context to give it. `doctor --connect` is rejected as
`arguments/invalid_arguments` unless both host and application are present,
and that rejection occurs before provider activity.

Phase-7 audited-local and active doctor work are occurrence-based even though
their success projections are alias-based. The occurrence key is the same total
key used by active selection validation: alias UTF-8 bytes, `workflow` before
`mission`, then manifest index.
For `probe`, `doctor --connect` invokes every selected occurrence in that order
with its own normalized selection and destination context. For `acquisition`,
it respects the sealed provider dependency graph; every ready layer is ordered
by that same occurrence key. An alias is reported `pass/available` only after
all of its applicable occurrences pass and their resources close successfully.
The public result then collapses them to the single documented per-alias check.
The first failing occurrence in the applicable total/dependency order produces
the top-level provider diagnostic with that destination/index locator, and no
alias-level pass is emitted from a partial occurrence set. Default doctor
reports declarative selection as `pass/declarative`; it reports active
selection as `skipped/active_check_required`. `doctor --connect` reports the
selection check as `pass/declarative` or, after every active occurrence passes,
`pass/available`.

Every occurrence-level connectivity operation, including acquisition-backed
MCP discovery, runs in a monitored worker under one
`doctor_connectivity_timeout_ms` monotonic deadline. For `acquisition`, the
deadline covers dependency dispatch, process/session startup, discovery,
bounded response consumption, and provisional-resource registration. On
expiry the dispatcher terminates the owned worker tree, then rolls back every
registered provisional resource under the separate cleanup deadline, and reports
retryable `active_preflight/connectivity_unavailable` with that occurrence's
`connectivity` subject. An `acquisition` connectivity descriptor promises that
this doctor operation performs observation/discovery only and has no
application-domain effect; shipped MCP satisfies that rule, and a custom
implementation is a trusted obligation. Cleanup failure can still replace the
timeout as primary under the documented precedence while retaining the timeout
in `secondary_errors`.

Every selected shipped live-LLM descriptor supplies a code-owned bounded
`connectivity_probe` operation in addition to acquisition. After the activity
marker, provider-application gate, active selection validation, and explicit
credential resolution, `doctor --connect` invokes that operation with only the
normalized selection, resolved credential value, and the installed
`doctor_connectivity_timeout_ms`. One monotonic deadline covers application
dispatch, connection, request, bounded response consumption, and worker
termination; the dispatcher kills the monitored worker tree at expiry.

The probe must perform exactly one remote request against the selected
endpoint/model. It disables adapter/SDK/HTTP retries (`max_retries: 0` or the
equivalent), automatic redirects, and any retry wrapper before dispatch. A
transient response is classified directly rather than hidden by another
attempt. Use a bounded authenticated metadata/model-list request where the
provider supports one and declare `probe_effect: metadata`; otherwise use an
explicitly documented minimal completion capped to one output token and declare
`probe_effect: completion`. The latter may incur one provider request/cost,
which the command help and retained guide must state.

The shipped HTTP path uses one code-owned passive HTTP/1 client for its single
attempt; it does not use a Req/Finch/Mint executor or pool. Its backend must
implement `recv_up_to(max_bytes, deadline)`: return promptly after at least one
byte is available, never return more than the positive maximum, and preserve
the single monotonic deadline. Plain TCP uses OTP `:socket.recv/4` in
nowait/select mode. The packaged TLS backend must prove the same semantics plus
peer/hostname verification, SNI, the packaged in-memory CA trust source, and
ALPN restricted to `http/1.1`. If OTP `:ssl` cannot prove the bound, use a small
code-owned length-framed port helper whose frames are capped before entering
BEAM; its stderr, lifecycle, and cleanup follow the provider-resource contract.
Host-owned/cloud embedding may inject an equivalent in-memory backend. If no
packaged backend passes the conformance spike, the shipped route is unsupported;
do not fall back to `recv(..., 0)`, exact positive-length reads, or an unbounded
library executor.

Before connect or send, the code-owned serializer admits only its closed
`GET`/`POST` methods and applies distinct byte grammars to the other request
parts. The generated origin-form target must start with `/`, is serialized from
validated URI path segments with required percent-encoding, and admits no raw
space, CR/LF, NUL, other control, or fragment delimiter. Endpoint parsing splits
the raw path only on literal `/`, validates and decodes each percent triplet
within its segment exactly once, rejects a decoded `/`, `\`, NUL, or control,
and retains empty segments. The serializer appends only fixed code-owned
operation segments and encodes each resulting segment once, so an existing
escape such as `%20` is not emitted as `%2520`. Header names use the bounded
HTTP token grammar. Generated header values may contain visible ASCII and the
spaces required by schemes such as
`Authorization: Bearer <credential>` but admit no CR/LF, NUL, other control,
obs-fold, or non-ASCII byte; credentials that cannot be represented by that
grammar are rejected rather than rewritten. All three parts have individual
byte caps, and aggregate request-header count/byte caps apply. A
credential-bearing endpoint must use `https`; plain
`http` is loopback-only and credential-free. The request asks the server to
close the connection after one response. It requests
`Accept-Encoding: identity`, disables automatic response decompression, and
rejects any non-identity `Content-Encoding` as
`connectivity_protocol_error` before decoding. It also rejects every compressed
HTTP transfer coding; only absent transfer coding or ordinary `chunked` framing
is admitted. The transport must expose and validate those headers before
applying a content or transfer decompressor.

The strict incremental parser consumes only `recv_up_to` chunks. Status, header,
informational-response, chunk-size, and trailer lines each have a line-size
ceiling; separate aggregate head/trailer byte,
field-count, and informational-response-count ceilings reject an unterminated
line or repeated `1xx` sequence before unbounded accumulation. After validating
the final headers, admit only a valid `Content-Length` or ordinary chunked body;
close-delimited bodies fail closed. For either framing, request at most the
lesser of the unread framed payload, fixed quantum, and remaining payload budget
plus one. The backend may return less and the parser carries bounded partial
framing state, so a large announced chunk delivered through many small SSE
writes produces prompt deltas. Count identity payload pieces before retaining
or decoding them and close on overflow. Thus at most cap-plus-one decoded
payload bytes enter code, and a small content- or transfer-compressed body can
never expand inside the command. The probe retains no response body, emits no
selector or credential metadata, and returns only one closed normalized
outcome. Map HTTP/protocol outcomes as follows:

- `401`/`403` or the provider's equivalent authenticated rejection becomes
  `active_preflight/authentication_rejected` (non-retryable);
- a transient `429`/rate-limit response becomes
  `active_preflight/connectivity_rate_limited` (retryable), while a
  provider-declared hard quota exhaustion becomes
  `active_preflight/connectivity_rejected` (non-retryable);
- another request-semantic `4xx`, including a missing/invalid model or
  unsupported request, becomes `active_preflight/connectivity_rejected`
  (non-retryable);
- for a metadata probe, a timeout, transport error, unavailable endpoint, or
  `5xx` becomes `active_preflight/connectivity_unavailable` (retryable);
- for a completion probe, the same ambiguous outcomes become
  `active_preflight/connectivity_outcome_unknown` (non-retryable), because the
  provider may already have accepted or billed the request; and
- a syntactically successful response that is malformed, violates the probe
  protocol, or exceeds the response cap becomes
  `active_preflight/connectivity_protocol_error` (non-retryable).

The code-owned adapter may inspect a bounded response only far enough to
distinguish hard quota exhaustion from transient rate limiting, then discards
it. Unknown statuses fail closed as `connectivity_protocol_error`; no raw
status text or body enters diagnostics. Custom probes must declare the same
effect class, obey the single-attempt/deadline/response-cap contract, and return
this same closed outcome vocabulary; arbitrary custom same-VM code remains a
trusted obligation, while the dispatcher invokes the callback only once and
bounds its worker. The dispatcher, not callback-supplied retry metadata,
applies the effect-sensitive mapping, so an ambiguous completion attempt can
never be advertised as safe to retry.

Plain live-LLM acquisition is not a connectivity check: constructing a
capability/snapshot without remote I/O cannot produce an `available`
connectivity result. The extra probe is invoked only by `doctor --connect`;
ordinary `run` never invokes it and incurs no extra request, including when the
workflow never calls the selected LLM. MCP acquisition/discovery remains its
real connectivity operation, matching its descriptor's `acquisition` mode.
Descriptors with `none` omit the check without entering the activity boundary
for connectivity. A custom live provider declares `probe` and must supply the
same bounded active probe; if its registered implementation is missing that
operation, `doctor --connect` fails closed after the marker as the
non-retryable
`active_preflight/connectivity_unsupported`, with the provider's
`connectivity` subject, rather than reporting a false pass.

`doctor --connect` creates the same owner-backed `ProviderResources` handle and
pending acquisition leases used by `run`. Every successful, failed, or raised
check closes or rolls back its registered sessions, ports, and process roots
under the installed global cleanup deadline before the command returns. A
single-provider close failure reports
`result_cleanup/provider_cleanup_failed` (or
`provider_cleanup_timeout`) with that provider's `cleanup` subject; failures
spanning providers use `subject: null`. No `available` check is emitted until
its acquisition lease is committed, and cleanup failure replaces doctor
success. Host-owned OTP applications are not part of this per-command cleanup.

`models` lists safe installed aliases and metadata without resolving
credentials, starting providers, or emitting/fingerprinting raw model
selectors. The transport-neutral command core accepts one already validated
`InstallationCatalog`; the standalone adapter constructs it only from
`--host-config`, while a trusted embedding may inject registered custom
descriptors/builders and call the same command core without a filesystem.
Programmatic construction validates the same alias, revision, data-policy,
destination, descriptor, and implementation-presence rules before rendering.
Its result uses `source: "custom"` for those registrations. Host JSON cannot
spell `custom`, and the standalone argv contract still requires
`--host-config`. The same safe alias/revision public projection applies to
`doctor`, run envelopes, public provider snapshots, and normal trace events.

With `--trace-dir`, the standalone CLI rejects a manifest that explicitly sets
`events.run_id` or `events.trace_id` during phase 3 as non-retryable
`application/event_identity_conflict`, with application source `ptc.json`,
path `/events`, null span/subject, exit `3`, and `provider_activity: false`.
The run is still unclassified, its requested trace state is `not_written`,
every other requested artifact is `not_written`, every unrequested artifact is
`not_requested`, and execution is `not_started`. It generates one
entropy-bearing `run_ref` value for both execution identities and uses it in
the exclusive trace filename. The caller can therefore locate the artifact as
`<trace-dir>/<run_ref>.jsonl` or the private-suffixed form from the envelope
alone. This prevents repeated fixed-ID runs from producing individually valid
files that make combined directory discovery malformed.
Explicit manifest identities remain available when `--trace-dir` is absent and
to trusted embedding callers.

A normal run publishes `<run_ref>.jsonl`. A private run publishes
`<run_ref>.private.jsonl` with mode `0600`. The exclusive publisher must accept
and preserve the reserved private suffix rather than routing private evidence
through the normal publisher. Directory discovery keeps normal and private
trace classification intact and never exposes a private trace through the
normal trace inventory.

Phase 6 rejects a private run without `--private-output` before provider
activity. V1 has no implicit private-value discard mode: a successful private
value must have an authorized owner-only result sink even though stdout
contains only public usage and `artifact_state`. A normal run may also select
`--private-output`; that protects the file destination but does not reclassify
the flow, suppress the normal value from its success envelope, or imply that
the value is confidential.

Whenever `--private-output` is present, phase 6 also creates one exclusive
mode-`0600` recovery file in the requested private-output directory with the
fixed basename
`.ptc-private-result-<run_ref>.json`. This is the sole mandatory
spend-before-run reservation. It contains no value during execution. On a
caught failure before a valid result for that destination, or on cleanup
failure, cleanup
removes it only after verifying that it is the invocation-owned file. After a
valid result for that destination and successful provider cleanup, the bounded
result bytes are written and synced to the recovery file, then its containing
directory is synced, before any optional trace or inspection publication;
`artifact_state.result` then becomes `recovery_written`. Failure of that
directory sync stops publication, leaves the invocation-owned recovery name for
inspection, and reports result state `failed`, never `recovery_written`,
because its directory entry was not proven durable. A later trace/inspection
failure after both syncs leaves the complete owner-only recovery file in place,
so the no-discard rule does not depend on ancillary evidence publication.

If ancillary publication succeeds, phase 12 attempts an exclusive hard link
from the recovery file to the requested final result name. It then syncs the
directory, unlinks the recovery name, and syncs the directory again before
reporting `written`. If the final name collides, the complete recovery file
remains, result publication reports an error, and the state remains
`recovery_written`; the caller derives its safe basename from `run_ref` and the
already-authorized output directory.

If the first directory sync fails after linking, the publisher attempts to
unlink the final name and sync the directory, returning to
`recovery_written` only when that rollback is verified. If unlinking the
recovery name or the final directory sync fails, or rollback cannot verify a
recovery-only state, it reports result publication failure with
`finalization_uncertain`: the already-synced recovery inode remains complete,
but the recovery name only, final name only, or both names may be visible
depending on the failed step and filesystem durability. The failure message
tells the caller to inspect both derived basenames, accept either single name,
and compare their exact bytes if both exist before removing either. A caught
recovery-file write or file-sync failure before the containing-directory sync
removes the invocation-owned partial file, reports result publication failed,
and never claims `recovery_written` or `finalization_uncertain`. This removal
rule explicitly does not apply when only the containing-directory sync fails;
that case leaves the complete recovery name for inspection as specified above.
A VM abort may leave an empty or partial recovery file, which is likewise not
claimed as written and requires inspection before removal. Same-UID malicious
unlink/replacement is outside this plan's threat model.

For `--output`, phase 12 publishes requested trace evidence first, inspection
evidence second, and the result last. For `--private-output`, the recovery
materialization above precedes those optional publications, but the requested
final result link remains last. Each successful publication
immediately updates `artifact_state`; the first failure stops later optional
publication. The failure envelope therefore reports which path-free artifact
classes were already written, which failed, and which were withheld. Cleanup
failure may still publish its authorized trace/inspection evidence, but never
materializes or publishes the result.

`init` creates a fixed minimal scaffold only when the destination does not
exist. It first renders and validates every bounded scaffold byte in memory,
then creates the destination exclusively and writes each fixed child
exclusively. On a caught write failure it removes only children this invocation
successfully created and removes the directory only if it is empty. It never
merges with, overwrites, or removes a pre-existing or unrecognized path. A VM
abort can leave partial state, as it can leave no envelope; document manual
removal after inspection for that exceptional case.

The existing interactive and non-interactive Mix REPL modes remain supported.
Their existing JSONL stream stays a distinct protocol rather than being folded
into the single-document command envelope. A standalone REPL is not part of V1.

## Implementation slices

### 0. Fix bundle graph identity

- replace Erlang-term hashing with the canonical V2 bundle framing above and
  include canonical dependency edges in `FrozenBundle.hash`;
- update trace/application identity consumers; and
- add golden vectors plus the same-bytes/different-edge regression.

**Gate:** rewiring an edge changes the bundle hash without changing component
IDs or sources. The effective-application half of this regression lands with
the digest in slice 2.

### 1. Transport-neutral package and identity

- add `ApplicationPackage`, `ExecutionInput`, destination-free
  `ExecutionPolicy`, and sealed `RunRequest`;
- materialize inline, manifest-path, and override input through one
  `ExecutionInput` constructor;
- build directory and memory adapters over the same bounded byte decoders;
- enforce shared JSON depth/node admission in bounded workers;
- add the type-preserving TJCS projection for identity-bearing semantic JSON;
- add the exact TJCS/framed application-content and contract-behavior
  projections;
- add the checked-in semantic source/dependency inventory, runtime projection,
  and derived `ptc_semantic_revision`;
- remove application directories from provider contexts; and
- make filesystem-backed entrypoints thin acquisition adapters.

**Gate:** one fixture validates and compiles identically from directory and
memory; input form/value/name changes leave the content digest unchanged;
local source, shipped-library source, override source, contract bytes, or
dependency-edge changes alter content identity. Directory acquisition never
reopens a captured path and documents its trusted-quiescent multi-file
assumption. Safe component-override identity reaches identical terminal
run-started metadata through both adapters; same candidate/effective source
with a different verified base changes the content digest but not the effective
digest. Neither package nor selection context contains an application
directory.

### 2. Typed diagnostics, phase ordering, and publication

- define closed outcome, diagnostic, phase, code, source, and activity types;
- add the generated V1 schema, safe renderer, shared argv parser, and closed
  `CommandOutcome`; keep process exit solely in the standalone wrapper;
- preserve typed, schema-context-aware `ValueContract` violation segments at
  classification time and make the diagnostic projector only RFC 6901-escape
  that safe representation;
- spike and install the standalone descriptor-3 envelope wrapper plus bounded
  stdout group leader, make the shipped ReqLLM adapter use a structured
  non-warning model-resolution path, and add the focused pinned
  Logger/SASL/explicit-stderr/direct-file-descriptor secret audit described
  above;
- establish the `CommandEngine`/path-free `RunCoordinator` boundary above,
  including its owner-backed shared `open_session/1` acquisition operation;
  decompose `RunBuilder` behind it, and make activity monotonic;
- add sealed declarative `ProviderDescriptor` metadata, including the closed
  selection-validation mode, connectivity mode, probe-effect class, and their
  implementation-consistency checks, so phase 5 never invokes a builder or
  callback;
- replace reflected limit-name handling with the scoped `LimitCatalog`, generate
  both host/application schemas from it, and seal the three installed-only
  operational timeouts with their exact ranges and identity participation;
- normalize every provider selection, derive the aggregate data class,
  effective flow, and effective event policy, then compute the exact effective
  application projection/digest—including input authority, that policy,
  inspection-capture selection, result projection, `mission.data`, final
  bundles, effective limits, normalized selections, and
  `ptc_semantic_revision`—before constructing the post-selection provider
  context;
- split provider preflight into deterministic per-occurrence audited-local
  checks and an active boundary used by both `doctor` and `run`; add the
  selected live-LLM adapter's
  single-attempt, deadline- and response-bounded real connectivity probe as a
  `doctor --connect`-only operation after that shared boundary, checking every
  selected occurrence before collapsing success to the alias result;
- require a safe installation revision on all five shipped host provider
  variants and every custom descriptor, and build public snapshots and
  effective provider projections only from the safe declaration fields plus
  the separately hashed runtime-captured acquisition/content projection;
- regenerate `priv/schemas/ptc-host-config.schema.json` from the decoder and
  update the retained host-configuration guide in the same change;
- retain existing result/inspection/trace adapters;
- preflight already knowable destination failures in phase 6 using the fixed
  trace/inspection/result order and terminal state table;
- reserve the deterministic owner-only private-output recovery artifact in
  phase 6, fill it after valid-result/cleanup success but before optional
  evidence publication, and retain it on any later failure;
- make final publication exclusive, no-clobbering, and private-trace-aware;
- enforce the installed cleanup deadline with monitored closers and owned-tree
  termination through one owner-backed resource graph, including pending
  acquisition leases that roll back provisional roots;
- remove raw-close-returning `ProviderRegistry.build/4`, and migrate direct
  embedding/E2E acquisition, `RunConfig`/`Kernel.run`, builder rollback,
  Runner, and REPL cleanup to the graph-requiring replacement;
- preserve successful execution facts when later publication fails;
- withhold result/success artifacts on cleanup failure while retaining the
  terminal `provider_cleanup_failed` trace and authorized inspection evidence;
  and
- add a sidecar lease only if concurrency tests demonstrate spend-before-run
  races that justify it.

**Gate:** representative failures at every phase have asserted envelopes,
status/code/retryability, and activity. Failures through audited-local phase 7
prove zero credential-resolution/acquisition calls; phase 8 marks activity
before active work. `doctor` and `run` return identical results for their shared
local checks. `validate` and occupied-destination failures never invoke an
unverified builder. Late collisions never overwrite data; cleanup failure
publishes no result but can publish its terminal failure trace/inspection; each
partial publication state is reported; a private-output result remains
recoverable after any post-recovery trace, inspection, or final-link failure;
and private
trace-directory publication is exclusive, mode `0600`, correctly suffixed, and
correctly classified by discovery. Directory and memory runs produce the same
effective digest; input
form/value/name within one authority class leaves it unchanged, while an
input-authority-class change, local/shipped/override source, selected provider
source/revision/data policy or normalized selection, `mission.data`, limits,
contracts, dependency edges, effective event privacy, inspection-capture
selection, result projection, or semantic revision changes it. Changing an
unselected installed provider does not change it.

### 3. Focused commands and packaged V1

- implement JSON-envelope help, `validate`, and `run`, then `doctor`, `models`,
  and `init`;
- remove unconditional Mix `app.start` and make `Mix.Tasks.Ptc.Run` delegate
  to the shared parser/engine and mode-specific phase-8 application gate;
- keep manifest-backed REPL script/profile modes on the same directory package
  adapter and shared `prepare/2` plus `open_session/1` lifecycle, remove the
  REPL's unconditional `app.start`, and leave only its streaming
  parser/protocol distinct; manifest mode gains `--host-config`, rejects it in
  direct/profile modes, and provider-bearing manifests use that installation
  rather than an empty registry;
- require an attached interactive `--private-terminal` before a classified
  private manifest REPL evaluates anything, reject private `-e`/`--load`
  sessions, and remove the current private-result-to-stdout behavior;
- package the same engine through the smallest proven OTP release/escript
  entrypoint;
- ship a minimal boot profile with implicit dotenv disabled and optional
  provider applications started lazily inside the activity boundary in
  standalone/Mix CLI mode, while cloud embedding remains host-owned; and
- document stdout as the V1 machine stream, stderr framing as non-contractual,
  and stderr content on supported paths as secret-safe.

**Gate:** the first packaged V1 already satisfies the final schema, phase,
digest, privacy, and publication contracts from slices 1 and 2. Standalone
subprocess tests cover every command, malformed arguments, caught internal
failures, signal characterization outside V1, and ordinary
stdout envelope/schema validity. Focused
tests prove Mix/standalone parser and engine parity without claiming Mix
process-stream purity. Directory and memory fixtures run identically; a
memory-backed fixture whose application/file-artifact adapters raise on use
succeeds when no file-backed provider is installed; a packaged default
`doctor` neither starts provider applications nor consumes a sentinel `.env`;
and a clean environment runs the packaged command without a repository
checkout. Retained guides, examples, shell journeys, and generated schemas use
the released names and host contract; `mix ptc.gen_docs --check` passes.

## Required tests

At minimum:

- shared parser parity for every `run` default, option, and conflict;
- one valid and representative invalid invocation for every command;
- exact root and per-command help envelope fixtures, including the doctor
  provider-cost notice, plus `--version` rejection without host/provider/file
  activity;
- standalone exact envelope schema/key/status/phase/code/retryability
  assertions, without imposing process framing on the Mix adapter;
- standalone success and failure fixtures proving the closed `ok`/`error`
  status variants;
- exact execution-state branches proving pre-execution failures report only
  `{"state":"not_started"}`, caught failures after Kernel start report bounded
  nullable `usage` and `evaluation_memory` under `incomplete`, and completed
  workflow failure/timeout reports `finished`/`error` with full accounting;
- cleanup and publication failures preserving the completed Kernel outcome
  (`ok` when execution succeeded) and full usage/evaluation-memory facts rather
  than collapsing them into the later infrastructure error; a completed Kernel
  error also preserves its bounded phase/code/subject in
  `execution.diagnostic`;
- pairwise and multi-failure fixtures across execution, result validation,
  session opening, cleanup timeout/failure, internal catches (including a
  publisher raise), sink finalization, and each publication step, proving the
  total precedence table selects exactly one stable phase/code/subject while
  `secondary_errors`, execution, and artifact state retain every
  lower-precedence classified fact; fixtures include
  result-contract-then-cleanup failure, incomplete-internal-then-cleanup
  failure, acquisition-error-then-rollback/cleanup failure, and
  local-preflight-error-then-sink-finalization failure, with every displaced
  diagnostic present in precedence order;
- early `run` argument, missing-application, and invalid-JSON failures proving
  `artifact_class: "unclassified"` and that no artifact state is written or
  failed before classification;
- table-driven terminal `artifact_state` fixtures for every state and class in
  the transition table, including requested-but-withheld versus
  attempted-and-failed adapters; simultaneous invalid/occupied trace,
  inspection, and result destinations prove phase 6 selects exactly the first
  trace/inspection/result diagnostic independent of argv order, marks only
  that adapter failed, leaves other requested adapters not written, and creates
  no recovery reservation;
- recovery-reservation creation fault injection proving sole non-retryable
  `destination/recovery_reservation_failed` with result `failed`, plus
  invocation-owned empty-reservation removal failure while unwinding each
  representative provider/execution/cleanup error, proving the earlier error
  remains primary, non-retryable `publication/recovery_cleanup_failed` is
  retained in precedence order, result is `failed`, and the bounded message
  names only the derived recovery basename;
- constrained command-boundary-generated `run_ref` on success, parse failure,
  and
  private-run failure, proving the exact fixed-width big-endian Crockford
  alphabet, first-character restriction, all-zero/all-`0xff` golden vectors,
  and that arbitrary explicit manifest event IDs never enter the envelope;
- destination-free `ExecutionPolicy` tests proving CLI and memory callers fix
  event identities and optional inspection capture before the first event,
  native/JSON result projection is enforced inside the coordinator, and no
  destination value enters the sealed request;
- CLI/Mix `validate` and `run` fixtures proving both seal JSON projection by
  default with no projection option, derive the same effective digest, and
  differ from an otherwise identical trusted native-projection embedding;
- catalog-generation checks proving every phase/code pair has exactly one exit,
  retryability, and renderer row, plus exact schema fixtures for every command
  success variant;
- source-kind, RFC 6901 path, half-open UTF-8 byte-span, and doctor-check
  catalog fixtures proving every claimed closed enum and object shape;
- provider diagnostic fixtures, including each failing doctor operation,
  proving `error.subject` contains only the safe alias, closed operation, and
  nullable destination/index occurrence, while aggregate multi-provider
  cleanup and non-provider errors use `null`; fail distinct workflow and
  mission occurrences of one alias and assert that their locators differ;
- bounded event/inspection rejection and dead-owner/protocol fixtures proving
  each of the four sink failure codes, with execution state matching the actual
  point of failure;
- no rejected value, credential, endpoint, private path/input, arbitrary term,
  exception, or stack trace in captured stdout or stderr;
- diagnostic-path fixtures with secret-bearing unknown input keys, credential
  names, and undeclared result keys, proving only safe parent/fixed/projected
  paths enter public output; include nested arrays and tagged-union branches,
  declared property names containing `.`, `/`, `~`, brackets, and decimal text,
  plus a name declared elsewhere but not at the failing schema node, proving
  typed local traversal and exact RFC 6901 escaping;
- endpoint/userinfo/query-token selector fixtures proving that neither the
  selector nor a deterministic fingerprint enters `models`, `doctor`, run
  envelopes, public provider snapshots, or normal traces;
- same revision/selection with changed MCP discovery or trace/inspection
  capture bytes proving `acquisition_identity_hash`, `snapshot_hash`, and the
  retained `content_snapshot_hash` citation identity change without exposing a
  selector-derived fingerprint;
- phase-2 `host/installation_revision_missing` rejection for every shipped
  provider kind through standalone `models`, `doctor`, `validate`, and `run`,
  including an unselected installation, plus equivalent constructor rejection
  for a custom descriptor before the embedded command cores can run; embedded
  `models` must render a compliant custom catalog entry with `source: "custom"`;
  also prove same-alias public snapshot and effective identity change when the
  selected host installation declares a new revision or behavior;
- default `validate` and `doctor` with no provider activity;
- optional provider-application startup failure mapping to
  `active_preflight/provider_application_unavailable`, with activity true and
  no credential resolution or acquisition attempted afterward;
- sequential and concurrent long-lived-host runs proving `ProviderRuntime`
  never starts or stops a VM-global application per command; repeated and
  concurrent `:mix_cli` runs proving one serialized post-marker startup is
  reused and never stopped per command; plus standalone subprocess tests
  proving lazy application startup occurs only after the marker and VM exit
  leaves no provider runtime behind;
- shipped MCP/LLM selection-rule parity fixtures plus bounded generic-rule
  fixtures, proving phase 5 performs all declared normalization without
  invoking a callback or side effect;
- unverified custom builder callbacks never invoked by `validate` or an
  occupied-destination run;
- active custom selection validation proving `prepare/2` preserves only the
  sealed `active_required` state, `validate` returns non-active
  `provider_declaration/selection_unverifiable`, and `run` plus
  `doctor --connect` invoke the same phase-8 validator after marking activity;
  cover `:ok`, explicit rejection, raise, exit, malformed return, and timeout,
  proving the three closed non-retryable diagnostics, provider `selection`
  subject with the exact failing destination/index occurrence, worker-tree
  termination, absence of callback reasons, deterministic
  `(alias, destination, manifest index)` ordering, and no
  credential/connectivity/acquisition work after failure; include one alias
  selected with distinct workflow and mission configurations to prove both
  occurrences receive their own normalized selection and sealed context;
- `LimitCatalog`, host schema/decoder, manifest schema/decoder, and effective
  projector parity proving all catalog rows and scopes agree; symmetric
  `provider_cleanup_timeout_ms` and `selection_validation_timeout_ms` fixtures
  cover omission sealing the default effective value `5_000`, explicit host
  decoding at `99`, `100`, `30_000`, and `30_001`, manifest rejection, worker
  behavior at the bound, and effective-digest change when the installed value
  changes; `doctor_connectivity_timeout_ms` covers the same host boundaries and
  manifest rejection while proving its `10_000` default and changes do not
  alter effective application identity;
- exact default-doctor check-list fixtures for no inputs, application only,
  host only, and host plus application, proving host-only audited-local checks
  are `skipped/application_required`, selection checks are omitted without an
  application, unselected installed aliases are omitted only after declaration
  validation, and application-only manifests cannot select a provider;
- default doctor reporting `provider/<alias>/local` as
  `skipped/active_check_required` for an unverified custom check and
  `provider/<alias>/selection` as `skipped/active_check_required` for active
  selection validation, with `doctor --connect` marking activity, executing
  both applicable checks, and reporting the selection pass only after every
  occurrence succeeds; declarative selections report `pass/declarative`;
- `doctor --connect` activity before the first credential/connectivity attempt;
- selected live-LLM `doctor --connect` probes with a fake bounded adapter,
  proving valid credentials/endpoints pass, a bad key maps to non-retryable
  `authentication_rejected`, transient rate limiting maps to retryable
  `connectivity_rate_limited`, hard quota and representative other `4xx`
  responses map to non-retryable `connectivity_rejected`, and malformed and
  oversized successful responses map to non-retryable
  `connectivity_protocol_error`; exercise bad endpoint, timeout, transport, and
  representative `5xx` outcomes for both effect classes, proving metadata
  probes return retryable `connectivity_unavailable` while completion probes
  return non-retryable `connectivity_outcome_unknown`; response bodies are
  discarded, callback-supplied retry metadata is ignored, and mere capability
  construction never emits a connectivity pass;
- shipped probe tests through a counting local HTTP server, not only a fake
  callback, proving metadata and completion paths disable SDK/HTTP retries,
  redirects, and automatic decompression, request identity encoding, make
  exactly one request on timeout/transport/`429`/`5xx`, enforce one total
  `doctor_connectivity_timeout_ms` deadline, reject gzip/Brotli or any other
  non-identity `Content-Encoding` and compressed `Transfer-Encoding` before
  decompression, admit ordinary chunk framing, reject oversized declared
  `Content-Length` before retaining or decoding body data, and cancel a chunked
  response after reading at most cap-plus-one payload bytes; coalesced
  header/body, unterminated/oversized status or header lines, repeated
  informational responses, short keep-alive content-length, final short chunk,
  a large announced chunk delivered through many small SSE writes, and
  single-write compressed-expansion fixtures prove the bounded framing-aware
  behavior rather than relying on server chunk timing; TCP and packaged TLS
  backend conformance proves `recv_up_to` returns available partial data without
  exceeding its requested maximum or total deadline, while request
  serialization tests accept `/v1/chat/completions` and a canonical
  `Authorization: Bearer <credential>` field, percent-encode admitted path
  segments exactly once—including a base-path `%20` fixture that must not
  become `%2520`—and reject invalid percent triplets, decoded slash/backslash,
  raw spaces, CR/LF, NUL, other controls, or fragments in the target plus
  invalid header-name or header-value bytes in declared headers and resolved
  authorization before any bytes are sent;
- a custom `probe` alias selected with distinct workflow and mission
  configurations, proving both occurrences are checked in the documented
  order, failure of either prevents the collapsed alias pass, success requires
  both, and each callback receives its own normalized selection/destination
  context; a corresponding `acquisition` fixture proves deterministic
  dependency-layer ordering before alias collapse;
- normal runs, including one whose workflow never invokes its installed LLM,
  proving they do not call `connectivity_probe` or incur its extra request;
- `none`, `acquisition`, and `probe` descriptor fixtures proving non-live
  omission performs no connectivity work, MCP discovery supplies the
  acquisition-backed check, an extraneous probe registration/effect is
  rejected, and every probe requires exactly one valid effect class;
  plus a custom live `probe` descriptor whose registered implementation omits
  `connectivity_probe`, proving `doctor --connect` returns non-retryable
  `active_preflight/connectivity_unsupported` with
  `provider_activity: true`, the safe provider connectivity subject, no
  credential resolution/request, and no false availability claim;
- successful, failed, raised, and hung `doctor --connect` acquisition proving
  one `doctor_connectivity_timeout_ms` deadline terminates the occurrence
  worker tree, maps a hang to retryable
  `active_preflight/connectivity_unavailable`, and every
  committed/provisional resource is closed or rolled back under the separate
  cleanup deadline, with cleanup failure replacing doctor success and using
  the exact provider/aggregate subject rule;
- failed and raised `doctor --connect` checks followed by rollback/cleanup
  failure, proving cleanup precedence while the original bounded check
  diagnostic remains in `secondary_errors`;
- `doctor --connect` without either required host or application argument
  rejected before activity, plus a selected write-capable MCP fixture proving
  the manifest `allow` list is honored;
- shared audited-local model/adapter/launcher checks running in the exact
  occurrence order and returning the same result in `doctor` and `run`, with
  active checks skipped by default doctor; select one alias with distinct
  workflow and mission configurations and prove both local occurrences run,
  failure identifies the correct occurrence, and alias success is emitted only
  after both pass;
- provider preparation with destination and effective limits, followed by
  exact capability/data-class verification at acquisition;
- missing application file, schema error, missing component, malformed Lisp,
  invalid entry, occupied destination, missing credential, acquisition failure,
  execution failure, timeout, manifest-input-contract failure,
  override-input-contract failure, result-contract failure, cleanup failure,
  and publication collision;
- cleanup failure withholding result/success artifacts while publishing the
  terminal failure trace and authorized inspection evidence;
- private-output phase-6 reservation followed by a forced final-name collision,
  proving the complete mode-`0600`
  `.ptc-private-result-<run_ref>.json` recovery artifact remains, its basename
  is derivable from the envelope, and `artifact_state.result` is
  `recovery_written`;
- valid normal- and private-flow runs using `--private-output`, followed by
  forced trace and inspection publication failures, proving the recovery file
  was already fully written/synced and remains discoverable with
  `artifact_state.result: "recovery_written"`; the normal-flow case keeps
  `artifact_class: "normal"` and its normal success value semantics;
- recovery write/sync fault injection proving a partial invocation-owned file
  is removed on a caught file failure, plus containing-directory-sync fault
  injection proving the recovery name is left for inspection but reported as
  `failed`; neither case is ever reported as `recovery_written`;
- private-output finalization fault injection at hard-link, first directory sync,
  rollback unlink/sync, recovery unlink, and final directory sync, proving
  `written`, `recovery_written`, and `finalization_uncertain` match the names
  that can remain—including recovery-only, final-only, and both-name uncertain
  states—and never discard the complete synced inode;
- packaged subprocess acquisition followed by `SIGINT` and `SIGTERM`, boundedly
  observing whether the VM exits and whether a provider child remains, then
  forcibly terminating and reaping the test tree when needed; no assertion
  treats termination, status, envelope, or close callbacks as V1 behavior, and
  a deployment requirement for reliable response or demonstrated child leak
  opens the outer-supervisor plan rather than weakening normal owner cleanup;
- a never-returning closer proving the installed cleanup deadline, forced child
  termination, timeout classification, and result withholding;
- a multi-layer provider graph whose first reverse closer never returns,
  proving every later-layer closer is still attempted and every registered
  process/port root terminates within the global deadline;
- every former direct `ProviderRegistry.build/4` embedding and E2E path
  requiring a resource handle, with no public acquisition API able to return a
  raw closer or unregistered process/port root;
- acquisition callback crash immediately after a registrar-owned root starts,
  normalization/result mismatch after root creation, dependency-acquisition
  failure, and worker death all proving provisional roots are rolled back
  within the installed cleanup bound;
- constructor/API tests proving shipped acquisition and one compliant custom
  fixture cannot expose a framework-owned process/port root before registration
  or return capabilities from an uncommitted lease, plus documentation/tests
  that arbitrary same-VM custom code remains trusted and outside that guarantee;
- equivalent direct `Kernel.run` and REPL owner-death/hung-closer regressions,
  proving those paths use the same resource owner and deadline;
- manifest-backed REPL setup proving it uses the directory adapter plus
  `prepare/2`/`open_session/1`, does not execute the workflow while opening,
  removes unconditional `app.start`, marks activity before provider application
  startup or acquisition, starts the same event/optional inspection owners as
  one-shot execution, does not consume a sentinel `.env`, and transfers sink
  plus resource cleanup ownership to `ReplSessionOwner`;
- result values bounded before recursive contract/JSON encoding helpers;
- private input/results never emitted to stdout by the standalone command,
  detached/non-interactive Mix paths, or an unauthorized manifest REPL; the
  only Mix REPL exception is the explicitly authorized attached
  `--private-terminal`;
- private runs without `--private-output` rejected in phase 6 with no provider
  activity;
- directory/memory failures exposing the same document-role/logical-name
  provenance and no absolute, credential, input, override, or artifact path;
- directory/memory parity for closure, inline/manifest-path/override input,
  overrides, safe override provenance in terminal run-started metadata, limits,
  diagnostics, bundle hashes, and both application digests;
- manifest-backed interactive and non-interactive REPL modes constructing the
  same package identities through the directory adapter;
- input declaration form, value, and logical/path name changes within one
  authority class leaving both application digests unchanged; switching normal
  to private authority leaving the content digest unchanged but changing the
  explicit effective `input_authority_class`, including when the event policy
  was already private;
- local, shipped-library, and override source changes altering effective
  application identity;
- table-driven mutations proving entries, component/provider selections,
  selected provider source/revision/data policy, effective limits, contracts,
  dependency edges, normalized `mission.data`, final bundle hashes, effective
  event privacy, inspection-capture selection, result projection, and
  `ptc_semantic_revision` each change effective identity, while an unselected
  installed-provider change, `$schema`, labels, input bytes within one
  authority class, and run/trace IDs do not;
- semantic-source inventory/generation checks proving an included source-byte
  or runtime-dependency identity change alters `ptc_semantic_revision`, an
  unclassified file/dependency under a semantic boundary fails the inventory
  audit, and a documentation/CLI-adapter-only change does not alter it;
- runtime-revision vectors proving Elixir, OTP, ERTS, or BEAM architecture
  changes alter `ptc_semantic_revision` even when the generated source/build
  projection is unchanged;
- checked-in bundle/content/effective digest golden vectors covering map-key
  order, JSON whitespace, type-tagged `1` versus `1.0`, negative zero,
  arbitrary-size integers, binary64 stability and decimal/exponent equivalence
  around `2^53`, escaped Unicode, logical names, exact raw source/contract
  bytes, every record-kind byte, nullable contracts, the complete safe provider
  projection including revision/source/data policy, complete
  effective-projection keys, every content record kind including `0x07`
  override identity, same-candidate/different-base provenance, and dependency
  rewiring;
- a manifest with the same component ID in workflow and mission but different
  source/dependencies, proving environment-qualified content records and
  distinct environment bundle identities without a record collision;
- contract behavior vectors proving recursive `title`/`description`, `default`,
  `$schema`, and accepted `x-*` annotation-only changes leave the behavior and
  effective digests unchanged while changing the raw content digest, plus
  schemas with properties literally named `title` and `description` proving
  those property names and their child schemas remain identity-bearing, and a
  root tagged-union fixture proving annotations inside every `oneOf` branch are
  removed only at schema-object positions;
- normalized `mission.data` changes altering effective application identity;
- dependency rewiring changing bundle and application identity;
- repeated default-ID `--trace-dir` runs producing independently discoverable
  `<run_ref>.jsonl` files whose basenames are derivable from each envelope, and
  explicit manifest run/trace IDs rejected with that option using the exact
  phase-3 `application/event_identity_conflict` diagnostic, unclassified
  artifact class, `trace: not_written`, requested/unrequested companion states,
  `execution: {"state":"not_started"}`, and no provider activity;
- manifest REPL parity proving `--host-config` enables the same provider
  installation/acquisition lifecycle as `mix ptc.run`, is rejected in
  direct/profile modes, and a provider-bearing manifest without it fails
  before acquisition;
- manifest REPL projection fixtures proving it always seals `:native`, its
  effective digest differs from the otherwise identical JSON `mix ptc.run`,
  its Clojure output/history retain the existing bounded native/public
  semantics, and no user projection option is accepted;
- private manifest REPL interactive and non-interactive regressions proving
  values and prints never reach stdout without an attached explicitly
  authorized `--private-terminal`, do reach that sink in the authorized
  interactive case, and rejected or disconnected sessions close their prepared
  owners without provider leaks;
- a private trace published before a later result-publication failure, proving
  the error envelope retains `artifact_class: "private"` and therefore
  identifies `<run_ref>.private.jsonl` rather than the normal basename;
- private `--trace-dir` runs publishing exclusive mode-`0600`
  `<run_ref>.private.jsonl` files that private-aware discovery classifies without
  exposing them through the normal trace inventory;
- memory-backed execution with application and file-artifact adapters that
  raise if invoked;
- depth-65 and over-100,000-node documents/results rejected in bounded workers
  through both acquisition adapters without crashing the coordinator;
- exact boundary vectors for revision pattern/length, logical-name bytes and
  segments, 512/513 records, and aggregate raw bytes at
  8_388_608/8_388_609, proving directory and memory adapters reject the same
  request at the same incremental accounting step and never read/copy or
  traverse the record that crosses the cap;
- packaged default `doctor` with a sentinel `.env`, proving it is neither
  consumed nor followed by provider application startup;
- packaged live-LLM runs with an allowed uncatalogued sentinel selector and a
  fake dependency that attempts direct `IO.warn`, proving structured ReqLLM
  resolution invokes no warning fallback, arbitrary command-descended `stdio`
  is swallowed by the bounded group leader, arbitrary globally supervised and
  direct-file-descriptor stdout is discarded on descriptor 1, stdout remains
  one descriptor-3 envelope, and the selector appears in neither stdout nor
  stderr; the fake arbitrary-stderr path must fail the packaged support audit
  rather than being executed, while separate command-descended and globally
  supervised secret-bearing Logger/SASL fixtures prove the absent console
  handler suppresses their reports and a wrapper fixture proves only enumerated
  fixed stderr messages are emitted; tests also prove descriptor 3 survives
  the macOS/Linux release wrappers, is not inherited by launched providers or
  ports, handles a caller-side close without an unbounded failure, preserves
  the command exit status, and that Mix/host-owned modes never mutate VM-global
  IO registration; the focused audit rejects an unclassified secret-bearing
  stderr call site, dependency-version drift, optional Logger handler
  installation, and fake same-VM native code that can target descriptor 3;
  descriptor close/replacement fault injection proves the writer validates its
  startup identity and never emits to a substituted target;
- Mix parse, application, and occupied-destination failures with a sentinel
  `.env`, proving unconditional `app.start` is gone and neither `req_llm` nor
  `llm_db` starts before the marker;
- a successful provider-backed `:mix_cli` run with a sentinel `.env`, proving
  the serialized gate sets both dotenv flags false before startup and does not
  consume the file, plus rejection of an already-running ReqLLM with no
  manager-owned safe-start record even if both configuration flags were later
  flipped to false, and safe manager startup followed by an unsafe external
  restart proving the monitored instance-bound record is invalidated;
- `init` fault injection after each child write, proving caught failures remove
  only invocation-owned state and permit a clean retry;
- phase-12 fault injection after trace, inspection, and result publication,
  proving result-last ordering and exact path-free `artifact_state`;
- no-clobber result/inspection/trace/init publication under sequential and
  concurrent processes;
- a packaged-install smoke journey from `init` through `validate`, `run`, and
  trace loading; and
- generated host-schema verification plus retained-guide/example searches
  proving removed `--mission`, `--private-mission`, and `run --check`
  spellings survive only in explicit historical/migration text, and that
  `--trace PATH` is absent specifically from `ptc run`/`mix ptc.run`
  invocations while the supported `mix ptc.repl --trace PATH` remains.

## Non-goals and future triggers

This plan does not define:

- an HTTP service, job queue, authentication, tenant isolation, service
  cancellation, scheduling, or concurrency quotas;
- an adversarial same-user/same-VM security boundary;
- manifest-defined provider installations, URLs, filesystem roots,
  credentials, commands, or callbacks (manifests still select installed
  aliases);
- a remote/streaming application-source protocol;
- a general object store or active trace persistence service;
- a hard five-minute standalone run ceiling;
- blanket rejection of FUSE, 9p, virtiofs, bind mounts, or unknown filesystems;
- a native lock-pool/ACL/statfs subsystem; or
- backward-compatible CLI aliases.

Start the outer-supervisor plan if any supported release target fails the
descriptor-3 survival, noninheritance, broken-pipe, exit-status, focused
descriptor-authority inventory, or startup-identity checks required above; do
not substitute dependency-wide stdout auditing. It is also triggered when
reliable signal response or child-tree cleanup requires a process boundary.
Start a service-boundary plan when cloud deployment needs untrusted tenant
handling;
that plan must define authentication, isolation, credential ownership,
cancellation, artifact durability, and resource quotas where the untrusted
input actually enters.

## Feasibility and recommendation

The Elixir slices are implementable against the current architecture.
`RunBuilder`, `ProviderRegistry`, strict schemas, confined reads, result
classification, and artifact modules provide the necessary seams. The main
refactors are preserving typed error provenance, making phase order explicit,
and replacing path-coupled manifest state with a sealed document closure.

The transport-neutral package should be done now, not postponed until a cloud
service exists. It is small enough to define without choosing object storage,
IAM, or tenancy, and it prevents the CLI directory layout from becoming the
runtime API.

The generalized artifact store should wait. A cloud frontend can authenticate
and fetch documents, construct the bounded in-memory request, supply a trusted
host installation and credential resolver, execute without application or file
destinations, and persist the classified outcome inside its own boundary. The
BEAM code still comes from its release/container image, and any selected
file-backed credential or provider remains host responsibility. This supports
the stated application-filesystem-free direction without pretending this
library plan is a complete hosted-service security design.
