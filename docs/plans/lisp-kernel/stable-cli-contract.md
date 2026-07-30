# Stable CLI and transport-neutral application plan

**Status:** proposed; implementation-ready after merged-OAuth and
multitenancy-preparation review.

This plan turns the remaining command-line work in
[`product-readiness.md`](product-readiness.md) into small implementation slices.
It also removes application-file acquisition from the execution core so the
same runtime can later accept a cloud-supplied application without requiring
application or artifact paths.

The plan deliberately does not make hostile same-user process containment,
inbound tenant authentication, adversarial multi-tenant service isolation, or
transactional artifact storage prerequisites for fixing the current CLI. It
does preserve trusted host-supplied tenant/principal partition keys and
execution-scoped provider services so a later multi-tenant host does not need
to undo a process-global credential design. Those keys are namespacing inputs
to the OAuth store, not proof of identity or a security boundary by themselves.

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
- `PtcRunner.Kernel.MCPOAuth` supplies principal-scoped authorization contexts,
  an atomic store behaviour, an in-memory adapter, explicit authorization,
  refresh fencing, and deferred manager cleanup. `MCPHTTPAdapter` is the shipped
  bounded direct-Mint HTTP/1 boundary shared by MCP and OAuth.
- `Mix.Tasks.Ptc.Run` owns the run option/error-rendering layer. The existing
  REPL also has non-interactive script/profile modes and a distinct JSONL
  streaming protocol; its manifest-backed mode calls `RunBuilder`.

The important gaps are therefore orchestration and boundaries, not a new
evaluator:

- inspected Elixir errors are not a stable machine protocol;
- validation, destination checks, provider preparation, credentials, and
  acquisition are not ordered as an explicit public contract;
- OAuth registry construction currently requires `MCPOAuth.Context` and performs
  `claim_principal`/`claim_authorities` store writes before provider selection,
  so the existing seam cannot preserve zero provider activity for `validate`,
  `models`, or default `doctor`;
- manifest loading and execution assembly are still coupled through paths;
- bundle identity does not cover dependency edges; and
- focused `validate`, `models`, `doctor`, and `init` commands do not exist.

## Decisions

### Ship the Elixir contract before native containment

Add one shared argv parser, command dispatcher, diagnostic projector, and
`CommandEngine` in Elixir. Both the standalone entrypoint and
`Mix.Tasks.Ptc.Run` delegate to them. The Mix task prepends the fixed `run`
command and selects the `mix_cli` frontend mode in the same option table; that
mode admits the one documented Mix-only `--authorize-mcp` adapter while
standalone mode rejects it. There is no second option table. The engine owns only
frontend concerns: argv, path-backed acquisition adapters, destination
preflight/publication, and envelope rendering. It returns a closed
`CommandOutcome` containing the envelope and exit status. Only the standalone
wrapper writes the exact process streams and exits; the Mix adapter returns or
raises through Mix conventions and never halts the caller's VM.

Add a separate path-free `RunCoordinator` with `prepare/2`,
`open_session/2`, and `execute/2`. `prepare/2` consumes a sealed `RunRequest`
plus a pure trusted `InstallationCatalog`, compiles bundles, normalizes provider
selections, classifies the run, and returns a sealed prepared run. After a
frontend performs any destination preflight, `open_session/2` consumes
execution-scoped `ProviderRuntimeServices` and owns local/active provider work
and acquisition for both one-shot and REPL execution;
`execute/2` composes that operation with Kernel execution, result guarding,
cleanup, and terminal-event finalization. Both the CLI and a cloud embedding
use this coordinator; neither `RunCoordinator` nor `RunBuilder` accepts argv,
an application path, or an artifact destination.

`InstallationCatalog` is inert. It contains validated provider descriptors,
implementations, safe static OAuth authority metadata, installed limits, and
installation revisions, but no principal, store claim, live authorization
context, resolved credential, process, or port. Constructing it performs no
store call or other provider activity. In particular, replace the current
`HostInstallation.registry/1` OAuth refusal and `registry/2` eager
`claim_authorities` path rather than wrapping either behind the new type.

`ProviderRuntimeServices` is a sealed execution-scoped authority supplied only
to `open_session/2`. It contains the provider-application ownership mode,
bounded ordinary credential resolver, and an OAuth activation mode of exactly
`disabled` or `context_groups`. `disabled` carries no store, partition, resolver,
or interaction and is used by standalone V1. `context_groups` carries a private
alias-to-group map and lazy runtime specification for each declared group. The
CLI resolver owns environment/confined-file/literal
resolution from inert host declarations; a cloud resolver may use its
authenticated secret service without exposing a filesystem. Neither is invoked
before phase 8. An OAuth runtime specification
contains trusted host-supplied tenant/principal partition keys, a store handle,
an optional interaction implementation, and a just-in-time client-credential
resolver. Constructing the specification validates only bounded shapes and
does not call the store or resolver. After atomically marking provider activity
in phase 8, `open_session/2` constructs `MCPOAuth.Context`, claims the selected
authorities, and only then loads, refreshes, or explicitly authorizes a grant.
Every context, principal claim, authority claim, grant operation, and
authorization call carries one caller-owned absolute monotonic deadline; no
OAuth boundary retains the current independent 5,000 ms claim timeout.

Intentionally break the `Store` behavior's bare-timeout transaction boundary.
Every coordinator-facing store call supplies a sealed `%Store.Deadline{}` with
the absolute local monotonic deadline and its positive remaining duration at
submission. A same-VM adapter checks it before dispatch, and its serialized
handler rechecks the absolute value inside the atomic transaction immediately
before any mutation and commit. An expired queued in-VM request returns
`:timeout` without changing state.

A remote adapter cannot compare unrelated monotonic timestamps and must not
pretend the submitted remaining duration is still fresh on arrival. Before
dispatch it chooses one of two declared mutation modes. `authoritative_deadline`
negotiates an opaque adapter-issued transaction guard whose server-clock expiry,
including the adapter's proven clock/transport uncertainty margin, is no later
than the caller deadline; the server rechecks that guard atomically before
commit. `indeterminate_after_dispatch` applies when no such bound can be proven:
once a mutation request may have been dispatched, local expiry never asserts
that state is unchanged and returns the operation's existing
`mutation_indeterminate`/possibly-dispatched outcome. Reads may simply time out
and discard a late reply. An adapter that does neither is unsupported. A
mutation committed before a guarded deadline whose reply is lost, or committed
at an unknown time in indeterminate mode, retains its operation-specific
idempotency/dispatch-indeterminate classification; no caller-local clock is
projected as an adapter-authoritative fact.

Generate the Store command catalog with more than a `read`/`mutation` bit. Every
exported transaction command has exact `access`, `remote_replay`,
`post_dispatch_projection`, and `cleanup_action` fields. A read has
`remote_replay: not_applicable`, `post_dispatch_projection:
discard_late_reply`, and `cleanup_action: none`. A mutation's `remote_replay` is
either `stable_idempotency_key`—the command carries a bounded key and replay
returns the original committed result—or `authoritative_only`, which an
`indeterminate_after_dispatch` adapter rejects before dispatch. A mutation's
`post_dispatch_projection` is one closed phase/code/retryability mapper, not a
raw atom or callback, and its `cleanup_action` is exactly `none`,
`reconcile`, `preserve_authorization_fence`, `preserve_response_fence`, or
`retain_admission_cleanup`.

The store handle seals its declared remote mutation mode as inert capability
metadata. To avoid a second conditional-operation inventory, handle construction
checks the complete generated Store catalog: an `indeterminate_after_dispatch`
store is invalid if any exported mutation is `authoritative_only`, whether or
not one particular run is expected to reach it. An `authoritative_deadline`
store may implement those rows. The incompatible trusted runtime specification
is rejected as non-retryable `internal/internal_error` before the activity
marker, store call, resolver, interaction, manager, or network action; it never
degrades into retryable `authorization_unavailable`.

All production Store calls go through wrappers generated from that same
catalog. A compile/source audit rejects a coordinator, OAuth module, cleanup
owner, or adapter helper that constructs a transaction command or calls
`transact/3` directly outside the generated Store boundary. Thus conditional
run, doctor, explicit-authorization, execution-response, and cleanup calls
cannot escape the capability check.

Principal/authority claims and pre-external-dispatch flow/lease setup use stable
reconciliation and their declared availability mapping; they may be retryable
without claiming the first attempt did not commit. Refresh/code operations
after possible external dispatch preserve the authorization fence and use
non-retryable `authorization_required`. Dynamic response-transition mutations
preserve their response fence and use the phase-specific doctor,
session-opening, or execution rows below. MCP admission/release retains its
cleanup owner until the exact idempotent release is acknowledged and uses the
cleanup precedence table. Retirement operations either carry their existing
stable idempotency/intent identity and policy mapper or are
`authoritative_only`. No mutation may inherit a default classification.
Generation fails when an exported Store command lacks a catalog row, when a
mutation lacks an admitted replay mode and projector, or when its public pair is
absent from the diagnostic catalog.

Relative TTLs stored in flows, leases, requirements, and retirements remain
separate from the caller deadline. Unselected OAuth installations are never
claimed. A runtime-service callback is trusted host code and is never invoked
by `validate`, `models`, default `doctor`, or a run rejected through destination
preflight.

An OAuth context-group key is an opaque, private execution-local identifier,
not a tenant ID or public identity. In `context_groups` mode, construction
requires every installed OAuth alias to map to exactly one declared group and
rejects unused or missing mappings. One group owns exactly one tenant ID,
principal ID, store handle, interaction implementation, and client-credential
resolver. Aliases intentionally mapped to that group may share its principal
claim and context. Construction validates only these inert mappings and does
not invoke a store adapter.

Make `Store.local_identity/1` mandatory for every store admitted to
`context_groups` and remove its handle-tuple fallback. The adapter must return a
non-secret opaque binary of exactly `1..128` bytes; arbitrary byte values are
allowed, but the empty binary and values longer than 128 bytes are invalid. The
value must be stable and equal for every live handle to the same backing store
and distinct from another backing store; violating that contract is an invalid
store adapter. After the activity marker and cleanup-capacity reservation, the
coordinator invokes this otherwise pure callback for selected groups in
deterministic group-anchor order inside monitored workers under the shared
activation-admission deadline. It rejects a missing, malformed, raised, exited,
or duplicate
`{store_identity, tenant_id, principal_id}` namespace before constructing a
context or performing any store mutation, then releases the reserved batch.
Callers that intend to share that namespace must map the aliases to one group.
Thus different groups cannot produce identical `GrantKey` values without adding
a second namespace concept to the durable-store contract. This makes a future
authenticated multi-tenant host an explicit producer of separate groups rather
than relying on process-global context. The group key, partition keys, store
identity, and resolver identity remain private.

In `disabled` mode, selecting any OAuth occurrence is a supported active
failure, not an invalid runtime specification. After the activity marker flips,
the first selected OAuth occurrence in the ordinary total order returns
non-retryable `active_preflight/authorization_required` with its
`authorization` subject, without reserving cleanup capacity, constructing a
context, calling a store/resolver, starting a manager, or opening an
interaction. Static providers in the same run retain their ordinary behavior,
but acquisition stops at this first OAuth failure. Static commands never
inspect the activation mode because they stop before phase 8.

Tenant and principal IDs never come from a manifest, MCP response, process
dictionary, or application environment. They remain private, do not enter
application/provider identity or public diagnostics, and are scoped to one
OAuth store authority. This prepares the runtime for a future authenticated
multi-tenant host while making no claim that the CLI or one BEAM VM authenticates
or isolates mutually hostile tenants.

The first standalone package should use the smallest supported BEAM packaging
that can carry the project and its dependencies. An OTP release with a
`bin/ptc` wrapper is the baseline; an escript is acceptable only if a packaging
spike proves that the dependency and optional-provider surface works without a
parallel runtime configuration. Packaging choice must not change the command
engine or envelope schema.

The standalone boot profile starts only the command core, including the inert
`PtcRunner.Supervisor`, bounded `MCPOAuth.ManagerCleanup.Registry`, and empty
cleanup worker supervisor. Starting that core performs no store or provider
work and does not mark provider activity. Optional provider
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
parsing, package construction, and ownership transfer. That ensured core
includes `:ptc_runner`'s root supervisor,
`PtcRunner.Kernel.MCPOAuth.ManagerCleanup.Registry`, and its empty worker
supervisor; they must be available before phase 7 but start with no provider or
store state. Provider OTP applications, including
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
are VM/host-owned runtime infrastructure outside that graph. The OAuth cleanup
supervisor is likewise VM/host-owned infrastructure, but a token manager is
per-run until an explicit successful ownership transfer described below.

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
`authorization`, `connectivity`, `acquisition`, `execution`, or `cleanup`.
`occurrence` is JSON `null` or exactly
`{"destination":"workflow|mission","index":nonnegative_integer}`. The index is
the zero-based position in that destination's manifest provider list. It is
non-null only when the failure is attributed to one selected occurrence;
installation-declaration, provider-application, alias-wide runtime-service
activation, credential-resolution, and aggregate cleanup failures use `null`.
An authorization, connectivity, or acquisition failure uses the selected
occurrence when the failed operation had entered that occurrence. Audited-local
failures use the selected occurrence they were checking.
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
| `active_preflight` | `provider_application_unavailable`, `selection_rejected`, `selection_validation_failed`, `selection_validation_timeout`, `credential_unavailable`, `authorization_required`, `authorization_rejected`, `authentication_rejected`, `connectivity_rejected`, `connectivity_protocol_error`, `connectivity_unsupported`, `connectivity_outcome_unknown` | `4` | false |
| `active_preflight` | `authorization_unavailable`, `connectivity_unavailable`, `connectivity_rate_limited` | `4` | true |
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
`provider/<alias>/selection`, `provider/<alias>/credentials`,
`provider/<alias>/authorization`, or `provider/<alias>/connectivity`; aliases
already exclude `/`. Within one alias, the fixed order is local, selection,
credentials, authorization, connectivity. Omit selection when there is no
application occurrence for that alias. Omit a credential check when the
descriptor declares no ordinary static credential names. Include authorization
exactly when `authorization_mode` is `oauth`; static MCP authentication and all
other shipped providers omit it. Omit a connectivity check exactly when its
connectivity mode is `none`; `acquisition` and `probe` both include it. The only
success-result pairs are:

| Check name | Allowed `status` / `code` |
| --- | --- |
| `runtime` | `pass` / `supported`; `warn` / `unsupported` |
| `application` | `pass` / `valid`; `skipped` / `not_requested` |
| `viewer` | `pass` / `available`; `warn` / `optional_unavailable` |
| `provider/<alias>/local` | `pass` / `available`; `skipped` / `application_required`; `skipped` / `active_check_required` |
| `provider/<alias>/selection` | `pass` / `declarative`; `pass` / `available`; `skipped` / `active_check_required` |
| `provider/<alias>/credentials` | `pass` / `available`; `skipped` / `requires_connect` |
| `provider/<alias>/authorization` | `pass` / `available`; `skipped` / `requires_connect` |
| `provider/<alias>/connectivity` | `pass` / `available`; `skipped` / `requires_connect` |

A required local, selection, credential, authorization, or connectivity failure
produces the matching top-level diagnostic instead of inventing a warning
check code. `authorization_required` means the selected OAuth authority has no
usable grant and needs a new explicit host/Mix interaction, including when a
previous explicit interaction expired safely; it is not
`authentication_rejected`, and an automatic command retry cannot repair it.
`authorization_rejected` covers an explicit denied/invalid authorization
outcome. `authorization_unavailable` is reserved for a bounded store or
runtime-service availability failure before provider request dispatch and is
retryable. Just-in-time confidential-client secret failure remains
`credential_unavailable`, with operation `authorization`.

The OAuth boundary uses this exhaustive provenance mapping during explicit
authorization, `doctor --connect`, and session opening/acquisition; an unlisted
raw reason is a caught `internal/internal_error`, never guessed into a retryable
class:

| OAuth/store outcome | Public diagnostic | Retryable |
| --- | --- | --- |
| absent grant, expired grant without an admissible refresh, `authorization_required`, or `mcp_authorization_required` before provider dispatch | `active_preflight/authorization_required` | false |
| explicit browser denial, invalid callback, invalid/consumed flow, or authorization-code rejection | `active_preflight/authorization_rejected` | false |
| `authorization_timeout` or explicit callback/listener wait expiry before any possibly-dispatched token/code mutation | `active_preflight/authorization_required` | false |
| store timeout/unavailability/error, runtime-service timeout/unavailability, `mutation_busy`, `principal_retiring`, or `authority_retiring`, all before external dispatch | `active_preflight/authorization_unavailable` | true |
| `authority_collision`, `stale_authority`, `stale_principal`, or another epoch/fingerprint mismatch | `provider_acquisition/provider_policy_changed` | false |
| invalid runtime specification, invalid store handle, invalid authority batch, or an impossible post-construction context shape | `internal/internal_error` | false |
| missing or failed just-in-time confidential-client binding before token dispatch | `active_preflight/credential_unavailable`, authorization subject | false |
| malformed, oversized, or unsupported successful OAuth discovery/token response before provider request dispatch | `active_preflight/connectivity_protocol_error`, authorization subject | false |
| well-formed OAuth discovery/token endpoint rejection other than the explicit authorization, credential, or lifecycle cases in this table, before provider request dispatch | `active_preflight/connectivity_rejected`, authorization subject | false |
| OAuth metadata/token timeout or transport failure with no indeterminate authorization mutation | `active_preflight/connectivity_unavailable` | true |
| refresh/code mutation that crossed `possibly_dispatched`, including `mutation_indeterminate`, an indeterminate commit, or a failed compensating fence | `active_preflight/authorization_required` | false |
| dynamic OAuth `401` after fencing the sent generation, or valid satisfiable `403 insufficient_scope` after fencing its requirement | `active_preflight/authorization_required` | false |
| dynamic OAuth `403` with a syntactically valid challenge but an unsatisfiable or unsupported scope requirement | `active_preflight/connectivity_rejected`, authorization subject | false |
| dynamic OAuth `403` with a missing or malformed challenge | `active_preflight/connectivity_protocol_error`, authorization subject | false |
| dynamic OAuth rejection that proves the presented client/grant is invalid without installing a new requirement | `active_preflight/authentication_rejected`, authorization subject | false |
| static-auth provider `401`/`403` during `doctor --connect` or another explicit connectivity probe | `active_preflight/authentication_rejected`, connectivity subject | false |
| static-auth provider `401`/`403` during ordinary session opening/acquisition | `active_preflight/authentication_rejected`, acquisition subject | false |
| static-auth provider `401`/`403` during provider execution | `execution/provider_failed`, execution subject | false |
| failure to persist an already fenced response-driven OAuth transition during `doctor --connect` | `active_preflight/connectivity_outcome_unknown`, connectivity subject | false |
| failure to persist an already fenced response-driven OAuth transition during ordinary session opening/acquisition | `provider_acquisition/provider_unavailable`, acquisition subject | false |
| failure to persist an already fenced response-driven OAuth transition during provider execution | `execution/provider_failed`, execution subject | false |

The classifier receives the operation and dispatch provenance, not only the raw
atom. In particular, it cannot turn an unsafe refresh/code outcome into
`authorization_unavailable`, retry the original MCP operation, or erase the
runtime-shared local fence.

Phase 10 has one explicit projection override, subordinate to the binding-limit
rule below. Any non-invariant dynamic OAuth/store outcome encountered while
obtaining an execution request's bearer header, refreshing it, or processing
that request's `401`/`403`—including authorization-required, stale/retiring
lifecycle state, credential resolution, transport/protocol rejection,
response-transition persistence failure, and timeout when the provider's
intrinsic deadline binds—maps to non-retryable `execution/provider_failed` with
the exact provider execution subject and occurrence. If the run deadline binds
that timeout, including an exact tie, `execution/run_timeout` with a null subject
wins instead. The internal `ProviderError` retains only the closed cause,
dispatch provenance, mutation state, and deadline provenance needed by Kernel;
the public envelope never backdates a phase-10 failure to `active_preflight` or
`provider_acquisition`. An invalid runtime specification or impossible internal
shape remains `internal/internal_error`, and cleanup may still displace either
result under the precedence table. Explicit browser interaction is never
entered from phase 10. Thus the table, this operation override, binding-limit
precedence, and the diagnostic catalog jointly close every doctor and run
outcome.
An explicit authorization target runs in a monitored resource worker. On its
deadline the owner stops the listener/worker and expires the pending flow under
the remaining bounded cleanup budget. If no token/code mutation was possibly
dispatched, the timeout row above applies. If dispatch provenance is
indeterminate, the existing possibly-dispatched row applies and its local fence
is preserved. Failure to stop a registered root or persist the required fence
is a provider cleanup failure under the compound precedence table, not silently
collapsed into the authorization timeout.
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
7. `RunCoordinator.open_session/2` starts the event and optional inspection
   owners from the sealed `ExecutionPolicy`, then runs shared audited-local
   provider checks that perform no credential access, process launch, network
   activity, discovery, or unbounded callback;
8. `RunCoordinator.open_session/2` enters the active-provider boundary, runs any
   unverified/active preflight, activates selected execution-scoped provider
   services, and resolves ordinary static credentials;
9. `RunCoordinator.open_session/2` acquires providers, including OAuth grant
   admission/refresh and MCP discovery,
   and returns one owner-backed `ExecutionSession`;
10. `RunCoordinator.execute/2` assembles and executes the Kernel;
11. `RunCoordinator.execute/2` guards the result, validates its contract,
    projects it to the selected native/JSON policy, closes every acquired
    provider, and finalizes terminal events from the compound
    execution/contract/cleanup outcome; and
12. `CommandEngine`, or an embedding host persistence adapter, publishes the
    result only when cleanup succeeded, while permitting requested trace and
    inspection adapters to publish the terminal failure evidence needed to
    diagnose cleanup failure.

Phase 2 may decode and validate inert OAuth authority configuration, including
references to a confidential-client binding, but it cannot construct
`MCPOAuth.Context`, call `Store.claim_principal/4` or
`Store.claim_authorities/4`, load a grant, or invoke a runtime-service factory.
`validate`, `models`, and default `doctor` therefore need no
`ProviderRuntimeServices` value and complete without touching an OAuth store,
even when the host installs OAuth-bearing MCP aliases. Phase 8 activates only
selected services, after all destinations and audited-local checks pass. Once
the activity marker is set, `disabled` mode returns the closed
`authorization_required` failure above without a store or cleanup reservation.
For `context_groups`, every required provider-application gate must succeed
before activation admission or any context, store, resolver, listener,
interaction, URL output, token-manager, or network action. The coordinator then
atomically reserves the entire
worst-case cleanup-capacity batch for the selected OAuth occurrences. That
batch either succeeds in full or fails before any runtime-service callback,
credential resolver, context/store call, authorization interaction, token
manager, or network action. Immediately after the marker it seals
`activation_admission_deadline_ms = monotonic_now_ms +
provider_cleanup_timeout_ms`; the application gates, Registry reservation, and
mandatory selected store-identity checks share that one absolute deadline
without resetting it.
Application-gate failure or expiry uses non-retryable
`active_preflight/provider_application_unavailable` and occurs before a
reservation. Reservation timeout or unavailability uses the closed availability
diagnostic below. A missing/malformed store-identity callback or an identity
collision is an invalid runtime specification and uses
`internal/internal_error`; callback raise/exit is the same caught internal
error, while callback deadline expiry uses retryable
`active_preflight/authorization_unavailable`. Every post-reservation failure
releases the full reservation batch. Explicit Mix authorization, when
requested, runs as a bounded pre-run subphase only after both the application
gate and activation admission succeed. Phase 9 may admit or refresh a grant as
part of selected MCP acquisition; ordinary execution never starts an
authorization interaction.

For ordinary `run`/REPL session opening, the coordinator starts the effective
`run_duration_ms` clock and seals `run_deadline_ms` immediately before the
first ordinary post-authorization phase-8 runtime action. With no explicit
interaction, that is immediately after activation admission (the capacity
reservation and store-identity validation). With explicit Mix authorization,
it is after every requested target has completed;
interactive browser time is governed by the target's authorization deadline
and does not consume the ordinary run budget. Define that instant as
`ordinary_phase_8_start_ms`. Each selected MCP occurrence also receives the two
distinct values
`provider_intrinsic_deadline_ms = ordinary_phase_8_start_ms +
normalized_timeout_ms` and
`occurrence_deadline_ms = min(run_deadline_ms,
provider_intrinsic_deadline_ms)`. For a repeated OAuth alias, its intrinsic
runtime-service deadline is the minimum of its occurrences' provider-intrinsic
deadlines. Within one selected OAuth context group, the principal claim uses
the minimum intrinsic runtime-service deadline of that group's selected
aliases, then combines it with `run_deadline_ms`; different groups claim their
own principals independently. Authority claims are never batched across
context groups. After a group's principal succeeds, the coordinator makes one
atomic authority batch for all selected aliases in that group under the same
group-minimum deadline. It orders unique authority entries by the UTF-8 bytes
of their lowest mapped alias; repeated occurrences and identical
installation-ID/fingerprint entries are claimed once and share the returned
epoch. Conflicting fingerprints for one installation ID inside a group are an
invalid runtime specification rejected before the store call. Grant admission,
refresh, and provider acquisition then use the relevant occurrence deadline
without resetting it. This deliberately makes the shortest selected OAuth
occurrence in one group bound all of that group's shared context setup rather
than allowing setup to consume time hidden from the occurrence. Provider-free
and non-OAuth runs retain the same run clock but skip these claims.

`ManagerCleanup.Registry.reserve_many/3` takes the active operation owner, one
slot per selected OAuth occurrence in total acquisition order, and
`activation_admission_deadline_ms`. The count is bounded by both the installed
selection limits and the Registry's fixed capacity. Its serialized ledger
mutation is all-or-nothing: saturation, Registry unavailability, deadline
expiry, or malformed acknowledgement leaves no partial reservation and returns
retryable
`active_preflight/authorization_unavailable`, anchored to the first selected
OAuth alias with operation `authorization` and `occurrence: null`. The
Registry checks the supplied absolute deadline before mutating its ledger, so a
call that expires while queued cannot later create orphan reservations. The
coordinator releases every unused slot when authorization, preflight, or
acquisition stops before a token manager is constructed. Acquisition binds any
constructed manager to that occurrence's exact pre-reserved slot before
exposing it. It never borrows another occurrence's slot or reserves after a
store mutation.

Extend the intentionally breaking 0.x `Store.claim_authorities/4` result
contract without weakening its all-or-nothing mutation: an
`authority_collision` or `authority_retiring` error also returns the
zero-based index of the rejected ordered input entry. The store validates the
whole batch and either commits every compatible/new authority or none. Generic
timeout, availability, or adapter failure has no entry index because it applies
to the group operation; an out-of-range/missing index for an entry-specific
reason is an `internal/internal_error`, not guessed. The safe index is consumed
inside the coordinator and never enters the envelope.

Each selected group seals a deterministic diagnostic anchor: the selected
occurrence that supplied its minimum provider-intrinsic deadline, breaking ties
by alias UTF-8 bytes, `workflow` before `mission`, then manifest index. Group
claims run in anchor order. A pre-dispatch principal-context/store failure uses
`active_preflight/authorization_unavailable` and that anchor's alias,
`authorization` operation, and `occurrence: null`, because the shared operation
has not entered an occurrence. An indexed `authority_collision` uses the
rejected entry's lowest mapped alias, `authorization`, and `occurrence: null`,
with `provider_acquisition/provider_policy_changed`; indexed
`authority_retiring` uses the same subject with retryable
`active_preflight/authorization_unavailable`. A generic authority-batch
availability failure uses the group anchor and the same availability code. If
the run deadline binds, the ordinary `execution/run_timeout` null-subject rule
below wins instead. Thus a shared group operation never chooses an arbitrary
alias, while failures in separate tenant/principal/store groups remain
independently attributable.

Every ordinary phase-8–10 bounded operation derives an
`operation_intrinsic_deadline_ms` before it starts and carries that candidate,
`run_deadline_ms`, and their binding-limit provenance; passing only the minimum
timestamp is forbidden. For occurrence acquisition and its nested OAuth work,
the intrinsic candidate is `provider_intrinsic_deadline_ms`, not the already
minimized `occurrence_deadline_ms`. For an OAuth context-group claim, it is the
group minimum defined above. For active selection validation, it is the
validator invocation's monotonic start plus
`selection_validation_timeout_ms`, including for a custom provider with no MCP
timeout. Any later operation-specific bound follows the same construction and
must name its diagnostic before admission. There are two pre-run exceptions
with no not-yet-created `run_deadline_ms`: activation admission carries
`activation_admission_deadline_ms` and the installed cleanup-limit provenance;
the explicit authorization subphase gives each target its own
`authorization_deadline_ms` and authorization provenance. Their expiry is
classified by the closed activation/authorization diagnostics, never as
`execution/run_timeout`.

If `run_deadline_ms <= operation_intrinsic_deadline_ms`, expiry anywhere in
the ordinary phases 8–10 is non-retryable `execution/run_timeout` with `subject: null`,
including expiry during selection validation, OAuth context/store work, or
provider acquisition; the run limit wins an exact tie. Only when the intrinsic
operation deadline is strictly earlier does the operation-specific mapper
apply: selection validation uses `selection_validation_timeout`, OAuth
runtime-service/store expiry before external dispatch uses retryable
`authorization_unavailable`, and provider acquisition expiry uses
non-retryable `provider_acquisition/provider_unavailable`, each with its
documented provider subject. Nested calls inherit both candidates and
provenance and may narrow but never reset them. Cleanup failure can still
displace any of these under the compound-failure precedence table. `RunState`
receives the already sealed `run_deadline_ms` and provenance and never starts a
replacement `run_duration_ms` clock after phase-8 setup.

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

`RunCoordinator.prepare/2` accepts only a sealed request and inert trusted
`InstallationCatalog` and returns a sealed prepared run containing classification,
digests, normalized selections, execution policy, and an activity marker still
set to false.
`open_session/2` consumes that prepared run exactly once with one sealed
`ProviderRuntimeServices` value, owns provider
activity and phases 7–9, and returns a non-forgeable `ExecutionSession`
containing the live event/optional inspection owners, acquired owner-backed
resource graph, and complete Kernel configuration. It starts the sinks before
the first phase-7 check so both one-shot and REPL modes have the same event
lifecycle; any failed open closes the sinks and resource graph under the same
bounded owner. Its owner must either pass it to one-shot execution or transfer
it once to the REPL session owner; owner death or explicit close runs the same
bounded cleanup and sink finalization.
`execute/2` is the one-shot operation: it opens a prepared run with the supplied
runtime services through `open_session/2`, runs phases 10–11, and returns a
`RunOutcome` after cleanup.
An internal `execute_session/1` consumes an already-open session exactly once
for this composition; it is not a second acquisition path.

Neither operation knows argv, paths, destinations, or publication callbacks.
`CommandEngine` never reproduces compilation, selection, acquisition,
execution, or cleanup semantics. A cloud host calls the same `prepare/2` and
`execute/2`, with a memory application adapter and no file destinations.
`validate` calls `prepare/2` only. The manifest-backed Mix REPL calls
`prepare/2` and `open_session/2`, transfers the returned handle to
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
identities and capture/projection policy. `open_session/2` starts event and
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
protocol shutdown. The owner retains authority to force-terminate ordinary
registered roots; the only exception is an OAuth token manager with an
unsettled response-persistence fence, whose safe terminal operation is
ownership transfer rather than termination as defined below. Migrate the
shipped LLM/replay builders, MCP transports,
trace/inspection snapshots, and the custom builder API to this lease contract.
Legacy custom callbacks that cannot satisfy it are unsupported and removed in
this intentional 0.x break. Custom builders are trusted same-VM host code: the
runtime can clean roots registered through the framework-owned constructors,
but it cannot prevent arbitrary Elixir code from spawning an unlinked process,
transferring a port, or hiding a resource in a closure. Registration is
therefore an explicit trusted-callback obligation, not a sandbox guarantee.
Hosted untrusted extensions require a later process/isolation boundary.

OAuth response persistence adds one closed transferable resource kind. Split
the command-core cleanup facility into a bounded `ManagerCleanup.Registry` and
its restartable worker supervisor. The registry is a sibling outside the worker
supervisor's restart domain. A namespaced, non-secret `:persistent_term` lease
ledger is authoritative for the VM-local capacity count across Registry
restarts; records contain only a random lease ID, transfer generation, the
operation-owner/manager pid where present, state, and safe timestamps—never a
store key, authority, tenant/principal, token, or provider selector.

Immediately after the phase-8 activity marker, the coordinator seals
`activation_admission_deadline_ms` and runs every required
provider-application gate under it. Only after those gates succeed,
`context_groups` activation calls serialized
`ManagerCleanup.Registry.reserve_many/3` once for the complete ordered
occurrence count and the same caller-owned deadline. It atomically writes every
owner-monitored `reserved` record or none, before context construction, store or
resolver work, interaction, token-manager creation, or network activity. It
rechecks the absolute deadline before mutation, including after mailbox backlog.
Reservation failure maps to retryable
`active_preflight/authorization_unavailable`; the implementation may not
perform provider work and hope that `adopt/1` later succeeds. Registry restart
reconstructs and re-monitors live operation owners; a dead owner with an
unbound reservation releases it, while a record already bound to a manager
follows the manager rules below.

Each OAuth acquisition receives its exact pre-reserved slot. If it constructs a
token manager, the Registry atomically binds that manager and its transfer
generation to the slot and the pending `AcquisitionLease` before either is
exposed. If no manager is needed, or if authorization/preflight/acquisition
stops first, the resource owner releases the unused slot during the same
bounded rollback. The Registry never allocates a replacement slot after a store
mutation and never reassigns one occurrence's slot to another.

A clean manager does not exit first and rely on a transient `DOWN` reason.
After its persistence fence is settled during per-run cleanup, it calls
idempotent `ManagerCleanup.Registry.mark_clean/4` with lease ID, transfer
generation, manager pid, and the remaining per-run cleanup deadline. The
Registry atomically writes
`clean_pending_exit` to the persistent ledger and acknowledges that exact
generation; only after receiving the acknowledgement may the manager exit. The
Registry retains the clean record until it observes that manager dead, then
erases it. If the Registry crashes after the write but before acknowledgement,
the live manager retries and receives the same acknowledgement. If the manager
received it and exits while the Registry is down, restart sees
`clean_pending_exit` plus a dead matching pid and erases the slot. A crash after
`DOWN` but before erase is handled identically. If the clean acknowledgement
cannot complete within the per-run cleanup deadline, the still-live manager
transfers/remains in autonomous cleanup and the command reports cleanup failure;
it never exits into an unprovable state.

An autonomous manager never reuses the expired per-run deadline. Once a later
persistence attempt settles its fence, it seals a fresh manager-owned
`cleanup_ack_attempt_deadline_ms = monotonic_now_ms +
provider_cleanup_timeout_ms`, using the installed value captured when the
manager was created, and calls the same idempotent `mark_clean/4`. If the
Registry call times out or is unavailable, the manager remains live and retries
with capped backoff; every retry gets one fresh bounded acknowledgement-attempt
deadline. It exits only after the exact generation is acknowledged. This
manager-owned retry clock can outlive the command but cannot make that command's
failed cleanup successful retroactively.

Change `TokenManager.close/1` at this integration boundary to accept the
resource owner's remaining monotonic deadline; its current fixed 6,000 ms call
cannot run beneath the installed 5,000 ms default. If response persistence is
still unsettled when the per-run attempt fails or its allotted deadline
expires, call a new atomic `TokenManager.transfer_to_cleanup/3` handshake. It
first records the manager against the pre-reserved registry lease, then changes
the manager from per-run ownership to an autonomous `deferred_cleanup` state,
cancels the old owner monitor, schedules its own individually bounded
persistence retries with capped backoff, and acknowledges only after both sides
observe the same transfer generation. The manager itself is the sole retry
owner; a cleanup worker may observe or nudge it but never links to it or owns its
survival. The registry monitors the manager and releases capacity only when that
generation completes the `clean_pending_exit` handshake and is observed dead.

A committed transfer removes the manager root from the per-run graph and leaves
the runtime-shared fence closed. Killing or restarting the cleanup worker
supervisor cannot kill the manager or interrupt its self-retry; the surviving
registry reattaches observation after restart. On Registry start, admission
remains closed while it reconstructs reservations and monitors from the entire
namespaced ledger. A live autonomous manager continues self-retry and
re-registers its generation. A dead matching manager in
`clean_pending_exit` is the sole recoverable exit state and releases its slot; a
dead manager whose ledger record did not reach that state becomes a `poisoned`
reservation that still consumes capacity and is never automatically erased or
reused. An abnormal autonomous-manager exit therefore fails closed rather than
creating a replacement with lost secret state. A Registry crash loses no
capacity state, and calls while it is absent fail as
`authorization_unavailable` before manager/store/network work.

The bounded internal ledger record is removed only after a
generation-acknowledged `clean_pending_exit` manager is observed dead, an
unbound owner dies, or the whole VM terminates. Loss of the command-core root
application/VM remains outside
the live-VM cleanup guarantee; a host may replace that VM but cannot restart the
application in place while discarding poisoned records. Transfer does not turn
cleanup into success: the command reports
`result_cleanup/provider_cleanup_failed` (or `provider_cleanup_timeout` when
expiry was primary), withholds the result, and may publish authorized terminal
evidence. `cleanup_unavailable` is an internal transfer failure, never a new
public code and never `mcp_transport_error`; the pre-reservation and
generation-acknowledgement protocol must make it unreachable after manager
creation. An invariant breach maps to the existing cleanup failure while the
pre-transfer owner remains authoritative; it never kills or orphans the
unsettled manager.

`ManagerCleanup.Registry` remains bounded to its configured capacity.
Saturation applies backpressure through reservation and cannot silently kill a
manager, discard a retry owner, or admit more OAuth work. Poisoned slots may
reduce availability, but never relax fencing or the capacity bound. No
standalone V1 command creates an OAuth manager, so its short-lived VM does not
claim deferred durable convergence. Mix and long-lived host-owned modes keep
the command-core registry and supervisor alive independently of provider
applications.

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
cleanup loop. The one post-run retry loop lives in each transferred manager's
autonomous state and is bounded by the central command-core registry above.
Direct embedding constructors that
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
- activation of execution-scoped provider runtime services, including any
  OAuth context construction or store claim;
- any credential resolution;
- optional provider application startup; or
- provider acquisition/discovery.

The transition and work authorization happen in one owner-process operation;
there is no separate read followed by update. Once true, the marker cannot be
reset by a later result or adapter. An ambiguous caught failure reports true.
A whole-VM crash may have no envelope.

Replace callback-derived preparation metadata with a sealed
`ProviderDescriptor` registered alongside each builder. It declares bounded
ordinary static credential names, a closed `authorization_mode` of `none` or
`oauth`, data policy, service dependencies, destination eligibility,
workflow-LLM identity, a closed connectivity mode, a closed selection-validation
mode, and a data-only `SelectionRules` value. OAuth descriptors also carry the
already validated inert `Authority` and its private behavior fingerprint, but
not an `MCPOAuth.Context`, store claim, grant, token manager, or principal. The
fingerprint remains an internal grant-fencing key and is never a public or
effective-application fingerprint. The selection-validation mode is
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

Ordinary credential resolution remains a once-resolved phase-8 barrier for
static MCP authentication, stdio environment bindings, and live LLM keys. OAuth
is not forced into that map. Its bearer grant is store-owned, and a confidential
client secret is resolved only when code exchange or refresh actually needs it,
through the runtime specification's bounded just-in-time resolver. A descriptor
with `authorization_mode: oauth` therefore may have no ordinary credential
names while still producing the separate doctor authorization check. The
dispatcher owns the mapping from OAuth/store reasons to the closed diagnostics;
provider callbacks cannot supply public retryability.

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
`selection_validation_timeout_ms`. During `doctor --connect`, the occurrence
deadline may narrow that worker further as defined below without changing its
selection-specific failure projection. The callback receives only the
normalized selection and sealed post-selection context and has exactly two admitted
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

The explicit Mix authorization subphase is the sole ordering exception. After
the activity marker, every required provider-application gate succeeds first;
activation admission then reserves cleanup capacity and validates selected
store identities; only then does the coordinator complete every requested
authorization target before these ordinary phase-8 validators run.
Authorization targets therefore cannot observe credentials or provider work
from ordinary preflight, and an application-gate, admission, or authorization
failure stops before any validator. A noninteractive run follows the ordinary
ordering directly.

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
process-global attestation keys. The OAuth store already keeps trusted
tenant/principal namespaces distinct, and this plan preserves those
execution-scoped partition keys, but inbound authentication and adversarial
cloud tenant isolation belong outside this BEAM instance unless a later service
design establishes a stronger boundary.

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

`FrozenBundle.hash` changes in commit 0 to bare lowercase SHA-256 hex over the
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
        "authorization_mode": "none",
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
class, accepted data classes, closed `authorization_mode`, and phase-5
normalized selection config—not the original spelling or raw installation
configuration. `authorization_mode` is exactly `none` or `oauth`; it exposes no
issuer, resource, client, scope, redirect, tenant, principal, store, credential
binding, or authority fingerprint. `accepts_data` is sorted
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

Standalone V1 deliberately has no OAuth authorization command or interaction
flag. The runtime ships no durable OAuth store, and a separate authorization
process backed only by the current in-memory adapter could not make its grant
available to a later `ptc run`. An OAuth-bearing host remains valid input to
standalone `validate`, `models`, and default `doctor`, which inspect only inert
declarations without store activity. A standalone `run` or `doctor --connect`
that selects OAuth reaches the marked phase-8 boundary and returns
`active_preflight/authorization_required` without constructing a token manager
or opening an interaction. The retained
[`mcp-oauth-durable-store.md`](../future/mcp-oauth-durable-store.md) trigger owns
any later standalone authorization command and its private interaction
protocol.

`mix ptc.run --authorize-mcp NAME` remains an explicitly Mix-only, repeatable
interactive adapter outside the standalone argv/envelope contract. The parser
preserves argv order, rejects a duplicate name, and rejects any target that is
missing, non-OAuth, not CLI-compatible, or absent from the manifest's normalized
workflow/mission selections. Authorization targets therefore form an explicit
subset of selected OAuth aliases; an unselected installation is never claimed
as a side effect of the option. Multiple valid targets authorize sequentially
in argv order, while the later ordinary runtime claims every selected OAuth
alias once in the provider graph's deterministic total order.

The adapter may print each one-time URL through the Mix shell, but the shared
coordinator still owns ordering: parse and static validation, destination
preflight, and audited-local checks complete first; provider activity is
atomically marked; every required provider-application gate succeeds; cleanup
capacity for every selected OAuth occurrence is then reserved in one batch and
selected store identities are validated; only after those steps does the Mix
runtime service construct the principal context and perform the requested
authorizations before ordinary active preflight, provider acquisition, or
Kernel execution. Application-gate failure therefore occurs before a cleanup
reservation, context/store call, listener, interaction, or URL output.
Immediately before each target's first
context/store/listener action, the coordinator seals a fresh
`authorization_deadline_ms = monotonic_now_ms +
authority.authorization_timeout_ms`. That one absolute deadline covers the
target's context and claims, listener, discovery, interaction, and token commit;
sequential targets never inherit or reset one another's clock.

After every requested authorization succeeds, the authorization-only contexts
are discarded, the ordinary run clock starts, and the selected context groups
are constructed/claimed under the ordinary deadlines as for a noninteractive
run. The persisted grant may make those idempotent claims cheap, but interaction
does not satisfy, extend, or predate the ordinary run deadline. An authorization
failure releases all unused reservations and sinks under the bounded owner and
returns the applicable `authorization_required`,
`authorization_rejected`, or `authorization_unavailable` diagnostic; it cannot
become `run_timeout` merely because the browser interaction exceeded
`run_duration_ms`.
Without an explicit flag, normal Mix and embedded runs never open an
interaction. A host-owned embedding may supply a previously populated durable
store or perform explicit authorization through its own trusted interaction
implementation; both use the same lazy `ProviderRuntimeServices` seam.

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
callback, an OAuth store/context, a process, discovery, or network access are
reported as skipped by default. `doctor --connect` enters the active boundary and flips
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
| host only | `skipped/not_requested` | every installed alias; local is `skipped/application_required`, selection is omitted, and declared credential/authorization/connectivity checks are `skipped/requires_connect` |
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

After the activity marker, `doctor --connect` runs every required
provider-application gate under `activation_admission_deadline_ms`. For selected
OAuth descriptors, it then performs the one all-or-none cleanup-capacity
reservation and mandatory store-identity validation under the remainder of that
same deadline, before any occurrence connectivity clock or store mutation.
Batch failure uses the first selected OAuth alias with a null occurrence as
specified above; it is not charged independently to every occurrence.

After all application gates and any OAuth activation admission succeed, seal
one `doctor_phase_8_start_ms`. Every selected occurrence whose connectivity mode
is `acquisition` or `probe` receives
`doctor_operation_deadline_ms = doctor_phase_8_start_ms +
doctor_connectivity_timeout_ms`. If its sealed normalized selection has a
provider timeout, it also receives `doctor_provider_deadline_ms =
doctor_phase_8_start_ms + normalized_timeout_ms` and
`doctor_occurrence_deadline_ms` is the minimum of those values; otherwise its
occurrence deadline is the operation deadline. This formula applies unchanged
to static MCP and custom acquisition/probe occurrences.

The coordinator preserves two barriers. First it runs every active selection
validator in the documented occurrence order before resolving any credential.
For an occurrence with a doctor deadline, its validator runs under
`min(doctor_occurrence_deadline_ms, validator_start_ms +
selection_validation_timeout_ms)`; an occurrence without a connectivity
operation retains the selection-validation deadline alone. If the doctor
occurrence deadline binds, including an exact tie, the dispatcher terminates
the validator's owned worker tree and returns non-retryable
`active_preflight/selection_validation_timeout` with its selection occurrence;
the callback's possible external effect forbids the generic retryable
connectivity mapping.

Only after every validator succeeds, the coordinator groups ordinary credential
requirements by alias and resolves each alias exactly once in alias byte order.
For an alias with one or more doctor connectivity occurrences, seal
`doctor_alias_credential_deadline_ms` as the minimum of their already-running
occurrence deadlines; repeated workflow/mission occurrences share the one
resolved value. If an alias declares ordinary credentials but every occurrence
has `connectivity_mode: none`, seal its credential deadline instead as
`doctor_phase_8_start_ms + doctor_connectivity_timeout_ms`; omitting a
connectivity check does not leave credential resolution unbounded. This is the
same already-running doctor-phase clock, not a fresh timeout taken when the
resolver starts. Credential resolution cannot reset either form of clock. If
that alias deadline binds, the dispatcher terminates the resolver worker and
returns non-retryable `active_preflight/credential_unavailable` with the
documented alias-wide credentials subject and `occurrence: null`. The same
operation-specific projection applies to resolver rejection, raise, or exit. A
later validator failure therefore performs zero credential reads.

Only after both barriers succeed does the coordinator apply the same
context-group algorithm as an ordinary run to the OAuth subset: one
principal claim and one ordered atomic authority batch per group, under the
minimum doctor occurrence deadline in that group; unique authorities and
repeated occurrences are claimed once; groups and their deterministic anchors
use the same ordering, indexed-failure attribution, and null-occurrence
shared-failure subjects defined above. Claims never cross a group.

After a group's claims succeed, each occurrence's grant
load/refresh/admission, acquisition-backed discovery, and provisional cleanup
continue under that occurrence's already-running deadline without resetting it.
Thus shared setup consumes every member's budget, while a repeated/shared alias
does not create extra principal or authority mutations. A usable grant allows
the authorization check to pass only after the bearer admission needed for
discovery succeeds. Missing or expired-without-refresh grants return
`authorization_required`; other raw outcomes use the exhaustive provenance
table above. A dynamic OAuth `401` or valid satisfiable `403
insufficient_scope` received after an actual provider request also returns
`authorization_required` only after its runtime-shared fence is installed.
Ordinary/malformed `403` and static-auth rejection retain the existing closed
authentication/scope/protocol mappings. Doctor never reports authorization
`available` merely because an OAuth block or credential binding parsed.

Every occurrence-level connectivity operation, including acquisition-backed
MCP discovery, runs in a monitored worker under that one absolute deadline. For
`acquisition`, the occurrence deadline begins after the separately bounded
application/activation-admission work and covers active selection validation,
credentials, OAuth context/group claims and grant admission, dependency
dispatch, process/session startup, discovery, bounded response consumption, and
provisional-resource registration. On expiry the dispatcher terminates the
ordinary owned worker tree and rolls back every registered provisional resource
under the separate cleanup deadline.

Only an observational discovery timeout with settled authorization state maps
to retryable `active_preflight/connectivity_unavailable` with that occurrence's
connectivity subject. If a refresh/code mutation may have been dispatched, or a
response-driven fence is awaiting persistence, the owner first preserves or
transfers the manager and projects the applicable non-retryable
`authorization_required` or `connectivity_outcome_unknown` row from the
provenance table; the generic timeout mapper may not overwrite it. An
`acquisition` connectivity descriptor promises that this doctor operation has
no application-domain effect beyond the separately classified OAuth lifecycle
work; shipped MCP satisfies that rule, and a custom implementation is a trusted
obligation. Cleanup failure can still replace the timeout as primary under the
documented precedence while retaining the timeout in `secondary_errors`.

Every selected shipped live-LLM descriptor supplies a code-owned bounded
`connectivity_probe` operation in addition to acquisition. After the activity
marker, provider-application gate, active selection validation, and explicit
credential resolution, `doctor --connect` invokes that operation with only the
normalized selection, resolved credential value, and its sealed
`doctor_occurrence_deadline_ms`. That one monotonic deadline covers application
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

Keep the existing code-owned `MCPHTTPAdapter` as the one shared request facade.
It already avoids Req/Finch, pooling, redirects, retries, and automatic
decompression; the probe adds only its closed serializer, header policy,
response callbacks, and outcome mapping. Pin Mint logging off explicitly rather
than relying on its default, and prove no request/response material reaches a
Logger or Telemetry handler.

The current adapter's active Mint receive path is not the final supported
backend. `active: :once` can deliver an OS/environment-sized socket message
before the adapter callback, and a finite fixture cannot establish an
authoritative adversarial bound. Commit 7 therefore installs one capped passive
receive boundary behind `MCPHTTPAdapter`, not a parallel public HTTP stack.
`recv_up_to(max_bytes, deadline)` must return promptly after at least one byte is
available, never return more than the positive maximum, and preserve one
absolute deadline. Plain TCP may use OTP `:socket.recv/4` in nowait/select mode.
If OTP `:ssl` cannot prove the equivalent TLS bound, use a small length-framed
port helper whose frames are capped before entering BEAM and whose
stderr/lifecycle follow `ProviderResources`. Mint may remain the pinned
HTTP/1.1 parser only if it consumes exclusively those already-capped chunks and
cannot perform its own active or zero-length receive; otherwise replace that
internal parser within the same adapter. Do not ship both backends for one
target or fall back to an unbounded library executor.

The dependency-version-bound conformance suite then proves the selected
backend's one monotonic deadline, prompt partial delivery, authoritative
transport-chunk bound, cumulative status/header/body bounds, peer/hostname
verification, SNI, ALPN restricted to HTTP/1.1, pinned in-memory CA trust, and
compression rejection before decoding. Retained and decoded response data may
never exceed the configured payload cap plus one. These are implementation
tests tied to the pinned Mint/OTP/TLS versions, not measurements used to infer a
hard bound.

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

The pinned Mint parser plus adapter callbacks must enforce line/aggregate
status, header, trailer, field-count, informational-response-count, and body
ceilings before unbounded retention. After validating final headers, admit only
a valid `Content-Length` or ordinary chunked body; close-delimited bodies fail
closed. Reject an oversized declared length before body retention, count
identity payload pieces before retaining or decoding them, and close on
overflow. A large announced chunk delivered through many small SSE writes must
still produce prompt callbacks. Thus at most cap-plus-one payload bytes are
retained or decoded, a compressed body never expands inside the command, and
the configured capped-receive transport-ingress bound also holds.
The live-LLM connectivity probe retains no response body, emits no selector or
credential metadata, and returns only one closed normalized outcome. Its
HTTP/protocol outcomes, distinct from the OAuth MCP response transitions above,
map as follows:

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
check closes or rolls back its registered ordinary sessions, ports, and process
roots under the installed global cleanup deadline before the command returns.
An OAuth token manager with unsettled response persistence may instead complete
the pre-reserved ownership transfer above; the command still returns a cleanup
failure while the host-owned supervisor retains the one live retry owner. A
single-provider close failure reports
`result_cleanup/provider_cleanup_failed` (or
`provider_cleanup_timeout`) with that provider's `cleanup` subject; failures
spanning providers use `subject: null`. No `available` check is emitted until
its acquisition lease is committed, and cleanup failure replaces doctor
success. Host-owned OTP applications are not part of this per-command cleanup.

`models` lists safe installed aliases and metadata without resolving
credentials, constructing an OAuth context, claiming/loading a store, starting
providers, or emitting/fingerprinting raw model selectors. The
transport-neutral command core accepts one already validated
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

### Delivery protocol

Implement this entire plan on one feature branch and deliver it through one
draft PR targeting `origin/main`. Open the draft after commit 0 and accumulate
the numbered commits below in order; do not split the work across independent
PRs and do not squash the slice boundaries. Every numbered slice is exactly one
reviewable commit in the final PR history. Each commit must leave the repository
compiling, keep all previously completed gates green, update its generated
artifacts and durable module/guide documentation, and contain no temporary
compatibility path or knowingly dead scaffold.

For each numbered commit:

1. implement only that slice and its gate;
2. run the focused tests plus `mix precommit`;
3. run an independent adversarial review of that commit in the context of all
   preceding commits;
4. address findings by amending the same slice commit and repeat focused
   follow-up review until it has no actionable finding;
5. run a fresh independent review as the final gate; and
6. only after that fresh review is clean, push the commit to the draft PR and
   begin the next slice.

The completed branch then receives one final `mix precommit`, the credentialed
live-model acceptance in commit 11, and a fresh full-PR review against
`origin/main`. Record the focused commands and clean review result for every
commit in the PR body. A later commit may integrate a completed seam but must
not silently repair a known failure in an earlier commit; amend and re-review
the owning commit instead. If a later integration or the final full-PR review
finds such a defect, rewrite the owning commit with `--force-with-lease`, rerun
that commit's clean-review cycle, and rerun the gates/reviews of every affected
descendant commit before declaring the PR ready.

This PR retains `req_llm`, `llm_db`, the current `PtcRunner.LLM` adapter seam,
and the existing provider/model configuration. The future ReqLLM-removal plan
is explicitly out of scope: do not introduce `PtcRunner.LLM.Target`, replace
the adapter, change the wire codecs, or remove/reclassify either dependency.
The only ReqLLM work allowed here is the structured non-warning model
resolution, safe application lifecycle, and bounded stable-CLI provider
behavior required below.

### Commit 0. Fix bundle graph identity

- replace Erlang-term hashing with the canonical V2 bundle framing above and
  include canonical dependency edges in `FrozenBundle.hash`;
- update trace/application identity consumers; and
- add golden vectors plus the same-bytes/different-edge regression.

**Gate:** rewiring an edge changes the bundle hash without changing component
IDs or sources. The effective-application half of this regression lands with
the digest in commit 4.

### Commit 1. Transport-neutral package and content identity

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
with a different verified base changes the content digest. The corresponding
effective-digest assertion lands in commit 4. Neither package nor selection
context contains an application directory.

### Commit 2. Closed diagnostics and command engine

- define closed outcome, diagnostic, phase, code, source, and activity types;
- add the generated V1 schema, safe renderer, shared argv parser, and closed
  `CommandOutcome`; keep process exit solely in the standalone wrapper;
- preserve typed, schema-context-aware `ValueContract` violation segments at
  classification time and make the diagnostic projector only RFC 6901-escape
  that safe representation;
- establish the `CommandEngine`/path-free `RunCoordinator` boundary above,
  decompose provider-free preparation from `RunBuilder`, and make activity
  monotonic; and
- route provider-free pre-success diagnostics and failure handling through the
  shared engine while retaining the existing public entrypoints; successful
  validation waits for commit 4's final effective digest, and successful
  execution waits for commit 6's owner-backed session lifecycle.

**Gate:** representative provider-free failures through phases 1–5 have exact
schema-valid envelopes, status/code/retryability, path-free safe diagnostics,
and correct `provider_activity: false` through the internal engine API and
existing direct embedding entrypoint. Public Mix/direct frontend parity belongs
to commit 9, and standalone parity belongs to commit 10. Rejected values,
arbitrary exception terms, paths, and private inputs never enter the envelope.

### Commit 3. Closed limit catalog

- replace reflected limit-name handling with the scoped `LimitCatalog`, generate
  both host/application schemas from it, and seal the three installed-only
  operational timeouts with their exact defaults, ranges, scopes, and identity
  participation; and
- migrate existing limit construction, narrowing, and enforcement callers to
  the catalog without changing provider declaration or execution yet.

**Gate:** exact boundary tests cover every generated limit
default/range/scope, host/manifest narrowing rule, runtime lookup, and schema
projection. Generated schemas are current, and invalid or unknown limits fail
before provider activity.

### Commit 4. Provider declarations and effective identity

- add sealed declarative `ProviderDescriptor` metadata, including the closed
  authorization mode, selection-validation mode, connectivity mode,
  probe-effect class, safe installation revision, and
  implementation-consistency checks, so phase 5 never invokes a builder,
  callback, OAuth context, or store;
- replace eager `HostInstallation.registry/1,2` assembly with the inert
  `InstallationCatalog`; retain validated OAuth authority/fingerprint data as
  private descriptor authority while removing principal/context/store claims
  from catalog construction;
- normalize every provider selection, derive the aggregate data class,
  effective flow, and effective event policy, then compute the exact effective
  application projection/digest—including input authority, that policy,
  inspection-capture selection, result projection, `mission.data`, final
  bundles, effective limits, normalized selections, and
  `ptc_semantic_revision`—before constructing the post-selection provider
  context;
- build public snapshots and effective provider projections only from the safe
  declaration fields—including only the safe `authorization_mode`—plus the
  separately hashed runtime-captured
  acquisition/content projection;
- complete successful provider-free validation routing through the shared
  engine now that every required content/effective digest exists; successful
  execution waits for commit 6's owner-backed session lifecycle; and
- regenerate both schemas and update the retained identity, limits, and host
  configuration documentation.

**Gate:** directory and memory runs produce the same effective digest; input
form/value/name within one authority class leaves it unchanged, while an
input-authority-class change, local/shipped/override source, selected provider
source/revision/data policy or normalized selection, `mission.data`, limits,
contracts, dependency edges, effective event privacy, inspection-capture
selection, result projection, or semantic revision changes it. Changing an
unselected installed provider does not change it. Exact boundary tests cover
  all five shipped source variants, both static-auth and OAuth MCP descriptors,
  custom descriptors, normalized selections, and safe installation-revision
  projection. Switching the selected authorization mode changes effective
  identity, while issuer/resource/client/scope/redirect/tenant/principal/store
  and the private authority fingerprint never appear publicly. Same
  candidate/effective source
with a different verified override base changes the content digest but not the
effective digest. Internal-engine and direct-embedding validation success
fixtures return the exact schema-valid digest result without provider activity.

### Commit 5. Local/application and runtime-service preflight

- split provider preflight into deterministic per-occurrence audited-local
  checks and the active application/credential boundary used by the shared
  doctor and run engine operations;
- add sealed lazy `ProviderRuntimeServices` with the closed `disabled` and
  `context_groups` OAuth modes, the latter's private alias-to-context-group map,
  duplicate-store-namespace rejection, and one OAuth runtime specification per
  group; make `open_session/2` activate selected groups only after the marker
  and construct each `MCPOAuth.Context` plus selected authority claims there
  rather than during host/catalog loading;
- replace fixed OAuth context/authority claim waits with absolute-deadline-aware
  APIs; introduce `%Store.Deadline{}` plus the checked Store command catalog
  carrying access, remote-replay, post-dispatch-projection, and cleanup-action
  metadata for every operation; make same-VM transactions recheck the caller's
  absolute deadline before mutation/commit instead of relying on
  `GenServer.call/3`, and require a remote adapter to declare either an
  adapter-authoritative transaction guard or catalog-checked
  indeterminate-after-dispatch mutation semantics;
  pass the applicable authorization-only or ordinary-operation budget through
  every phase-8/9 store and authorization call;
- make store-local identity mandatory and bounded for grouped stores, and
  resolve it only inside marked, monitored activation;
- introduce the command-core `ManagerCleanup.Registry`, its bounded non-secret
  reservation ledger, and usable deadline-aware `reserve_many/3`; atomically
  reserve selected OAuth occurrence capacity before runtime-service/store work,
  release every unused reservation on the pre-manager paths available in this
  slice, give explicit Mix authorization a separate per-target absolute clock,
  then start the ordinary run clock before the first post-authorization runtime
  action; preserve raw per-operation deadline candidates and binding
  provenance, derive repeated-alias and per-context-group OAuth
  deadlines/anchors exactly as specified above, and change the atomic
  authority-batch result to return a checked safe failing index for
  entry-specific errors;
- implement the serialized provider-application gate and safe-start ownership
  records for standalone, Mix CLI, and host-owned modes;
- adjust the application/dependency metadata in this slice so starting
  `:ptc_runner` loads provider code when packaged but never auto-starts
  `:req_llm` or its included `:llm_db` application before the gate;
- make the shipped ReqLLM adapter use the reviewed structured non-warning model
  resolution path without changing or replacing the adapter, centralize final
  generation-option sealing for its plain-text, structured-object, tool-call,
  and streaming constructors, and force `max_retries: 0` in that shared helper
  rather than exposing a host or manifest retry option; and
- make provider activity monotonic before every unverified callback,
  application start, runtime-service activation/store claim, credential
  resolution, or later provider action.

**Gate:** phase-5 declaration and selection validation invokes no builder,
callback, application, credential resolver, OAuth context/store, or network
operation. OAuth-bearing `validate`, `models`, default `doctor`, and
occupied-destination fixtures complete with zero store calls and cannot incur
either current 5,000 ms claim timeout; selected `run`/`doctor --connect` claims
only after the phase-8 marker, while unselected OAuth aliases are never claimed.
Standalone `disabled` activation returns `authorization_required` with no
cleanup reservation, context, store, resolver, manager, interaction, or network
call. Marked activation rejects two group keys that resolve to the same
store-local tenant/principal namespace, accepts the same textual tenant/principal
IDs under distinct mandatory store identities, and permits intended sharing
only by mapping aliases to one group. Missing/malformed identity callbacks and
callback raise/exit/timeout cases take their exact closed paths without a store
mutation; identity fixtures accept arbitrary one- and 128-byte values and reject
empty and 129-byte values.
Slow-store fixtures at the accepted 100 ms minimum prove principal plus
authority claims share one deadline rather than consuming two fixed waits.
Catalog-driven mailbox-backlog fixtures cover every Store mutation class and
prove an expired queued same-VM transaction performs no late mutation; remote
test adapters prove delayed authoritative guards reject before commit and
indeterminate mode never labels a possibly dispatched timeout as unchanged.
Mutations committed before the deadline whose replies are lost retain their
catalog-declared idempotent or indeterminate mapping. Catalog generation covers
every exported command and rejects a missing replay, projector, cleanup action,
or diagnostic pair. Store-handle construction rejects an indeterminate mode
when any catalog mutation is `authoritative_only`, and the direct-transaction
source audit prevents conditional operations from bypassing it.
Ordinary-run fixtures with two OAuth aliases in one context group, another
alias in a different store/tenant/principal group, and repeated occurrences at
distinct normalized timeouts prove per-group minimum/anchor rules, independent
principal claims, group-bounded atomic authority claims with exact indexed
failure attribution, and the shared `run_duration_ms` cap.
Capacity fixtures fill the Registry before activation and prove the
deadline-aware atomic reservation batch fails before the first store call with
no partially occupied slots; an expired request left in the Registry mailbox
cannot later reserve, and early authorization/preflight plus no-manager paths
release every unused reservation. A fake-clock interaction longer than a
narrowed `run_duration_ms` but shorter than its authorization timeout succeeds
and receives a fresh full ordinary run budget afterward; the inverse expires as
non-retryable `authorization_required`, never `run_timeout`.
Application-gate failure and fake-clock expiry precede activation admission,
map to `provider_application_unavailable`, and produce no reservation,
context/store call, listener, interaction, or URL output.
Trusted tenant/principal partition keys reach only the selected OAuth store
operations, never identity or output; two principals using one installation
remain distinct without claiming inbound authentication or hostile-tenant
isolation. Phase-7
audited-local checks run once per occurrence in the documented order and return
identical results in the internal doctor and run operations; workflow/mission
alias collapse occurs only after all occurrences pass. Public command wiring
belongs to commit 9. Failures through phase 7 prove zero credential
resolution/acquisition, phase 8 marks activity before active work, and dotenv
sentinels prove the mode-specific application gate does not implicitly load
credentials. Starting only `:ptc_runner` in a fresh VM starts the empty
command-core cleanup registry/worker supervisor but leaves both provider
applications absent from `Application.started_applications/0` until a marked
provider-bearing operation reaches the gate. A table-driven counting endpoint
returns `429`, which the pinned
ReqLLM version retries by default, across the retained adapter's plain-text,
structured-object, tool-call, and streaming constructors and proves each sends
exactly once with the shared `max_retries: 0` seal. This is distinct from the
commit-7 connectivity-probe transport and leaves no parallel constructor or
caller-controlled retry override.

### Commit 6. Provider resource ownership and cleanup

- complete the owner-backed shared `RunCoordinator.open_session/2` acquisition
  operation introduced by the command-engine boundary;
- complete successful provider-free execution routing through the shared engine
  using the same owner-backed session lifecycle and an empty resource handle;
- enforce the installed cleanup deadline with monitored closers and owned-tree
  termination through one owner-backed resource graph, including pending
  acquisition leases that roll back provisional roots;
- extend commit 5's sibling `ManagerCleanup.Registry` reservations into
  token-manager ownership: add deadline-aware token-manager close and the
  generation-acknowledged transition to autonomous deferred cleanup; bind a
  manager to its exact pre-reserved slot, release acquisition-failure and
  successful no-manager slots, add the persisted generation-acknowledged
  `clean_pending_exit` handshake, reconstruct reservations/monitors across
  Registry restart from the existing bounded non-secret ledger, release only
  proven clean deaths, and poison abnormal/unacknowledged manager exits; remove
  linked-worker ownership and the kill-and-`mcp_transport_error` fallback;
- remove raw-close-returning `ProviderRegistry.build/4`, and migrate direct
  embedding/E2E acquisition, `RunConfig`/`Kernel.run`, builder rollback,
  Runner, and REPL cleanup to the graph-requiring replacement; and
- add a sidecar lease only if concurrency tests demonstrate spend-before-run
  races that justify it.

**Gate:** construction/acquisition rollback, owner death, timeout, ordinary
completion, and concurrent runs all close each registered resource exactly
once in dependency order under the one deadline. No former direct
`ProviderRegistry.build/4` caller bypasses the owner. Cleanup failure has the
documented primary/secondary precedence and leaves no untracked worker or port.
OAuth fixtures cover clean close, response-persistence failure, per-run expiry,
successful pre-reserved transfer, atomic batch saturation before
context/store/resolver/manager work, partial-batch rollback, unused-slot
release, repeated bounded self-retry, and
owner/Registry/worker-supervisor death.
Crash-point tests cover reservation, manager registration, transfer intent,
generation acknowledgement, clean-state write before acknowledgement, clean
acknowledgement before manager exit, `DOWN` before ledger erase, Registry
reconstruction, and worker-supervisor restart. They prove a Registry crash in
either clean-exit window releases the slot after restart, Registry death
preserves every other ledger slot and monitor after reconstruction, and
abnormal autonomous-manager death poisons rather than releases its slot. An
unsettled manager is never force-killed; transfer remains classified as cleanup
failure, preserves the local fence, and keeps exactly one live retry owner until
an acknowledged clean exit or a fail-closed poisoned state.
When persistence settles after the original per-run cleanup deadline, the
autonomous manager uses fresh bounded acknowledgement-attempt deadlines,
survives Registry timeout/unavailability, retries, and eventually releases the
slot only after the exact clean generation is acknowledged and observed dead.
The current
6,000 ms token-manager close cannot overrun a narrowed/default 5,000 ms global
deadline, `cleanup_unavailable` never becomes `mcp_transport_error`, and no
post-creation transfer can fail for lack of capacity.
Internal-engine and direct-embedding provider-free success fixtures return the
exact schema-valid run outcome, exercise the empty resource handle, and prove
session cleanup completes.

### Commit 7. Bounded connectivity and doctor

- add the selected live-LLM adapter's single-attempt, deadline- and
  response-bounded real connectivity probe to the internal doctor-connect
  operation after the shared local/application boundary, checking every
  selected occurrence before collapsing success to the alias result;
- retain `MCPHTTPAdapter` as the shared facade while installing the capped
  passive `recv_up_to` boundary, strict response policy,
  decoded/retained-byte ceiling, and Mint/OTP/TLS conformance suite above; never
  ship parallel transports for one target;
- implement OAuth authorization doctor state and the exhaustive
  operation/provenance mapping table for required, rejected, unavailable,
  lifecycle/policy change, indeterminate mutation, just-in-time client-secret
  failure, authenticated rejection, and discovery/protocol failure without
  opening an interaction; keep doctor/session-opening projections distinct from
  the phase-10 `execution/provider_failed` override;
- make acquisition-backed OAuth doctor checks use the same one-principal,
  one-atomic-authority-batch context-group algorithm as ordinary activation,
  under group-minimum doctor occurrence deadlines;
- implement the declared `none`, `acquisition`, and `probe` connectivity modes
  and provider-specific authenticated/model-specific probe rules through the
  commit-6 resource owner and pending-lease API; and
- keep ordinary provider acquisition and ordinary runs free of the extra
  connectivity request.

**Gate:** the local counting-server and backend-conformance suite proves one
attempt, no redirect/decompression/retry, a single monotonic deadline, prompt
partial delivery, exact payload bounds, injection-safe request serialization,
compressed-expansion rejection, and every closed HTTP/protocol outcome.
It exercises the shipped `MCPHTTPAdapter` through the authoritative configured
capped receive boundary; active Mint and zero-length passive receives are
forbidden on this path.
Repeated workflow/mission occurrences are checked in deterministic order. The
default internal doctor operation performs no credential/network work, and the
connect variant sets activity before credential resolution while never
emitting a selector, endpoint, credential, or response body. Acquisition-backed
OAuth checks also prove no context/store call by default, distinct
authorization versus authentication diagnostics, no automatic interaction or
tool replay, grouped claim parity, and registered close/transfer/rollback
through the commit-6 owner. Dynamic OAuth failures are projected separately
through doctor, session opening/acquisition, and phase-10 execution, with the
last always using non-retryable `execution/provider_failed` for non-invariant
provider failures except when the binding run deadline correctly wins as
`execution/run_timeout`.
Commit 9 wires
these operations to the public `doctor` command without duplicating them.

### Commit 8. Destination preflight and terminal publication

- retain existing result/inspection/trace adapters behind the shared engine;
- preflight already knowable destination failures in phase 6 using the fixed
  trace/inspection/result order and terminal state table;
- reserve the deterministic owner-only private-output recovery artifact in
  phase 6, fill it after valid-result/cleanup success but before optional
  evidence publication, and retain it on any later failure;
- make final publication exclusive, no-clobbering, and private-trace-aware;
- preserve successful execution facts when later publication fails;
- withhold result/success artifacts on cleanup failure while retaining the
  terminal `provider_cleanup_failed` trace and authorized inspection evidence;
  and ensure every partial publication state is represented exactly.

**Gate:** internal validation and occupied-destination failures never invoke an
unverified builder; public `validate` wiring belongs to commit 9. Late
collisions never overwrite data, cleanup failure
publishes no result but can publish its terminal failure trace/inspection, each
partial publication state is reported, and a private-output result remains
recoverable after any post-recovery trace, inspection, or final-link failure;
private trace-directory publication is exclusive, mode `0600`, correctly
suffixed, and correctly classified by discovery. Fault injection covers every
write/link/sync boundary and proves invocation-owned cleanup never removes
pre-existing or unrecognized state.

### Commit 9. Focused shared commands and REPL parity

- implement JSON-envelope help, `validate`, and `run`, then `doctor`, `models`,
  and `init`;
- remove unconditional Mix `app.start` and make `Mix.Tasks.Ptc.Run` delegate
  to the shared parser/engine and mode-specific phase-8 application/runtime
  service gate, while explicitly ensuring the inert `:ptc_runner` command core;
- retain `--authorize-mcp` as a documented Mix-only interactive adapter: it
  performs no context/store/interaction work until the shared engine has passed
  destination and audited-local phases and marked provider activity; standalone
  parsing rejects the flag and never prints an authorization URL; preserve its
  repeatable argv order, reject duplicates and unselected/non-OAuth targets, and
  authorize multiple valid selected targets sequentially;
- keep manifest-backed REPL script/profile modes on the same directory package
  adapter and shared `prepare/2` plus `open_session/2` lifecycle, remove the
  REPL's unconditional `app.start`, and leave only its streaming
  parser/protocol distinct; manifest mode gains `--host-config`, rejects it in
  direct/profile modes, and provider-bearing manifests use that installation
  rather than an empty registry;
- require an attached interactive `--private-terminal` before a classified
  private manifest REPL evaluates anything, reject private `-e`/`--load`
  sessions, and remove the current private-result-to-stdout behavior; and
- regenerate the command/host schemas and update retained guides, examples, and
  shell journeys to the final names.

**Gate:** focused tests prove Mix/direct parser and engine parity for every
shared default, option, conflict, phase, and closed exit class without claiming
Mix process-stream purity; the one documented parser delta is the Mix-only
`--authorize-mcp` adapter, whose explicit interaction ordering and safe output
have separate fixtures. They cover duplicate rejection, missing/non-OAuth and
unselected-target rejection with zero store calls, and two valid selected
targets authorized in argv order before deterministic selected-provider
acquisition. Directory and memory fixtures run identically; a memory-backed
fixture whose application/file-artifact adapters raise on use succeeds when no
file-backed provider is installed. Standalone OAuth-bearing
`validate`, `models`, and default `doctor` remain non-active, while a selected
OAuth `run`/`doctor --connect` returns `authorization_required` after the marker
without a store call, token manager, or interaction. Mix explicit authorization
and a host-owned populated-store run activate only through
`ProviderRuntimeServices`. REPL manifest mode uses the
same prepare/acquire/cleanup lifecycle, and private REPL values never reach an
unauthorized stream. This commit adds frontend delegation only: it does not
reimplement the validation, run, doctor, or publication operations completed by
earlier commits.

### Commit 10. Standalone packaging and descriptor framing

- spike and install the standalone descriptor-3 envelope wrapper plus bounded
  stdout group leader and add the focused pinned
  Logger/SASL/explicit-stderr/direct-file-descriptor secret audit described
  above;
- package the same engine through the smallest proven OTP release/escript
  entrypoint;
- ship a minimal boot profile with implicit dotenv disabled and optional
  provider applications started lazily inside the activity boundary in
  standalone/Mix CLI mode, while the empty command-core OAuth cleanup
  supervisor starts eagerly and cloud embedding remains host-owned; and
- document stdout as the V1 machine stream, stderr framing as non-contractual,
  and stderr content on supported paths as secret-safe.

**Gate:** the first packaged V1 already satisfies the final schema, phase,
digest, privacy, and publication contracts from commits 1 through 9. Standalone
subprocess tests cover every command, malformed arguments, caught internal
failures, signal characterization outside V1, and ordinary
stdout envelope/schema validity. Descriptor survival, noninheritance,
broken-pipe, exit-status, startup-identity, and focused authority-audit tests
pass on every packaged macOS/Linux target or trigger the outer framing process.
Mix/standalone parser and engine parity covers every shared command, default,
option, conflict, phase, and closed exit class without changing Mix
process-stream semantics; the documented Mix-only authorization adapter is
excluded from standalone parity and tested independently.
A packaged default `doctor` neither starts provider applications nor consumes a
sentinel `.env`, and a clean environment runs the packaged command without a
repository checkout. Retained guides, examples, shell journeys, and generated
schemas use the released names and host contract; `mix ptc.gen_docs --check`
passes. Packaged OAuth-bearing static commands touch no store, and selected
OAuth execution returns the documented noninteractive
`authorization_required` envelope without creating a manager.

### Commit 11. Credentialed live-model and filesystem-free acceptance

- add one dedicated, bounded `:e2e` acceptance module for the completed stable
  command path;
- in the test harness only, load the repository `.env`, require
  `OPENROUTER_API_KEY`, honor optional `PTC_TEST_MODEL` only after resolving it
  to an OpenRouter-backed model admitted by the selected installation (otherwise
  fail the gate), and pass only the resolved environment entries or host-owned
  credential resolver into the system under test;
- prove the packaged `doctor --connect` performs its declared real
  authenticated/model-specific probe and returns the closed available result;
- execute one minimal real `llm/request` through the retained ReqLLM adapter
  through the packaged `run` command with strict run/provider/output-token
  deadlines and ceilings, asserting the contract shape, usage normalization
  when reported, resource cleanup, and absence of
  endpoint/model/credential/response data from public diagnostics and stderr
  rather than depending on stylistic model output;
- repeat the actual run through the host-owned in-memory
  `ApplicationPackage`/`ExecutionInput` path with application and file-artifact
  adapters that raise if invoked, proving the cloud execution path needs no
  application filesystem; and
- add a credential-free local OAuth MCP integration through that same
  host-owned memory package path, using an injected in-memory store and lazy
  tenant/principal context groups; prove two principals remain partitioned,
  aliases share a claim only inside an explicitly shared group, only selected
  authorities are claimed, no file adapter is invoked, and
  authorization/token-manager cleanup follows commits 5–7; and
- keep prompts domain-blind, configure all three operations for one attempt,
  cap their request and response size, and record only the selected safe model
  alias, closed outcomes, and pass/fail status in the PR evidence.

The parent test process may call `PtcRunner.Dotenv.load/0` once to obtain the
local credential, but it must not execute either acceptance path in that
already-marked VM. Spawn every child with an allowlisted environment that
explicitly removes inherited provider credentials. Pass the copied
`OPENROUTER_API_KEY` only to the packaged child; keep it absent from the
host-owned child's OS environment and supply it only through the host-owned
credential resolver. Pass the optional non-secret model override explicitly to
each child. Run both the packaged path and a small host-owned embedding runner
in fresh child VMs. In the host-owned child, require
`Code.ensure_loaded(PtcRunner.Dotenv)`, install a local call
trace pattern for exactly `{PtcRunner.Dotenv, :load, 0}`, assert the pattern
matched exactly one function, and enable call tracing for every existing
process plus descendants before invoking the runtime. After the runtime and its
owned processes quiesce, disable tracing, wait for an
`:erlang.trace_delivered/1` barrier, and fail if any matching call arrived.
Before starting provider applications, the paid host-owned child also sets both
`:req_llm` and `:llm_db` `:load_dotenv` flags to `false`, changes into an
isolated directory containing a self-tested unopened `.env` FIFO, and installs
exact matched local call traces for the pinned dependency's
`Dotenvy.source/1`, `source/2`, `source!/1`, and `source!/2` entrypoints. It
first requires `Code.ensure_loaded(Dotenvy)` and asserts that each trace pattern
matched exactly one function before starting either application. It proves
`OPENROUTER_API_KEY` is absent from the child OS environment before application
startup, after startup, and after the paid run; only the resolver holds the
copied credential. The FIFO subprocess deadline and all dependency trace
patterns remain active through application startup, and the same trace-delivery
barrier proves that neither project nor dependency dotenv code ran.

Use two separate credential-free startup guards in isolated directories before
the paid operations. One contains an unreadable regular `.env`, so an
unintended `PtcRunner.Dotenv.load/0` read fails; the other contains an unopened
FIFO named `.env` with no writer, so ReqLLM/Dotenvy-style `File.exists?` plus
read blocks and misses the subprocess deadline. The packaged guards use host
JSON to select the shipped `llm` descriptor, whose declaration names the real
`req_llm`/`llm_db` provider applications, and run a minimal packaged workflow
that installs but never invokes that capability. Its bounded host JSON supplies
one explicitly non-secret dummy literal credential while every real provider
credential remains scrubbed. The `run` command crosses the application gate,
completes selection and acquisition, executes the workflow, and returns a fixed
local value; assert both applications actually started before the standalone VM
exits and that the provider request counter remains zero. No custom descriptor
or test-only public injection path is involved. The
host-owned guards set both dotenv flags false, start
those real applications as the host while the traps are active, capture and
monitor the `ReqLLM.Supervisor` PID, and assert `:llm_db` remains in the
started-application set. Instrument the code-owned provider-application adapter
to prove the runtime issues no start/stop call for either host-owned
application. Thus the guards exercise real dependency startup without making a
provider request. Also omit
an independently generated credential sentinel from both the explicit
environment and resolver and prove it remains unavailable. Local absence of the
required real credential is a hard failure for the final live gate, not a skip.
Scheduled CI may supply the same credential directly as an environment secret.
Before using either trap on each supported macOS/Linux target, the harness
self-tests under the same UID that the regular file returns the expected access
failure and that a sacrificial FIFO reader remains blocked until explicitly
terminated. An ineffective or unavailable trap fails the target gate; it never
counts as evidence that dotenv was not read.

**Gate:** the focused live module passes with the locally available `.env`
credential and optional model override. Within that focused module, exactly
three single-attempt external provider requests are permitted: one packaged
connectivity probe, one packaged run request, and one host-owned memory-run
request. The startup guards make none. All three focused live requests stay
within their declared token, byte, and time ceilings and close resources; the
memory-backed run performs no application/file-artifact access; and credential
sentinels appear in no envelope, trace, inspection, log, or stderr capture.
As a separate gate, the documented scheduled/manual E2E harness then runs the
full `mix test --include e2e` suite with its required MCP fixtures and secrets.
That suite retains its own per-test request/turn ceilings and may make more than
the focused module's three requests; a skip caused by a missing live-model
credential does not satisfy either gate.

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
- OAuth-bearing `validate`, `models`, and default `doctor` with no provider
  activity, context construction, principal/authority claim, grant load, or
  claim-timeout latency; ordinary provider-free variants retain the same gate;
- optional provider-application startup failure mapping to
  `active_preflight/provider_application_unavailable`, with activity true and
  no credential resolution or acquisition attempted afterward; a hung startup
  is bounded by `activation_admission_deadline_ms`, has the same mapping, and
  creates no OAuth cleanup reservation;
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
- `doctor --connect` activity before the first credential, authorization,
  runtime-service, store, or connectivity attempt;
- OAuth activation-mode fixtures proving standalone `disabled` selected work
  returns `authorization_required` without a cleanup reservation or store call;
  marked `context_groups` activation rejects duplicate
  `{Store.local_identity(store), tenant_id, principal_id}` namespaces before
  context construction/store mutation, permits equal textual partition IDs for
  distinct mandatory store identities, shares one namespace only when aliases
  map to one group, and closes missing/malformed/raise/exit/timeout identity
  callbacks without pre-marker invocation; exact boundary fixtures accept
  arbitrary one- and 128-byte identities and reject empty and 129-byte values;
- Registry-capacity fixtures proving `reserve_many/3` reserves one slot per
  selected occurrence all-or-none before context/store/resolver/network work,
  reports saturation against the first OAuth alias with a null occurrence,
  leaves no partial reservations on failure, refuses an expired mailbox request
  without a late mutation, binds managers only to their assigned slots, and
  releases slots for authorization/preflight/acquisition failure and successful
  no-manager paths;
- Store command-catalog parity plus a valid-state fixture factory for every
  exported operation and mutating row, proving `%Store.Deadline{}` is propagated
  through wrappers, every read has the exact not-applicable/discard/none tuple,
  every mutation has an explicit remote-replay,
  post-dispatch-projection, and cleanup-action class, and an operation queued
  behind a blocked transaction rechecks its expired absolute deadline inside
  the serialized transaction without changing state;
  remote-mode test doubles delay request arrival past the local deadline and
  prove an adapter-authoritative guard rejects before commit while
  indeterminate-after-dispatch drives every mutation through its catalog
  projector and cleanup action without asserting unchanged state; this includes
  principal/authority claims, admissions/releases, flow and grant mutations,
  requirements/response fences, and both retirement families; an
  indeterminate-mode store with any catalog `authoritative_only` mutation is
  rejected as an invalid runtime specification before the activity marker or
  adapter call, and the source audit covers direct transaction-command
  construction/calls in coordinator, OAuth, cleanup, and adapter helpers;
  paired committed-before-deadline/lost-reply cases prove each operation retains
  its declared idempotent or indeterminate result rather than being mislabeled
  as a proven non-mutation;
- a slow OAuth store at `doctor_connectivity_timeout_ms: 100`, proving context
  creation, principal claim, authority claim, grant admission, and discovery
  share one occurrence deadline after the separately bounded application gate
  and activation admission and cannot each consume a fresh timeout; equivalent
  run and explicit-Mix-authorization fixtures prove their own active absolute
  deadlines reach every nested store call; a run with two aliases in one
  context group, a third alias in a distinct store/tenant/principal group, plus
  a repeated alias at three distinct normalized MCP timeouts proves per-group
  principal minima, deterministic anchors and equal-deadline tie-breaking,
  independent group claims, per-alias minima, separate atomic authority batches,
  per-occurrence acquisition deadlines, and the `run_duration_ms` cap; inject
  a principal-claim failure in each group and prove the exact anchored
  authorization subject has the anchored alias but a null occurrence and obeys
  first-failure order; inject a collision at a non-first indexed authority
  entry and prove the entire group batch remains unchanged and the diagnostic
  names that entry's lowest mapped alias with a null occurrence; prove a slow
  batch is capped by the group's shortest provider deadline even when that
  alias sorts last; paired
  fixtures make the run deadline bind (including an exact tie) and then the
  provider deadline bind, proving the former is
  `execution/run_timeout` with a null subject while the latter retains the
  exact selection-, authorization-, or acquisition-specific diagnostic and
  provider subject without restarting either clock; repeat that comparison for
  an active custom validator with no MCP timeout and make both its independent
  `selection_validation_timeout_ms` candidate and the run candidate bind;
- `doctor --connect` with two aliases sharing one context group, a repeated
  alias at distinct normalized timeouts, and a third alias in a separate group,
  proving one principal and atomic authority batch per group, group-minimum
  doctor occurrence deadlines, deterministic anchors/indexed failure
  attribution, null occurrences for shared claim failure, per-occurrence
  admission/discovery after setup, and no cross-group batch; static MCP and
  custom `acquisition`/`probe` occurrences prove the same common start time,
  doctor-only bound when no provider timeout exists, and minimum rule when one
  does, without entering OAuth grouping; active validators are additionally
  narrowed by `selection_validation_timeout_ms`, all validators complete before
  the once-per-alias credential barrier, and repeated workflow/mission aliases
  resolve one credential under their minimum occurrence deadline without
  resetting it; a credential-only custom provider with
  `connectivity_mode: none` resolves under the original doctor-phase deadline
  despite omitting connectivity, and its slow resolver is terminated with the
  same alias-wide non-retryable `credential_unavailable`; a later validator
  failure proves zero credential reads. Slow validator and resolver fixtures
  make the doctor deadline bind first on both acquisition and probe paths,
  prove worker-tree termination, null occurrence for the alias-wide credential
  subject, and retain the non-retryable `selection_validation_timeout` and
  `credential_unavailable` projections rather than retryable connectivity
  failure;
- explicit Mix authorization fake-clock fixtures in which interaction exceeds a
  narrowed `run_duration_ms` but remains inside
  `authority.authorization_timeout_ms`, then receives the complete ordinary run
  budget after authorization; reverse the bounds and prove authorization expiry
  uses non-retryable `authorization_required` rather than `run_timeout`, with
  unused cleanup reservations released in both failure paths; timeout before
  token dispatch cancels the listener/worker and pending flow, while
  possibly-dispatched mutation preserves its fence and cancellation/registered
  root failure follows cleanup precedence; fail the provider-application gate
  and prove it precedes admission with no reservation, context/store call,
  listener, interaction, or Mix-shell URL output;
- OAuth doctor/run fixtures proving missing grants map to non-retryable
  `authorization_required`, explicit denial to `authorization_rejected`,
  store/context availability failures to retryable `authorization_unavailable`,
  just-in-time confidential-client secret failure to `credential_unavailable`,
  and remote authenticated rejection remains distinct; standalone opens no
  interaction, while explicit Mix interaction occurs only after destination
  and audited-local success; repeatable Mix authorization rejects duplicate,
  missing, non-OAuth, and unselected targets before a store call, then processes
  two valid selected targets in argv order; the table covers every store reason,
  including
  retiring lifecycle states, authority collision, stale epochs, invalid runtime
  shape, and not-dispatched versus possibly-dispatched refresh/code failures,
  with no fallback to a retryable classification; run every applicable dynamic
  store/header/refresh/`401`/`403` outcome through doctor, session
  opening/acquisition, and a phase-10 MCP invocation, proving the first two use
  the exhaustive pre-execution rows while phase 10 uses non-retryable
  `execution/provider_failed` with the exact execution occurrence; dynamic
  phase-10 timeout fixtures separately make the intrinsic provider deadline and
  the run deadline bind, including an exact tie, proving the former is
  `provider_failed` with the occurrence and the latter is `run_timeout` with a
  null subject; dynamic OAuth `401` and valid satisfiable `403
  insufficient_scope` install their local
  fences before either projection; valid-but-unsatisfiable and malformed challenges,
  dynamic authentication rejection, and malformed-success versus well-formed
  endpoint rejection each exercise their one exact catalog row; static-auth
  `401`/`403` fixtures separately prove connectivity, acquisition, and execution
  classification with the matching subject operation;
  response-transition persistence failure separately proves the closed
  doctor, acquisition, and execution mappings plus mandatory cleanup/transfer;
  expire doctor during settled observational discovery and prove retryable
  `connectivity_unavailable`, then expire after possibly dispatched refresh/code
  mutation and during fenced response persistence and prove the respective
  non-retryable `authorization_required` and `connectivity_outcome_unknown`
  projections survive manager transfer;
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
  behavior rather than relying on server chunk timing; the
  `MCPHTTPAdapter` capped passive TCP and packaged TLS conformance proves the
  configured hard transport-ingress bound, prompt partial delivery,
  peer/hostname/SNI/ALPN behavior, and total deadline. It also proves that this
  path performs no active Mint or zero-length passive receive and that
  `recv_up_to` never exceeds its requested maximum or deadline. Request
  serialization tests accept `/v1/chat/completions` and a canonical
  `Authorization: Bearer <credential>` field, percent-encode admitted path
  segments exactly once—including a base-path `%20` fixture that must not
  become `%2520`—and reject invalid percent triplets, decoded slash/backslash,
  raw spaces, CR/LF, NUL, other controls, or fragments in the target plus
  invalid header-name or header-value bytes in declared headers and resolved
  authorization before any bytes are sent;
- the commit-11 credentialed live acceptance, with the parent test harness
  loading `OPENROUTER_API_KEY` and optional `PTC_TEST_MODEL` from `.env` before
  execution, rejecting an override that does not resolve to an admitted
  OpenRouter-backed model, spawning allowlisted child environments that scrub
  inherited provider credentials, proving one real packaged `doctor --connect`, one
  bounded real packaged `llm/request` through the retained ReqLLM adapter, and
  one host-owned filesystem-free memory run whose credential exists only in its
  resolver; exactly three single-attempt provider requests are permitted within
  this focused module; separate zero-request packaged and fresh-VM host-owned
  guards start or reuse the real declared `req_llm`/`llm_db` applications and
  use an exact matched BEAM call trace with a delivery barrier, an unreadable
  regular `.env`, and an unopened `.env` FIFO to catch both project and
  dependency dotenv reads; every paid request has explicit token/byte/time
  ceilings, missing credentials fail rather than skip this acceptance, and
  credential sentinels appear in no public or captured channel;
- a credential-free local OAuth MCP run through the host-owned memory package,
  injected in-memory stores, and lazy context-group specifications, proving no
  application/artifact file adapter use, selected-only authority claims,
  explicit same-group sharing, distinct store/tenant/principal partitions, no
  public group/partition/grant material, and bounded token-manager
  close/transfer; these local requests are outside the exactly-three paid
  OpenRouter request count;
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
- successful, failed, raised, and hung observational `doctor --connect`
  acquisition with settled authorization state proving
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
- OAuth response-persistence fixtures at every side of the cleanup deadline,
  proving a clean manager writes and receives acknowledgement for
  `clean_pending_exit` before exiting and releases its pre-reserved slot, an
  unsettled manager transfers exactly once without being killed, transfer
  preserves cleanup failure/result withholding, the manager itself retries
  bounded attempts, a worker-supervisor kill/restart neither kills nor
  duplicates that owner, Registry death/restart reconstructs all reservations
  from the non-secret ledger before admission, crashes after the clean-state
  write/before acknowledgement, after acknowledgement/before manager exit, and
  after clean `DOWN`/before erase all recover and release exactly once, abnormal
  or unacknowledged manager death leaves one poisoned occupied slot with no
  replacement or fence relaxation, and
  persistence that settles only after the original per-run cleanup deadline
  starts fresh bounded manager-owned acknowledgement attempts, survives at
  least one Registry timeout/restart, and releases the slot only after the exact
  generation is acknowledged and observed dead; prove 128 occupied registry
  slots make the next activation return
  `authorization_unavailable` before manager/store/network work; inject the
  former `cleanup_unavailable` branch and prove it cannot become
  `mcp_transport_error` or leave an ownerless manager; inject crashes at every
  reservation/registration/transfer acknowledgement boundary and prove the
  generation handshake yields either the original owner or exactly one
  autonomous manager;
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
  `prepare/2`/`open_session/2`, does not execute the workflow while opening,
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

- an HTTP service, job queue, inbound tenant authentication, adversarial tenant
  isolation, service cancellation, scheduling, or concurrency quotas; it does
  preserve trusted host-supplied OAuth tenant/principal partition keys and the
  store's existing logical separation contract;
- an adversarial same-user/same-VM security boundary;
- manifest-defined provider installations, URLs, filesystem roots,
  credentials, commands, or callbacks (manifests still select installed
  aliases);
- a remote/streaming application-source protocol;
- a general object store or active trace persistence service;
- a shipped durable OAuth token store or standalone authorization interaction;
  [`mcp-oauth-durable-store.md`](../future/mcp-oauth-durable-store.md) remains
  adapter-triggered;
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
`RunBuilder`, `ProviderRegistry`, `MCPOAuth.Store`, `MCPHTTPAdapter`, strict
schemas, confined reads, result classification, and artifact modules provide
the necessary primitives. The existing registry boundary is not itself
sufficient: it must be split into inert `InstallationCatalog` declarations and
lazy execution-scoped `ProviderRuntimeServices`, and OAuth cleanup must gain
pre-reserved ownership transfer. The other main refactors are preserving typed
error provenance, making phase order explicit, and replacing path-coupled
manifest state with a sealed document closure.

The transport-neutral package should be done now, not postponed until a cloud
service exists. It is small enough to define without choosing object storage,
IAM, or tenancy, and it prevents the CLI directory layout from becoming the
runtime API.

The generalized artifact store should wait. A cloud frontend can authenticate
and fetch documents, construct the bounded in-memory request, supply an inert
installation catalog plus execution-scoped runtime services carrying its
trusted tenant/principal partition and credential resolver, execute without
application or file destinations, and persist the classified outcome inside
its own boundary. The
BEAM code still comes from its release/container image, and any selected
file-backed credential or provider remains host responsibility. This supports
the stated application-filesystem-free direction without pretending this
library plan is a complete hosted-service security design.
