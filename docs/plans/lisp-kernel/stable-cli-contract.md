# Stable CLI and transport-neutral application plan

**Status:** accepted; Checkpoints A and B are complete, Checkpoint C's
stabilization prefix is merged, and the remaining work continues through
follow-up PRs.
**Revised:** 2026-08-06 after the Checkpoint C stabilization prefix merged, to
record that prefix as delivered and make doctor completion the active work.

This plan delivers a stable command-line contract and a path-free execution
core without designing infrastructure for a future hosted service. Exact
durable contracts belong in module documentation, retained guides, generated
schemas, and conformance tests. This file records implementation boundaries,
delivery order, and explicit deferrals.

## Goal

Deliver one shared Elixir command implementation for Mix and a standalone
executable with:

- stable, privacy-safe JSON command envelopes;
- explicit phase ordering and a monotonic provider-activity marker;
- filesystem and in-memory application acquisition through the same sealed
  request;
- deterministic content and effective-application identities;
- bounded provider-session work after the explicit application-bootstrap
  exception, plus bounded execution, cleanup, and artifact publication;
- `help`, `version`, `validate`, `run`, `doctor`, `models`, and `init`;
- no application path in the execution core; and
- a codebase small enough for one maintainer to understand and change.

This is a 0.x library. Remove obsolete paths instead of adding compatibility
layers.

## Maintainability budget

These are design constraints, not aspirational metrics:

1. There is one provider-session owner, one cleanup stack with one provisional
   root registrar, one deadline type, one supported OAuth store model, and one
   shared provider activation prefix.
2. Pure preparation is separate from effectful session opening.
3. The shipped implementation supports process-local OAuth only. Remote-store
   semantics are deferred until a real remote adapter exists.
4. Provider applications are host/process resources. A command may ensure that
   an optional application is started, but does not reconstruct exact prior OTP
   application state or stop shared applications at command exit.
5. Resource cleanup is owner-backed and process-local. It is not a durable
   crash-recovery journal.
6. Prefer transition tables and small data types over interacting flags.
7. Aim for fewer than 500 lines in an orchestration module. Crossing that size
   requires splitting a cohesive pure component or simplifying the state
   model, not adding another facade.
8. Aim for fewer than 1,500 changed lines in one review. A slice may be split
   into several coherent commits to stay within this budget.
9. Tests cover public transitions, ownership, and failure boundaries. Do not
   mirror every private branch with implementation-shaped unit tests.
10. Each checkpoint deletes the transitional path it replaces once all callers
    and tests use the replacement. Do not defer known-dead integration
    scaffolding to the final acceptance slice.

## Existing foundation

The runtime already provides the evaluator, bounded workers, provider
registry, confined reads, artifact formats, strict validators, an in-memory
OAuth store, and a bounded MCP HTTP adapter. This plan composes those pieces;
it does not introduce another evaluator, HTTP stack, general artifact store,
or service supervisor.

Completed commits on `codex/stable-cli-contract`:

| Slice | Commit | Result |
| --- | --- | --- |
| 0 | `dff98698` | Bundle hashes include canonical dependency edges. |
| 1 | `1784f0d2` | Sealed, transport-neutral run requests and content identity. |
| 2 | `2f3d028d` | Closed command preparation, diagnostics, and envelopes. |
| 3 | `8e2d4a6a` | Closed generated limit catalog. |
| 4 | `1af044ac` | Inert provider declarations and effective identity. |
| 5a | `b51804e4` | Shared absolute-monotonic deadline type and migrated provider activity. |
| 5b | `325d0195` | Process-free catalogs and sealed runtime activation. |
| 5c1 | `dab44224` | One provider-session owner with scoped, bounded LIFO cleanup. |
| 5c2a | `6a66eb71` | Bounded scoped process-root admission and terminal handoff. |
| 5c2b | `bdf80865` | Shipped process and port roots use scoped registration. |
| 5d1 | `3ef0e99d` | Active selection validation runs in bounded registrar scopes. |
| 5d2a | `7aa93376` | Active sessions admit selected optional applications. |
| 5d2b | `8f89175a` | Mix commands use the active boundary and explicit provider startup. |

Commit `1af53948` refreshes the semantic projection after 5d2a. The plan-only
commit that records Checkpoint A follows 5d2b and does not alter its runtime
boundary.

The first local implementation of slice 5, `d38d0bef`, is intentionally not a
delivery milestone. It demonstrated useful failure cases but combined remote
store theory, OTP application reconstruction, cleanup reservations, provider
preflight, authorization, and acquisition into 14,000 changed lines. Replace
it before pushing.

## Architecture

### Pure preparation

`RunCoordinator.prepare/2` consumes only a sealed `RunRequest` and inert
`InstallationCatalog`. It validates and compiles the application, normalizes
provider selections, classifies the flow, narrows limits, and produces a sealed
`PreparedRun`.

Preparation does not:

- resolve credentials;
- construct an OAuth context or call an OAuth store;
- start a provider-owned OTP application, process, port, or socket;
- invoke provider callbacks; or
- publish an artifact.

Consequently, failures through destination preflight report
`provider_activity: false`. Preparation may still use the existing bounded
internal validation and compilation workers; those are safety boundaries, not
provider activity.

### One provider session

After phase-6 destination authorization, `RunCoordinator.open_execution/2`
starts one `ExecutionSessionOwner` and its authorized sinks, runs every
applicable audited-local phase-7 check while provider activity is still false,
then either returns the provider-free owner or atomically marks activity and
opens its one `ProviderSession`. Run, REPL, and both doctor modes use this same
opening operation; no frontend or `CommandEngine` path runs a local callback or
opens a sink independently.

The provider session is the sole owner of active provider work for that
command. After the marker it:

1. ensures required optional provider applications are available;
2. performs the optional Mix authorization subphase and prepares its selected
   OAuth authorities in one execution-scoped context;
3. starts the run or connectivity operation deadline;
4. runs active selection validation;
5. resolves ordinary credentials once per selected alias;
6. prepares selected OAuth authorities under the operation deadline when the
   authorization subphase did not already prepare them; and
7. branches once by operation: a run acquires provider resources in dependency
   order; `doctor --connect` probes `:probe` occurrences, performs bounded
   acquisition and discovery for `:acquisition` occurrences, and skips `:none`.

Both branches use the same validation, credential, OAuth, deadline, diagnostic,
and ownership prefix. Every acquired run, acquisition-backed connectivity, or
temporary probe resource registers its close operation immediately on the same
LIFO cleanup stack.

An active callback receives the session's scoped `ResourceRegistrar` and its
private signal owner. Every shipped or trusted custom adapter starts process
and port roots with that owner; the process root must monitor the owner before
its init callback synchronously registers itself with the registrar's private
controller, and any port must be owned by one of those registered processes.
The controller gates registration into one authoritative cleanup owner;
terminalization handoff and cleanup reach that owner directly if the gate
stalls. The start operation returns only
after that handshake; later registration is unsupported. The root remains
provisional until acquisition returns and attaches its idempotent closer.
Callback failure, exit, or timeout terminates the callback worker and drains the
registrar scope, force-closing every provisional root without depending on a
builder first returning a close function. This is an in-memory ownership
handshake, not a lease ledger or restart journal.

Execution and `doctor --connect` use the same session boundary. Provider-free
commands never open one.

`RunCoordinator.execute/2` is the sole one-shot composition for phases 7–11. It
opens the execution owner, invokes the Kernel or active doctor operation when
applicable, guards and classifies the result, closes the provider session and
applies any cleanup failure, and only then finalizes terminal events before
returning one path-free execution outcome. Command frontends add only phase-12
publication and envelope projection. A REPL is the one explicit alternate
consumer: it opens an execution owner once and performs repeated evaluations
before the same close path.

The `ExecutionSessionOwner` owns the canonical `EventSink`, optional
`InspectionSink`, and, after phase 8 begins, the `ProviderSession`. It starts
the sinks after destination authorization and before phase-7 checks so failed
opening, one-shot execution, and REPL execution share one event lifecycle.
Failed session opening and caller death run the same bounded provider cleanup,
finalize the sinks once, and stop them. One-shot execution keeps this owner for
the whole operation. A REPL atomically transfers the owner handle from its
opener to `ReplSessionOwner` before the session is returned; the sinks then
survive every evaluation and finalize only when that owner closes or dies.
There is no frontend sink-cleanup path, and an immutable one-shot `RunConfig`
is never reused as a lifecycle owner.

The caller monitors the session and the session monitors its caller. Each scope
has one private registration controller, one authoritative cleanup owner that
monitors its admitted roots, and one signal owner that those roots monitor. The
controller forwards registration into the cleanup owner; terminalization
handoff and session cleanup address that owner directly and do not depend on a
responsive controller. Normal close and caller death both initiate bounded
reverse-order cleanup. Each resource implementation remains responsible for
making its close operation idempotent. After its closer runs, the cleanup owner
stops the signal owner so cooperative roots can terminate normally, then
force-kills survivors at their fair cleanup cutoff. Delayed `DOWN` observation
continues only in a separately bounded tail. Cleanup failure is classified and
reported; no registry attempts to reconstruct cleanup after the runtime VM
dies.

### Runtime services

`ProviderRuntimeServices` is a sealed execution-scoped value supplied only
when opening a session. Its first delivery contains:

- a lazy runtime-activation callback;
- a bounded credential resolver;
- an opaque keyed binding to the host document that produced it; and
- OAuth mode, either `:disabled` or one lazy process-local context factory.

Add provider application mode, either `:host_owned` or `:command_vm`, in the
same commit that adds the application gate which consumes it. Do not carry an
unused mode through preparation merely to complete the eventual type early.

The value contains no filesystem path. Constructing it performs no provider
activity. A CLI adapter may resolve environment, confined-file, or validated
literal credential declarations. An embedding may resolve credentials from
its own trusted service.

For the transitional host adapter, the lazy activation and credential
callbacks capture only one authenticated, process-local encrypted host payload.
They do not retain a plaintext host document, path, or credential declaration.
Generic service construction cannot mint the keyed host binding, and a
host-bound catalog rejects activation that does not return a valid private host
authority.

Slice 5 removes the current live `HostInstallationOwner` from catalog
construction. `InstallationCatalog` retains only sealed declarations and
process-free, path-free implementation recipes. Host recipes retain only an
alias and opaque host binding; path-bearing installation data, the credential
resolver, and any live authority they need stay in `ProviderRuntimeServices`
and are activated only inside the marked session. Host-backed provider-free
commands and failures before phase 8 therefore create no catalog process.

Until `ProviderSession` owns equivalent revocation, runtime activation starts
the existing private `HostInstallationOwner` only while opening a registry and
transfers that authority directly to the registry. Registry close therefore
still revokes retained builders and credential access. Delete that owner only
in the commit that replaces its lifecycle; an intermediate no-op close is not
an acceptable simplification.

Host-bound activation runs synchronously in the caller and is an explicit
exception to the per-command deadline, on the same terms as application
bootstrap. Only `from_host_payload/2` can seal a runtime binding, so that
branch runs exactly one code-owned step: decrypt the sealed host payload, then
start the private owner and its credential lease. It reaches no
embedder-supplied callback, file, socket, or network, and its input is bounded
by the confined read ceiling every command-loaded host document passes through.
An embedding that constructs a `HostConfig` without that loader owns the bound
itself.
The operation deadline is checked immediately before that step and rechecked
after it, so an expired operation releases the resulting authority instead of
returning a usable registry. The residual non-guarantee is explicit: a
pathological activation delays the command past its deadline rather than being
cancelled.

All selected OAuth aliases in one command use the session context. Authority
identity still distinguishes aliases and grants. A future host needing several
tenant partitions opens separate sessions; the stable CLI does not need
context-group routing.

### Deadlines

Use one small absolute-monotonic `Deadline` type with `new/1`, `remaining/1`,
and `expired?/1`. Passing a deadline through nested work never resets it.

The in-memory OAuth store checks the caller deadline before submitting a
request and again inside its serialized mutation before changing state. A
queued request whose deadline expired does not commit. No generic remote-store
contract, possibly-dispatched result algebra, replay catalog, clock
translation, or store-local identity protocol is part of this plan.

Provider application admission, authorization interaction, a run, and each
doctor connectivity operation may have different top-level deadlines because
they are different user operations. Each bounded nested operation may also add
an intrinsic absolute deadline: active selection validation uses its installed
validation limit, and provider work uses the selected provider's normalized
timeout when it has one. Work receives only the minimum effective deadline; it
does not retain candidate or exact-tie metadata. If that deadline expires, the
closed diagnostic comes from the operation class executing at expiry, regardless
of which candidate supplied the minimum. Kernel evaluator work reports
`run_timeout`; a provider capability call during Kernel execution reports the
closed provider-execution diagnostic; active selection validation reports
`selection_validation_timeout`; and credential, OAuth, acquisition, and doctor
connectivity work retain their respective closed operation diagnostics. This is
an intentional coarse diagnostic contract: candidate order and exact ties do
not change the code. Passing a deadline through nested work may narrow it but
never resets it.

For an ordinary run or doctor operation, shared OAuth context construction,
principal claim, and authority-claim batch use the minimum intrinsic deadline
across all selected OAuth occurrences in the session, intersected with the
applicable top-level deadline. Alias ordering therefore cannot choose or extend
the shared bound, and no candidate-attribution state is required.

For a Mix run with explicit authorization, phase 8 first creates one
`authorization_setup_deadline` from the minimum configured
`authorization_timeout_ms` among the selected OAuth aliases, before lazily
constructing the shared context. The effective setup deadline is the minimum of
that deadline and every selected OAuth occurrence's intrinsic deadline, all
anchored when setup begins. `Context.new`, its principal claim, and one
authority-claim batch containing all selected OAuth aliases use that effective
deadline without resetting it. After setup, each requested target in argv order
receives a fresh top-level authorization deadline for its discovery, listener,
interaction, exchange, and commit. The
ordinary `run_deadline` is created only after every requested interaction has
finished and before active selection validation or ordinary credential
resolution, so browser time does not consume `run_duration_ms` but all ordinary
provider preflight does. A run without explicit authorization creates
`run_deadline` at that same point; its validation, credential resolution,
context construction, principal and authority claims, grant work, acquisition,
and Kernel execution all consume that same run budget. Reusing the context never
renews any claim or operation deadline. `doctor --connect` follows the same
post-application ordering under its own connectivity deadline and never opens
an interactive authorization subphase.

Cleanup is a separate terminal operation with the installed
`provider_cleanup_timeout_ms`. The session creates exactly one absolute cleanup
deadline when it first transitions to cleanup, whether because of normal close,
operation timeout, or caller death. Every closer receives only that deadline's
remaining duration; no closer creates a fresh budget. Before each LIFO entry,
the owner reserves a fair slice of the remaining global duration for every
still-unattempted entry and runs the current closer in a monitored worker capped
by that slice. Thus a hung closer is terminated without starving later
callbacks, every registered callback is attempted in reverse order, and no
callback extends the one absolute cutoff. At global expiry the owner forcibly
closes every still-registered process/port root and reports
`result_cleanup/provider_cleanup_timeout`; ordinary close failures retain their
catalogued precedence. The sole exception is an OAuth terminalization root that
has atomically stopped accepting work and retained an unacknowledged admission
release or response-persistence fence. `MCPRequestContext` keeps its opaque
release and bounded retry owner after caller death; an unsettled token manager
is adopted by the bounded cleanup owner. Only after that adoption
does the registrar hand the root out of its scope owner's force-close set. Those
roots remain live and fenced until their terminal operation acknowledges, and
are never converted to successful cleanup by the handoff.

Request-context cleanup first atomically closes the context to new admissions,
then confirms token-manager adoption and registrar handoff, and only then waits
for retained releases. This order transfers both roots before a bounded closer
can time out when release and persistence are unsettled together. The scope
cleanup owner serializes handoff against cleanup: a completed handoff cannot
enter the force-close set. On abnormal session death it continues accepting
terminal handoffs directly during the cooperative owner-down window, then seals
the set when the force-close cutoff begins and rejects later
handoffs. Failure to adopt a manager remains distinct from loss of its scope
after adoption, so callers never kill an already supervised persistence retry.

### Optional provider applications

`:host_owned` is for long-lived embeddings and hosts that intentionally start
provider applications. It requires the application to be running and makes its
safe configuration and lifecycle a host responsibility. Command code does not
infer safety from application configuration or attempt to prove how an
inherited instance started.

`:command_vm` is the default when one command invocation owns its VM: a normal
one-shot `mix ptc.run`, the fresh standalone VM, or one manifest-backed Mix REPL
that opens exactly one provider session for its whole lifetime. After the
session atomically marks provider activity, it rejects an already-running target
because its startup provenance is unknown, sets both `:req_llm` and `:llm_db`
`load_dotenv` application flags to `false`, and only then calls
`Application.ensure_all_started/1`. Setting one flag is insufficient because
either optional application may otherwise consume ambient `.env` credentials
before the explicit resolver runs. The command never stops the application
independently of VM shutdown. The check and every configuration mutation occur
after the marker transition succeeds, so rejection uses the existing
`active_preflight/provider_application_unavailable` diagnostic with
`provider_activity: true`. A long-lived or repeated in-VM caller must arrange
safe startup and use `:host_owned` rather than reuse `:command_vm`.

The Mix frontend makes that ownership choice per invocation. It uses
`:command_vm` while the shipped provider application is stopped and treats an
already-running application as host-owned. A provider application started by
one Mix invocation can therefore be reused by a later invocation in the same
VM, while a fresh one-shot command still configures and starts it only after
the provider-activity marker.

The optional application and its background processes are VM-owned, not
session-owned. Session close and caller death close only resources acquired by
the session; application processes end when the one-shot command VM exits.
Accordingly, `:command_vm` is valid only when the frontend owns the command VM
lifetime. A provider-backed REPL reuses its single session rather than opening
one per evaluation, and VM shutdown follows REPL close. It does not promise
per-session application rollback. Embeddings or REPL hosts that reuse a VM
across command invocations must prestart providers safely and use `:host_owned`.

The shared parser handles phase-1 help and version before either the Mix adapter
calls `Mix.Task.run("app.start")` or the standalone wrapper boots the command
core. Other commands may start `:ptc_runner` only after phase 1. Slice 5 removes
every optional provider application from the core OTP application's inferred
startup set, not merely from `extra_applications`: optional runtime dependencies
are otherwise still listed in generated application metadata. The existing
bounded `MCPOAuth.ManagerCleanup` remains command-core infrastructure: it starts
empty, performs no store or provider work, and is the terminal owner only for a
token manager whose response persistence could not settle during session
cleanup. Removing it is deferred until a separately reviewed
replacement can preserve those fences. Provider application startup is delayed
to `:command_vm` after the marker. Regression tests prove help/version do not
start the core or scan semantic-revision dependency files, and provider-free
core startup starts neither an optional provider application nor a token
manager or cleanup worker.

OTP application startup is not cancellable and `Application.ensure_all_started/1`
has no timeout. V1 therefore makes application bootstrap an explicit exception
to the per-command deadline instead of wrapping it in a worker and claiming a
false bound. A stuck application callback may require terminating the
standalone VM. After startup returns, every provider-session operation is
bounded normally. If a supported deployment requires bounded bootstrap, that
is a concrete trigger for the outer process supervisor. The implementation
does not call private `:application_controller` protocols, snapshot controller
state, keep startup provenance ledgers, or reconstruct prior state.

### Provider adapters

Provider declarations remain inert. Effectful implementations expose the
smallest operation needed by the declared mode:

- active selection validation;
- optional connectivity probe; and
- acquisition returning capabilities plus an idempotent close operation.

Shipped adapters translate their native errors into the closed diagnostic
catalog at their boundary. The coordinator orders operations and deadlines; it
does not know adapter internals.

Phase-5 preparation never invokes a local callback. `validate` and `models`
stop after inert declaration work. Default doctor may invoke only the shipped,
code-owned `:audited_local` callbacks in phase 7; those may inspect decoded
configuration and loaded adapter/executable availability, but may not resolve a
credential, start an application/process/port, contact a provider, or perform
network work. Only a shipped source in a host-bound catalog may declare
`:audited_local`, and both constructors enforce that rather than trusting the
declaration. A custom `:unverified` callback is active work: default doctor
reports that an active check is required, while run and `doctor --connect`
invoke it only after the phase-8 marker under the session deadline.

### OAuth

Standalone V1 has OAuth execution disabled. It may validate and list inert
OAuth declarations. A selected OAuth provider in `run` or `doctor --connect`
returns `active_preflight/authorization_required` after activity is marked and
without opening an interaction.

`mix ptc.run --authorize-mcp NAME` remains the only shipped interactive path.
Names must be unique, selected, OAuth-capable aliases. Authorization occurs in
argv order after destination and audited-local checks and before provider
acquisition. The process-local store and resulting context are shared with the
immediately following run in the same Mix invocation. Each interactive target
gets the absolute interaction deadline described above.

Token refresh and response-driven authorization fencing retain their existing
atomic store semantics. Simplification must not weaken principal/authority
partitioning, scope checks, bounded interaction, or the guarantee that an
expired queued mutation does not commit.

A settled request context and token manager close with the session. If an
admission release remains unacknowledged, `MCPRequestContext` first atomically
enters its existing closed-to-new-work state and retains the opaque release for
bounded asynchronous retries. If response persistence remains unacknowledged,
the session atomically adopts that still-live manager into the existing bounded
`MCPOAuth.ManagerCleanup` supervisor. Either case reports cleanup failure before
the handoff; neither discards a local fence, reports the failed command as
successful, or allows possibly spent authority to be reused. Caller death may
therefore leave only an explicitly self-owned/adopted terminalization root,
never an unowned one. This is the sole exception to the general rule that
session-owned processes are gone after cleanup.

### Command engine and frontends

There is one argv grammar and one `CommandEngine`. The engine owns frontend
concerns: argv, path-backed acquisition adapters, destination preflight,
publication, and envelope rendering. It returns a closed outcome and never
halts the VM.

The Mix adapter prepends the fixed `run` command and permits the documented
Mix-only authorization option. The standalone wrapper alone writes the exact
process streams and exits. Its durable process contract is specified in
[Running and debugging](../../guides/running-and-debugging.md#stable-standalone-process-contract).
The existing REPL JSONL stream remains a distinct protocol but uses the same
preparation and provider-session boundaries.

The command surface is:

```text
ptc --help
ptc help [COMMAND]
ptc COMMAND --help
ptc --version
ptc version
ptc validate ptc.json [--host-config HOST.json]
ptc run ptc.json [--host-config HOST.json]
    [--input INPUT.json | --private-input INPUT.json]
    [--trace-dir DIR]
    [--output PATH | --private-output PATH]
    [--inspect PATH]
    [--component-override-descriptor PATH]
ptc doctor [ptc.json] [--host-config HOST.json] [--connect]
ptc models --host-config HOST.json
ptc init DIRECTORY
```

Remove `--mission`, `--private-mission`, `--trace PATH`, and `run --check`.
Do not add compatibility aliases.

`help` and `version` finish during argument handling without opening files,
starting the command core, or performing provider activity. `validate` and
`models` use only inert declarations. Default `doctor` may additionally run the
constrained audited-local checks above; it never invokes an unverified callback.
`doctor --connect` requires both application and host configuration and uses the
exact selected provider occurrences and narrowed limits.

### Phase order

The stable order is executable and externally observable through the phase and
activity fields:

| Phase | Work | Provider activity allowed? |
| --- | --- | --- |
| 1 | Parse argv; handle help/version | No |
| 2 | Acquire and validate host configuration | No |
| 3 | Acquire and validate application/input | No |
| 4 | Compile bundles and resolve dependency graph | No |
| 5 | Normalize selections, limits, flow, and identity | No |
| 6 | Preflight requested destinations | No |
| 7 | Run audited-local declaration checks | No |
| 8 | Mark activity; open provider session | Yes |
| 9 | Execute Kernel or active doctor operations | Yes |
| 10 | Validate and classify the result | Yes |
| 11 | Close provider session in reverse order | Yes |
| 12 | Publish authorized artifacts and terminal envelope | No new activity |

For provider-free commands, phases that do not apply are skipped without
opening a session. Once activity is true it never becomes false, including on
failure.

### Identity and privacy

The completed content/effective identity contracts remain authoritative.
Provider activity and runtime-captured acquisition identity may add only the
already documented safe projections. Never publish credentials, OAuth issuer,
client, scope, redirect, tenant, principal, store data, filesystem paths,
private input/value, arbitrary exception terms, raw model selectors, or raw
provider responses.

All command outcomes use the checked-in V1 envelope schema. Diagnostics use a
closed phase/code/source/subject catalog and safe bounded messages. A frontend
does not inspect arbitrary Elixir terms into public output.

### Publication

Destination authorization completes before provider activity. Execution code
receives sinks/capabilities, not destination paths.

Keep the existing publication requirements:

- exclusive creation; no overwrite or symlink following;
- owner-only permissions for private output and private traces;
- generated normal traces named exactly `<run_ref>.jsonl` and private traces
  named exactly `<run_ref>.private.jsonl`;
- no successful private value without an authorized private result sink;
- result publication last, after provider cleanup;
- artifact state updated after each successful publication; and
- a publication failure reports already-written, failed, and withheld artifact
  classes without exposing their paths.

Implement the compact recovery state machine retained in
[the Kernel maintainer guide](../../guides/kernel-maintainer.md#private-result-recovery-planned).
Do not generalize it into a transactional artifact store.

`init` renders and validates the complete scaffold in memory before it creates
anything. It creates the requested root and every child exclusively, records
the identity of each entry it created, and never merges with an existing root.
On a caught partial-write failure it removes children in reverse order only
after their identities still match, then removes the root only if it is still
the same invocation-owned empty directory. It never recursively deletes an
unrecognized or concurrently replaced entry. Successful cleanup leaves a clean
retry; uncertain cleanup leaves the remaining entries untouched and reports
the caught initialization failure.

## Revised implementation slices

Every commit must compile and leave all earlier gates green. A numbered slice
may use `a`, `b`, and `c` commits when necessary to respect the review budget.
Do not combine unrelated state machines merely to preserve a one-commit slice.

Delivery uses mergeable checkpoints rather than holding every slice in one
ever-growing branch:

- **Checkpoint A (complete):** slices 0 through 5d2b, providing the sealed
  preparation model, one provider-session owner, active validation, explicit
  provider-application admission, and the Mix runtime cutover.
- **Checkpoint B (complete):** 5d3 and slice 6, completing bounded credentials,
  process-local OAuth, acquisition, and one-shot execution composition. Merged
  as PR #1179 at `37f413de`.
- **Checkpoint C:** the early parity/deadline stabilization prefix described
  below, followed by slice 7 bounded connectivity and doctor. Stabilization
  comes first so doctor reuses a corrected owner boundary instead of adding a
  fourth execution path.
- **Checkpoint D:** slice 8, destination preflight and publication.
- **Checkpoint E:** slice 9, shared commands and REPL parity.
- **Checkpoint F:** slice 10, standalone packaging.
- **Checkpoint G:** slice 11, final acceptance and documentation.

Each follow-up checkpoint starts from the updated `origin/main` after its
predecessor merges. This keeps the deployed boundary useful at every merge and
prevents unfinished later commands or packaging work from expanding an already
reviewable PR.

Use one PR per value-bearing checkpoint, not separate PRs for its plan edits,
prerequisite cleanup, or generated-artifact maintenance. Within that PR, keep
each commit independently reviewable, run an incremental independent review to
clean before committing, and push each clean commit. A later commit must remove
the transitional path it replaces rather than accumulating both paths until
slice 11.

### Slices 0–4: complete and pushed

The completed results are listed above. They remain the base of the revised
work.

### Slice 5: provider-session foundation

Delivery is intentionally split into review-sized commits:

- 5a (complete): shared deadlines;
- 5b (complete): process-free catalogs and sealed runtime activation;
- 5c1 (complete): replace the resource list with one provider-session owner and
  scoped, bounded LIFO cleanup;
- 5c2a (complete): add bounded scoped process-root admission and terminal
  handoff behind the registrar;
- 5c2b (complete): route shipped process and port starts through the scoped
  registrar;
- 5d1 (complete): bounded active selection validation;
- 5d2a (complete): optional application admission inside the new active-session
  boundary;
- 5d2b (complete): atomically cut the command frontend over to that boundary
  and remove optional provider applications from the core OTP startup set; and
- 5d3 (Checkpoint B): bounded credential resolution.

Checkpoint B begins with small prerequisite commits that share application
request and host-catalog acquisition between `mix ptc.run` and the command
engine, derive complete phase code sets from `DiagnosticCatalog` while keeping
intentional subtractions explicit, and make the checked-in semantic projection
reviewable. These commits remove their replaced copies immediately and remain
part of the Checkpoint B PR; they are not separate cleanup PRs. JSV caching and
revision-aware seal-only `PreparedRun` validation remain measured follow-up
work, not prerequisites for Checkpoint B.

Slice 5d2b keeps the Mix command's existing option surface but replaces its
provider-bearing runtime path atomically: destination preflight completes on
the inert prepared run, `ProviderActiveSession` marks activity and admits
applications, and `RunBuilder` assembles through that same session. The core
OTP application no longer infers `:req_llm`; the dependency remains available
for explicit admission and semantic-revision accounting. Credential resolution
and provider acquisition still use the transitional runtime registry and are
the only work intentionally left for 5d3 and slice 6.

The Mix frontend loads application configuration but starts only the PtcRunner
core before admission, so an ordinary downstream `:req_llm` dependency cannot
be inherited accidentally through the caller application. Its ephemeral OAuth
store records every token manager created from it and terminates any adopted
retry manager before the store itself stops; retry ownership therefore never
outlives the backing store.

- replace the unpushed draft with the minimal `ProviderSession`, `Deadline`,
  cleanup stack, provisional root registrar, and runtime-services types;
- make phase-8 activity marking atomic and monotonic;
- make `InstallationCatalog` construction process-free by moving its resolver
  and live authority from `HostInstallationOwner` into marked runtime services;
- remove optional provider applications from the command core's inferred OTP
  startup set and keep their modules available for explicit activation;
- retain one bounded OAuth cleanup owner solely for safe handoff of unsettled
  token managers;
- add the simple optional-application start gate and disable dotenv in both
  optional applications before either can start;
- run active selection validators and credential resolution through bounded
  owner-linked work; and
- keep provider-free execution unchanged.

**Gate:** ordering, session timeout, caller-death after session admission,
application-mode, and reverse-close integration tests pass without any
remote-store or restart-ledger modules. A prestarted application is rejected in
`:command_vm`; a deliberately hanging application documents the explicit
bootstrap limitation rather than asserting a false timeout. Provider-free core
startup leaves every optional provider application stopped, including from a
downstream Mix project that declares `:req_llm` normally. Catalog
construction and every provider-free command create no provider-owned process.
A provider-backed startup regression places a unique sentinel credential in
`.env`, omits it from the explicit environment and resolver, and proves that
neither `:req_llm` nor `:llm_db` reads or exposes it after both `load_dotenv`
flags are disabled and the applications start.
Forced OAuth terminal-persistence failure proves closing the command's
ephemeral store terminates an adopted retry manager rather than stranding it
against a dead store.
A hung closer proves the one cleanup cutoff terminates remaining registered
process/port roots without resetting the budget, while every later callback is
still attempted in reverse order for its reserved share. A builder that starts
a root and then hangs proves provisional registration closes that root even
though no final close callback was returned.

### Slice 6: process-local OAuth and acquisition

**Checkpoint B status (merged 2026-08-05):** PR #1179 completed the bounded
credential, OAuth-context, provider-acquisition, execution-outcome, publication
separation, provider-free execution-owner, and owner-created sink commits.
Provider-backed non-check `mix ptc.run` execution now runs on the same
`ExecutionSessionOwner`: a subordinate authorized executor performs provider
setup and Kernel work while the fixed lifecycle owner tracks the provider
session, registry, OAuth memory, listener, prepared run, and sinks. Runtime
setup crosses that boundary as a sealed `ProviderExecution`; the raw host
configuration and authorization-URL notifier do not enter the sealed value.
Active assembly reuses the owner's already-opened sealed sinks, and the
replaced non-check frontend lifecycle plus `RunBuilder.run_active_with_class/4`
have been removed. `--check` and REPL stay on their existing paths for their
later parity cutover.

The repair pass that followed added caller-death coverage at blocked provider
setup, acquisition, OAuth interaction, and Kernel execution; owner-status,
crash-report, and caller-failure privacy regressions; and a loopback OAuth
fixture that drives the shipped discovery, authorization, and loopback-listener
code over real HTTP. It also corrected the abort unwind, which closed the
provider session second rather than last and so disagreed with the nested
unwind `ProviderExecution` performs itself.

The final repair `df8fa2f6` runs the OAuth context factory and process-free
activation in deadline-cancelled workers, preserves
`operation_deadline_expired`, explicitly releases an invalid returned
authority, and rechecks expiry after host-bound activation. Host-bound
activation itself still runs in the caller because its authority is owned by
the process that created it and `transfer_to_registry/1` reparents to
`self()`. Checkpoint C keeps that step synchronous and records it as the
bounded-input bootstrap exception described above, rather than wrapping
repository-owned initialization in a second ownership protocol.

One gate item stays structurally out of reach in process. `HostConfig` never
enables `allow_insecure_loopback` for an OAuth authority and `HostInstallation`
never passes it to `MCPSource.builder/1`, so a host-installed streamable-HTTP
transport always requires HTTPS. An in-process one-shot therefore proves the
authorization interaction, the run clock that starts only after it settles, and
the single execution-scoped context shared by selected authorities, but stops at
that transport rule before the bearer token reaches an authenticated MCP
request.

Command-level context handoff is therefore covered up to acquisition, and
authenticated bearer transport is covered independently by the credential-free
Go OAuth end-to-end test, which constructs `Context`, `TokenManager`, and
`MCPSource` directly rather than through `ExecutionSessionOwner`. No single test
currently spans both. Closing that seam needs an HTTPS fixture or a trusted
remote harness; do not widen `allow_insecure_loopback` into production
`HostConfig` to reach it from a test.

- adapt the in-memory Store to absolute deadlines with the pre-dispatch and
  in-transaction expiry checks;
- lazily construct one OAuth context per session and claim only selected
  authorities;
- route the Mix-only authorization option through that context;
- anchor shared context setup and every target interaction to the exact
  top-level deadlines above, then start the ordinary run clock after interaction;
- acquire selected providers in dependency order and register each close
  operation immediately;
- preserve token-manager/fence cleanup through session close or the existing
  bounded terminalization handoff; and
- add the one-shot `RunCoordinator.execute/2` composition without a second
  frontend-owned execution lifecycle.

**Gate:** provider-free runs make zero Store calls; expired queued mutations do
not commit; a multi-target fixture proves shared context claims do not reset
their setup deadline, differing selected timeouts use the shortest OAuth
occurrence's intrinsic deadline, and each interaction has its own anchor;
fixtures for validation, credentials, OAuth, acquisition, provider execution,
and Kernel execution prove that either candidate ordering and an exact tie
retain the operation-class diagnostic;
explicit authorization is reusable by the immediately following run without
consuming or renewing its run budget; partial acquisition closes exactly the
acquired prefix in reverse order. Caller death leaves no session-owned resource
process, port, or listener; an OAuth terminalization root may remain only in its
closed-to-new-work self-owned/adopted state, and its unsettled fence prevents
reuse. VM-owned optional-application processes remain until the one-shot VM
exits. Failed opening and caller-death fixtures prove the one execution owner
finalizes and stops both sinks, while a REPL handoff keeps them alive across
evaluations and finalizes them exactly once at REPL close.

### Slice 7: bounded connectivity and doctor

**Stabilization prefix status (merged 2026-08-06):** PR #1180 merged as
`7abc1728` and delivered every entry below. Descriptor authority, the recorded
host-bound activation exception, pre-run dotenv loading, exact listener expiry,
shared `--check` execution ownership, external provider-task ownership, and
anchored terminal cleanup are all on `origin/main`, and the scaffolding each
entry replaced is deleted. Doctor completion is the active work; it starts from
the caller-death ordering repair named in the third residual below, because
doctor becomes the fourth caller of that abort path.

Checkpoint C started with a small stabilization prefix before adding doctor:

- (complete, `586f0de0`) make the sealed provider descriptor authoritative
  during staged preparation; reject `data_class` or `accepts_data` drift before
  preflight, credentials, or acquisition, while retaining the owned-sink
  comparison as defense in depth;
- record host-bound runtime activation as the code-owned bootstrap exception
  above instead of bounding it. The expiry check before activation and the
  release after it already exist, so this slice adds only the two missing
  host-bound regressions — an expired deadline never activates the payload, and
  an operation that expires during activation releases the owner and its lease
  — plus the documented non-guarantee. Creator death is already covered by the
  existing credential-drain regression. Both alternatives
  are worse: decrypting in a worker would move the plaintext host document
  through a process message for a partial bound, and a two-phase handoff would
  add a second ownership protocol around initialization that performs no
  external I/O and is already covered by the creator monitor, fence
  arbitration, transfer reconciliation, and stale-authority protection;
- (complete) classify `.env` loading as command setup rather than bounded run
  work, because dotenv discovery reads the filesystem and mutates the process
  environment: it cannot be deadline-cancelled or rolled back, and an embedding
  must not acquire ambient `.env` state implicitly inside the Kernel. The Mix
  adapter decides once, after preparation and before the `--check`/one-shot
  branch, so both paths apply the same selected-provider rule and neither
  charges the load to the run clock. `ProviderExecution.maybe_load_dotenv/2`
  and the sealed `dotenv_required?` query chain it used are deleted;
- (complete) return zero from `LoopbackListener.remaining/1` on expiry, decide
  expiry before `:gen_tcp.recv/3` rather than delegating it to a zero timeout,
  and keep `:authorization_timeout` distinct from `:invalid_callback_request`.
  Regressions cover a callback already buffered before an expired accept, a
  client that keeps trickling past the deadline, and a silent client that stops
  mid-request. The pre-receive expiry branch remains fail-closed defense in
  depth: its neighbouring branches report the same closed reason at the same
  instant, so it is not independently observable through the socket; and
- (complete) move `--check` onto the shared execution-owner composition. A
  check now differs from a run only in the owner's completion step, so both
  share the activity marker, session, registry, credentials, OAuth,
  acquisition, and cleanup ownership, and `--check --authorize-mcp` reaches the
  same authorization subphase. The replaced scaffolding is deleted with it: the
  Mix adapter's session, registry, OAuth context, deadline, and authorization
  helpers, `RunBuilder.build_active/4`, and `ProviderActiveSession`'s
  frontend-owned `open/3`, `open_setup/3`, and `begin_run/3` together with the
  ownership branch they required; and
- (incomplete, superseded by the two entries below) bound terminal cleanup with
  the budget the lifecycle owner installs. `ProviderSession.close/1` and
  `close_with_unregistered/2` wait `provider_cleanup_timeout_ms` plus one reply
  grace and terminate a session that misses it, returning the classified
  cleanup failure instead of waiting indefinitely.
  `Authorization.cancel_authorization/3` requires a supplied
  `:cleanup_deadline` rather than minting one from the residual budget of the
  interaction it cleans up, and `LoopbackListener.await/4` reports an
  uncommitted cancellation as `authorization_cleanup_failed` instead of
  discarding it. That bounded the caller but left the cleanup it bounds
  violating its own contract in two ways, so the entry does not stand alone:
  terminating a wedged session skipped the `terminate/2` that would have killed
  the provider tasks the session tracked by monitor alone, and every stage of
  terminal cleanup still minted a fresh full budget, so sequential stages were
  bounded individually and not together. Both are repaired below; the wait
  bounds and the two classified failures above are retained unchanged;
- (complete) make one external owner responsible for provider tasks.
  `ProviderTaskTracker` is the sole owner of a run's live callbacks. It
  monitors both `RunState` and the `ProviderSession`, so either lifecycle
  disappearing kills and reaps every attached task — including a session
  terminated at its cleanup deadline, where `terminate/2` cannot run. Session
  attachment routes through that owner and the session's monitor-only provider
  map is deleted, so a session drains through the one owner before any provider
  closer runs rather than tracking tasks itself. A regression proves an
  attached task is alive before the session is wedged and that the task, its
  scope root, and further attachment are all gone once the wedged session is
  terminated; a second proves a committed closer never observes a live task;
  and
- (complete) bound every terminal action with one absolute deadline. The first
  terminal action anchors the session's `cleanup_deadline` through
  `ProviderSession.anchor_cleanup_deadline/1`; OAuth cancellation and the later
  `close/1` or `close_with_unregistered/2` cleanup consume what remains of that
  same deadline instead of each minting the installed cleanup duration again.
  `LoopbackListener` no longer mints a deadline at all — it receives the
  anchoring operation and spends what it returns — the caller anchors where its
  terminal action began so a busy session cannot restart the budget at dequeue,
  and the session is told the share reserved for the closer that must outlive
  it so both bounds agree. Aborting one acquisition scope mid-run is
  deliberately outside that episode and keeps its own bounded budget.
  `provider_cleanup_failed` and `authorization_cleanup_failed` stay exactly as
  classified.

  Three residuals are recorded rather than repaired here, each because closing
  it is an ownership change rather than a deadline fix:

  - The deadline bounds a session's own cleanup, not the last root's exit. A
    scope reaper starts its own `provider_cleanup_timeout_ms` window when it
    observes the session's death, so a terminated session's registered roots can
    outlive the close that reported the failure, inside that separately bounded
    tail. Folding the tail in means propagating the anchored deadline into the
    scope reapers.
  - A terminal stage that must ask the session for the anchored deadline can
    only bound that request by the installed budget, because it cannot know the
    remainder before the reply. A session that answers an OAuth cancellation and
    then stops answering therefore costs one further budget on the close that
    follows, before it is terminated. Removing it means returning the anchored
    deadline out through the authorization subphase so the close inherits it
    instead of asking.
  - Caller death during a check aborts through the execution owner, which closes
    the registry and the OAuth runtime before the session, while a close request
    already delivered to that session continues concurrently. This is the
    shipped abort ordering for runs as well, pinned by its own regression;
    reversing it for the abort path is a separate ownership slice. Doctor
    becomes the fourth caller of that path, so this residual is repaired first
    in the doctor work below rather than inherited.

The first two residuals stay recorded rather than repaired, because neither
blocks the doctor contract below.

Doctor completion delivers the following, again as independently reviewable
commits in one Checkpoint C PR:

- repair the abort ordering named in the third residual above. During run and
  `--check` abort, the execution owner closes the provider session first and
  keeps the registry and the OAuth runtime alive until that cleanup has
  settled, because a committed provider closer runs against the runtime that
  produced its resources. Ownership is corrected to match: the OAuth store and
  the host-bound registry authority both belong to the lifecycle owner rather
  than to the execution worker, so terminating a blocked worker no longer
  destroys the store or revokes the authority a session closer still needs.
  Closing a detached store is itself a bounded terminal action: it stops
  cooperatively, then terminates a store that will not answer, and refuses to
  force-stop a process its handle does not identify as that store. Retry
  ownership never outliving the backing store also moves from the explicit
  close to every cooperative stop, so owner death now terminates registered
  managers too; only a store terminated because it stopped answering at all
  bypasses that step.

  That store bound is deliberately its own outer-runtime bound and does not
  consume the anchored cleanup deadline. The anchored deadline is the session's:
  it governs the registered closers on the session's LIFO stack, which is what
  "every registered closer" and the OAuth-cancellation/`close/1`/
  `close_with_unregistered/2` entries above name. The execution owner's runtime
  handles are not registered closers, and `ProviderRegistry.close/1` already
  minted the same independent bound through `HostInstallationOwner.stop/4`
  before this work, so the store now matches that shipped shape rather than
  inventing one. Inheriting the remainder instead would be worse, not stricter:
  the anchored deadline is designed to be fully spendable by the session's own
  closers, so any session that used its whole budget would hand the store zero
  milliseconds and force-kill it immediately — skipping the cooperative stop,
  and with it the registered-manager termination above, exactly when cleanup is
  already under stress. The cost is explicit: after session cleanup ends, an
  unresponsive registry and an unresponsive store can each add up to two
  seconds, so the owner's post-session unwind is bounded at roughly four
  seconds beyond `provider_cleanup_timeout_ms`. Revisit this only if a
  deployment needs one bound across both, which is a deadline-propagation slice
  rather than an ownership change;

  One residual is recorded rather than repaired. A worker killed between
  creating a detached resource and registering it with the lifecycle owner
  leaves that resource untracked, so it is reaped by the owner's death instead
  of by a cooperative close. The window is bounded by the owner's own lifetime
  and is not a regression — the previous worker-linked resources were killed
  outright at the same point, also without a cooperative close. Closing it means
  creating the resource inside the owner, which is viable for the store but not
  for the registry, whose deadline-bounded activation must not run inside the
  owner's callback loop;
- (complete) implement the default doctor applicability matrix from inert
  declarations. Two survey findings scope this commit. The result contract is already closed
  and complete: `CommandContract` fixes the `runtime`/`application`/`viewer`
  prefix, the per-alias operation ranks, and separate default and connect
  consistency rules, so the work is deriving rows rather than designing them.
  A provider row has no failure code in any mode, so a check that fails must
  fail the whole command with its catalogued diagnostic rather than appear as a
  failing row;
- (complete) build phase-7 audited-local execution. The declaration side was
  already complete — descriptors carry `local_preflight`, host
  installations build the callback, `host_call` reaches it process-free through
  the sealed payload, and `local_preflight/{environment,adapter,launcher}_unavailable`
  are catalogued with `provider_activity: false` — but nothing invokes the
  callback, for runs, checks, or doctor. The architecture section above
  describes where that execution belongs; doctor is the first caller, so this
  commit adds the bounded phase-7 step and the boundary translation from
  `HostInstallation`'s internal reasons into those three closed codes. Keep
  validate and models inert, and every unverified callback behind the phase-8
  marker.

  `local_preflight/4` reaches exactly two shipped sources, and its reachable
  reasons divide cleanly, so the translation is a table rather than a judgement:

  | Internal reason | Closed code |
  | --- | --- |
  | `invalid_compatibility_environment`, `invalid_mcp_working_directory`, `invalid_mcp_executable` | `environment_unavailable` |
  | `mcp_stdio_launcher_unavailable`, `unsupported_mcp_stdio_platform` | `launcher_unavailable` |
  | `invalid_llm_model` | `adapter_unavailable` |

  Two reachable reasons are deliberately absent from that table.
  `provider_destination_denied` and the per-source `invalid_*_selection` values
  are declaration and selection failures rather than local-environment ones, and
  they have their own catalogued phases. Mapping them into a `local_preflight`
  code would report a manifest error as a missing local dependency, so they keep
  their own diagnostics, and an unrecognised reason fails closed as an internal
  error instead of being forced into the nearest local code;
- (complete) wire default doctor through the shared coordinator boundary,
  preserving this separation exactly. `RunCoordinator.local_checks/3` is that
  boundary and the only entry to the step: it anchors the one deadline and
  invokes `LocalPreflight` from the sealed prepared/catalog/services inputs.
  `LocalPreflight` returns only success or a diagnostic and never consumes
  `DoctorPlan` rows, so applicability keeps coming from sealed declarations
  rather than from a rendering plan a caller could shorten. After success,
  doctor settles all audited-local rows, because the shared executor has proven
  every applicable occurrence. `CommandEngine` only selects the command flow and
  renders the returned result: no callback invocation, no deadline arithmetic,
  no occurrence traversal. Run, check, and the REPL reach the same boundary
  through `ProviderExecution.execute/8`, immediately before
  `ProviderActiveSession` marks activity.

  Three supporting decisions were forced by wiring it, each recorded here
  because none is visible from the entry above:

  - the step needed a bound of its own, so `local_preflight_timeout_ms` joins
    the installed-only limit family. It participates in effective identity like
    selection validation, because run and `--check` cross phase 7 too;
  - phase 7 runs before the marker for every caller but not in the same
    consumption state — doctor still holds a claimed preparation while an
    execution owner has already consumed one. `PreparedRun.inactive_valid?/1`
    checks the invariant the step actually depends on, which is that the marker
    is unset, rather than accepting either other predicate; and
  - the plan's two environment facts had no producer. `DoctorEnvironment`
    supplies them from this VM alone: the declared Elixir requirement, and
    whether the optional viewer is on the code path. Neither can fail a
    command, and a test pins the requirement constant against `mix.exs`;
- run `doctor --connect` through the ordinary provider-session prefix and its
  connectivity branch: probe `:probe`, use bounded acquisition/discovery for
  `:acquisition`, and skip `:none`. A survey before starting it fixes the shape:

  - `ProviderExecution` has no connectivity operation at all, so this is the
    whole branch rather than a variation of the run one. The prefix is already
    shared and needs no change: `execute_ordinary/7` marks activity, opens the
    session, resolves OAuth authorities, anchors the operation deadline, and
    opens the runtime registry, and only `complete_operation/2` differs by
    operation. Connectivity becomes the third completion, and unlike run and
    check it does not go through `RunBuilder.build_active_owned/5` — it needs
    the registry and the sealed services, not a Kernel run config;
  - the two modes reach different places. An `:acquisition` occurrence goes
    through the registry it shares with a run — `prepare`, preflight, `acquire`
    with resolved credentials — and registers its closer on the same LIFO stack.
    A `:probe` occurrence instead invokes `catalog.implementations[name]
    .connectivity_probe` with the sealed services, because a probe is not a
    builder and never enters the registry;
  - the shipped live-model probe already exists and needs no work. It disables
    adapter and HTTP retries and redirects, forces a one-token ceiling, resolves
    its credential only after local checks, and spends
    `doctor_connectivity_timeout_ms` intersected with any supplied occurrence
    deadline; and
  - the result contract is stricter than default doctor's and decides the
    result shape. `CommandContract` admits a connect success only when the
    application row is `pass/valid` and *every* provider row is `pass`, so
    `doctor --connect` requires an application, and any failed check fails the
    whole command with its catalogued diagnostic. The connectivity branch can
    therefore return `:ok` or one diagnostic, exactly like the phase-7 step, and
    `DoctorPlan` settles its remaining pending rows only after that success.
    `DoctorPlan.new/3` gains the mode, because connect leaves pending what
    default doctor settles as `requires_connect` or `active_check_required`;

- invoke `:unverified` local checks after the phase-8 marker, under the session
  deadline, for run, `--check`, and `doctor --connect`. Nothing invokes them
  today — that was already true before phase-7 execution existed, and restricting
  `:audited_local` to shipped host declarations made it the only path a custom
  local check has. Default doctor keeps reporting `active_check_required`
  instead of running one.

  Two questions were settled before writing it, because both changed what gets
  built rather than how.

  **The phase a post-marker failure reports (settled, first answer wrong):** the
  local codes keep their phase and the run mode needed no widening at all. The
  question was posed as "run cannot report these codes", from reading
  `diagnostic_pair_allowed?/3` alone; `diagnostic_rows(:run)` returns every
  catalogued row, and `local_preflight` is a classified phase, so a post-marker
  failure already renders through the classified branch. Adding the codes to
  `:run_unclassified` — the answer that reading implied — admits an envelope
  that cannot exist, because that branch pins `provider_activity` to false and
  reports execution as not started. It was added and then reverted under review.

  What is real is the constraint underneath: `provider_declaration` *is*
  pre-classification and pinned to no activity, so a post-marker declaration
  reason cannot render for a run whatever the activity policy says. Those
  reasons therefore report `active_preflight/selection_rejected` past the
  marker, keeping their `:selection` subject and occurrence, while phase 7 keeps
  the declaration phase that stops a manifest error being read as a missing
  local dependency. The placement/selection distinction is a phase-7 refinement
  and is deliberately not carried across the marker.

  **Activity (decided):** `LocalPreflight` builds its diagnostics without
  `provider_activity`, which is correct in phase 7 and wrong after the marker,
  so its constructors take the flag rather than assuming it. That alone was not
  enough: `DiagnosticCatalog.provider_activity_policy/2` pinned the whole
  `local_preflight` phase to `false`, so an honest post-marker diagnostic could
  not be constructed at all — it raised, and the step's own rescue turned the
  real outcome into `internal_error`. `local_preflight` is now the one phase
  that spans the marker and pins neither value, because the flag is what carries
  which side of the marker a check ran on. The whole envelope-schema delta is
  those four rows relaxing `provider_activity` from `false` to a boolean, plus
  `local_check_timeout` losing wording that named only the audited step. No pair
  is added or removed.

  **Closed (registrar scope lifecycle bounds):** scopes were opened with a fixed
  five-second call timeout and activated, committed, and aborted with
  `:infinity`, so a stalled session could overrun a short operation budget or
  hang, and one abort minted a fresh full cleanup budget per scope inside the
  handler. The runtime now has three deadline classes and each registrar action
  belongs to exactly one:

  - the **operation deadline** bounds useful work — open, activate, and the
    commit attempt — and the registrar carries the deadline it was opened
    under, so a handle cannot be replayed against a longer one;
  - a **per-scope abort deadline**, one freshly anchored
    `provider_cleanup_timeout_ms` per abort episode, anchored by the caller
    where the episode begins and shared by every action inside it. N
    independent aborts may spend N budgets. That is deliberate: anchoring the
    terminal deadline here would let one early rejected scope exhaust the
    session's eventual shutdown, and spending the operation deadline would hand
    cleanup a zero remainder exactly when abort is most often triggered by that
    deadline expiring. If aggregate abort latency ever proves excessive, the
    answer is a separate command-wide provisional-cleanup ceiling as a
    deliberate contract change, not overloading either neighbour; and
  - the **terminal cleanup deadline**, anchored once when the session enters its
    final episode and shared across the whole LIFO stack, is untouched.

  Two residuals are covered by reasoning rather than by tests. The fence is
  rechecked after `ProviderScopeOwner.start/2`, because startup can itself
  outlast the caller and a scope inserted past that point has no handle anywhere
  to abort it; forcing that branch needs startup to straddle the deadline, which
  no deterministic mechanism here can arrange, so an expired scope is torn down
  in its own abort episode and the branch stays uncovered. The same is true of a
  setup call that is live at its precheck and expires while waiting: it is
  classified as the operation-class timeout rather than an internal error in all
  three callers — local checks, selection validation, and acquisition — but only
  the already-expired case is reachable on demand.

  Late execution is fenced rather than raced. `open` and `commit` carry the same
  absolute instant the caller stops waiting on, and the handler refuses to
  mutate past it, so a reply nobody is waiting for cannot leave a scope with no
  handle or a closer with two owners. When a commit cannot be confirmed before
  expiry the caller keeps the closer and runs the existing unregistered-closer
  recovery under cleanup authority, which leaves exactly one owner. Regressions
  wedge the session with `:sys.suspend/1` and read `:sys.get_state/1`, so the
  fences are proved by suspension and state rather than by timing margins.

  **Ordering (decided, first answer wrong):** active selection validation runs
  first and the unverified check follows. The first attempt reversed them on the
  grounds that a local check contacts nothing — true of an audited-local check
  in phase 7, and precisely untrue of an unverified one, whose whole definition
  is that nothing bounds what it may do. Running unrestricted work before the
  selection is accepted spends cost and causes side effects for a selection the
  validator then rejects, so the order is a contract rather than a preference;
- keep `MCPHTTPAdapter` as the single shipped HTTP boundary while adding an
  authoritative cap at or before the transport receive boundary; and
- (complete) add shipped live-model probes with retries and redirects disabled.
  `HostInstallation` already builds one: it disables adapter and HTTP retries
  and redirects, forces a one-token ceiling, resolves its credential only after
  local checks, and runs in a heap- and time-bounded worker. The remaining
  connect work is orchestration and transport enforcement, not another probe.

**Connect build order (do not vary):** the CLI surface is enabled last, so no
intermediate commit ships a reachable `doctor --connect` that can perform
provider work the transport does not yet bound. Internal and unreachable is
fine; temporarily reachable and unsafe is not.

1. (complete) add the internal connectivity operation to `ProviderExecution`,
   unreachable from the CLI. `:connect` joins `:run` and `:check` in the
   operation algebra, reaching the same activity marker, `ProviderSession`,
   registry, sealed services, deadline ownership, and cleanup path, and
   differing only in its completion. That completion does not build a run
   config: a run and a check both acquire every selected provider, while
   connectivity decides per occurrence what its declaration asks for.
   `ConnectivityResult` is the internal success value — one entry per selected
   occurrence in declaration order, with a closed outcome set validated at
   construction and, after the repairs in step 2 below, a `bound_to?/3` check
   against the exact preparation and catalog, so a later plan cannot settle a
   row nothing reached. Connectivity has no provider-free
   form, because it answers for selected occurrences. Only `:none` is
   implemented; `:probe` and `:acquisition` fail closed;
2. (complete) implement `:none`, `:probe`, and `:acquisition` behaviour through
   the existing session, registry, activity marker, operation deadline, and LIFO
   cleanup stack. `ConnectivityProbe` is the probe half and follows
   `LocalPreflight`'s shape — derived applicability, one anchored deadline every
   occurrence spends, a bounded worker cancelled with its caller, and a closed
   translation table. It hands the operation deadline to the callback as
   `:doctor_occurrence_deadline_ms`, which is how a shipped probe intersects its
   intrinsic budget with the operation's. The acquisition half calls
   `ProviderAcquisition.acquire_targets/6` with the `:acquisition` occurrences
   as targets and a no-op artifact preflight, because connectivity publishes
   nothing. Three corrections came first, because all of them get more expensive
   once `DoctorPlan` consumes the result:

   - (complete, repaired under review) the acquisition subset primitive.
     `ProviderAcquisition.acquire_subset/6` narrows which providers are
     acquired without narrowing any judgement about the application, and
     `acquire/5` is that primitive with `:all`, so an ordinary run and check
     take the path they always took. Every whole-application judgement stays
     whole-application — all selected providers are prepared, and dependency
     validity, the single-workflow-LLM rule, the effective data class, and the
     providers' acceptance of it are decided over the complete set — because
     narrowing them is exactly how a subset becomes a second, weaker pipeline.
     The first attempt prepared every selected provider to learn
     `requires`/`provides` and narrowed only the later steps. Review rejected
     it, correctly: preparation is provider work, not a lookup — a prepare
     callback can fail the operation, block until the deadline, spend the
     budget a real target needed, and register provisional roots — so a `:none`
     occurrence was not skipped at all whenever anything else acquired. Worse,
     deriving the closure from callback-reported values makes the authority to
     invoke a callback depend on invoking callbacks, and lets executable code
     redirect which executable code runs.

     `acquire_targets/6` therefore plans from sealed evidence.
     `ProviderAcquisition.plan/2` projects the graph from `PreparedRun`'s
     declarations and the exact catalog they were validated against, the closure
     is computed from those sealed `requires`/`provides` before any builder
     runs, and only that closure is prepared, preflighted, credentialed, and
     acquired. Targets are `{destination, index}` — the identity the sealed
     declarations and `ConnectivityResult` already use, not a global counter —
     and are checked before preparation, so an unknown or empty target set costs
     no callback. Inside the closure each preparation is compared with its
     sealed declaration and drift fails closed, because runtime binding compares
     only the data policy.

     The whole-application judgements need no re-derivation: `ProviderPlan`
     already decides dependency validity, cycles, single-workflow-LLM, the
     effective class, and acceptance inertly in phase 5, and seals the result.
     An application whose classes disagree never becomes a preparation at all,
     which is a stronger guarantee than re-checking it here would have been.
     `acquire/5` keeps the complete preparation path unchanged for ordinary runs
     and embedding. Providers pulled in only as dependencies are support work:
     acquired and cleaned up like any other, and never a successful connectivity
     row. Cleanup stays the session's, so a failure mid-closure leaves the
     acquired prefix on its stack rather than unwinding through a path of its
     own;

   - (decided) execution order versus reporting order. The barrier acquires in
     dependency-order waves while the result validates declaration order, so
     the two cannot be the same without building a second incremental
     acquisition engine with cached prerequisites and interleaved probes.
     `ConnectivityResult` is a canonical success projection rather than an
     execution trace — on failure no result exists at all — so declaration
     order means stable output matching the manifest, not the order callbacks
     happened. The pinned shape: compute every `:acquisition` target and its
     dependency closure inertly from sealed `requires`/`provides`; prepare,
     validate, resolve the credential union once, and acquire that closure
     through the existing dependency-order barrier; then run probes in
     declaration order; then build success entries in declaration order.
     Dependency-only providers are support work and never become successful
     connectivity rows. A failure reports the occurrence that actually failed,
     and the contract deliberately promises no manifest-first failure
     precedence;

   - (complete) connectivity is non-interactive by construction.
     `ProviderExecution` could carry authorization targets, which would have
     routed a health check through the interactive authorization path.
     `RunCoordinator.connect/3` takes no notifier, `ProviderExecution.execute/8`
     requires connectivity to carry none, and both the execution owner and the
     execution refuse an execution with authorization targets. The refusal is
     deliberate rather than a silent downgrade to the non-interactive path: a
     caller that asked for authorization and got a check that skipped it would
     be told the wrong thing. Refusing before `init/1` consumes the preparation
     leaves it reusable;

   - (complete) the operation clock. Connectivity entered through
     `begin_owned_run/3` and inherited `run_duration_ms`, which is the wrong
     budget and one the shared-boundary language concealed. That entry point is
     replaced by `ProviderActiveSession.begin_owned_operation/5` over
     `ProviderSession.begin_operation/2`: the duration is supplied by the
     operation rather than read from the session, so `:connect` anchors
     `doctor_connectivity_timeout_ms`. The old names are deleted rather than
     kept as aliases, so nothing can anchor a clock without saying which one;
     and
   - (complete, repaired under review) the result binding. `covers?/2` proved
     occurrence identity
     only, which is not enough where alias names are not identity: the same
     alias sequence names different sealed descriptors in another catalog.
     `ConnectivityResult` is now sealed over the prepared and catalog
     attestations, requires the trio at construction, re-derives every entry's
     mode from the catalog, and refuses an outcome that does not match its
     mode. `bound_to?/3` re-checks all of that, so `DoctorPlan` never has to
     trust entries alone. Review found the seal itself unchecked — a
     caller-authored `%PreparedRun{}` keeping a stale attestation could have its
     edited declarations attested — so `PreparedRun.sealed?/1` now exposes the
     lifecycle-independent seal check the binding needs;

   Review of the foundation slice found two further repairs and one residual.
   Sealing both budgets into the session closed a hole the first correction
   opened: taking a duration argument let any caller anchor a clock longer than
   its limits allowed, so `begin_operation/2` now takes the operation and reads
   the budget the session sealed from its own limits. Registry setup is tagged
   with the real operation, because an exhausted connectivity budget was
   classified as `execution/run_timeout` — a phase the connect contract does not
   admit and a budget connectivity never spends.

   The residual: two expired-deadline branches — registry setup returning
   `:operation_deadline_expired` under `:connect`, and connectivity success
   arriving after its own cutoff — cannot be forced deterministically. An active
   validator is itself killed at the operation deadline, so nothing can carry
   execution past it on purpose. Both stay as fail-closed branches covered by
   reasoning, while the deterministic regressions prove the connectivity clock
   is the one that bounds work inside the operation;
3. add connect-mode planning to `DoctorPlan`, with frontend dispatch still
   disabled. Review of the connectivity modes found three gaps the operation
   cannot close on its own. None is a regression — `authorization_required` is
   constructed nowhere in the tree, and a bare acquisition reason is what an
   ordinary run already propagates — but each becomes a wrong public answer the
   moment the command is reachable, so all three close before step 5:

   - **credentials for a `:none` occurrence.** The credentials row exists
     whenever `credential_names` is non-empty, independent of connectivity mode,
     and connect must settle it `pass/available`. Acquisition resolves the union
     for its closure and a shipped probe resolves its own, so the unsettled case
     is exactly a `:none` occurrence that declares a credential: nothing asks
     for it, and a connect success would claim a credential nobody resolved.

     **Decided:** resolution moves to phase-8 step 5, once per selected alias,
     before the operation branch — the sequence this document already pins.
     Having connect resolve only the remainder its closure missed would give it
     a credential path of its own, which is the second weaker pipeline the
     acquisition subset was rejected for.

     This is not a move. It changes the authority and sequencing model for every
     active command, so it is its own architectural slice built to an explicit
     plan rather than folded into neighbouring work:

     1. required credentials are derived from the sealed selected declarations,
        never from callback reports — the same rule that decides the acquisition
        closure, for the same reason;
     2. resolution happens after registry and OAuth context setup and before any
        provider callback;
     3. it happens once, with deterministic alias and occurrence attribution;
     4. the resolved values are passed into acquisition and probes, and no
        downstream code calls the host resolver again;
     5. a missing credential fails before prepare, preflight, probe, or
        acquisition rather than partway through one;
     6. regressions prove the run and check behaviour changed intentionally —
        a credential failure now surfaces earlier than it did — and that a
        doctor-connect credentials row cannot pass without resolution; and
     7. a regression proves the shipped LLM probe consumes the pre-resolved
        credential instead of resolving its own, since it resolves one today
        inside `prepare_llm_connectivity_probe`;
   - **a selected OAuth occurrence.** The contract returns
     `active_preflight/authorization_required` after the marker and without
     opening an interaction. Nothing constructs that code today, so an OAuth
     selection walks into acquisition against an empty store and fails later
     with whatever that path produces. Connect must refuse it before any
     provider work, and `run` needs the same refusal; and
   - **raw acquisition reasons.** A builder, preflight, or acquire callback
     returning `{:error, reason}` propagates as a bare term through
     `ProviderAcquisition`, and the connectivity boundary cannot classify it: a
     `provider_acquisition` code requires a subject bearing an occurrence and
     the bare reason carries none, so it fails closed as `internal_error` and
     reports an unreachable provider as an implementation defect. The fix
     belongs where the occurrence is still in scope — `prepare_provider/7` and
     its preflight and acquire neighbours — and it changes the shared run path,
     so it is its own reviewed commit rather than a translation invented at the
     connectivity boundary;
4. prove and implement the MCP receive-boundary response cap;
5. only then enable `doctor --connect` in `CommandEngine`; and
6. integration review, acceptance gates, then the cumulative PR review.

Step 2 carries a constraint the phrase "a probe calls the catalog
implementation directly" must not be read as weakening. Direct means selecting
the sealed callback rather than routing it through the registry, which builds
providers a probe does not need. It does not mean invoking a raw function: a
probe still runs only with the runtime-service and catalog binding checked, only
after activity is marked, inside a heap- and time-bounded worker it can be
cancelled with, under the connectivity deadline intersected with any occurrence
deadline, and behind the same privacy translation that keeps credentials and
response material out of every diagnostic. The only thing that differs from
acquisition is where the callback comes from.

**Resolved (which active rows connect settles):** review called active selection
validation for a `:none` occurrence a defect. It is not one, and the closed
result contract decides it rather than the reviewer or the implementation.
`CommandContract` admits a connect success only when *every* provider row is
`pass`, and those rows come from three independent sealed declarations: `local`
exists for every visible alias and is governed by `local_preflight`; `selection`
exists once an application named the occurrence and is governed by
`selection_validation`; and `credentials`, `authorization`, and `connectivity`
exist only when `credential_names`, `authorization_mode`, and
`connectivity_mode` respectively say they apply.

`connectivity_mode: :none` therefore removes exactly one row — the connectivity
row, which `DoctorPlan` omits rather than skips — and says nothing about the
occurrence's other rows. A `:none` occurrence that also declares
`selection_validation: :active` still renders a selection row that only a real
validator run can move off `active_check_required`, so filtering validators by
connectivity mode would leave a row unsettled, make the connect outcome invalid,
and do it by building the second, weaker pipeline the acquisition subset was
rejected for. The declaration is sealed independently too: `validation_state` is
derived from `selection_validation` alone in phase 5 and never consults the
connectivity mode.

The rule is that a mode governs only its own row, and `doctor --connect` settles
every active row the sealed declarations produce:

- every `selection_validation: :active` validator, which run, `--check`, and
  connect already share through
  `ProviderActiveSession.begin_owned_operation/5` — connect needs no selection
  path of its own, and giving it one is the defect to avoid;
- every `local_preflight: :audited_local` check in phase 7, and every
  `local_preflight: :unverified` check after the phase-8 marker;
- credential resolution for every occurrence declaring credentials; and
- the connectivity work of each `:probe` and `:acquisition` occurrence.

An `authorization_mode: :oauth` occurrence has no settling path in V1: its row
demands `pass/available` while standalone OAuth execution is disabled, so connect
fails with `active_preflight/authorization_required` exactly as the OAuth section
specifies. That is the contract holding, not a gap to close here.

**Resolved (audited-local trust):** `:audited_local` is now a declaration
contract the constructors hold to, not only prose. Nothing but a host-bound
shipped installation may declare it, so default doctor cannot reach a callback
that is not shipped, code-owned code. Two rules carry it, and both run at
construction rather than at execution, because an invalid trust claim must not
survive sealing and later be reinterpreted as a skipped check:

- `ProviderDescriptor.new/1` refuses `local_preflight: :audited_local` from a
  `:custom` source. A custom registration declares `:unverified`, whose check is
  active work after the phase-8 marker; and
- `InstallationCatalog.new/2` refuses an `:audited_local` descriptor when it has
  no `runtime_binding`, because an unbound catalog is assembled by its embedder
  rather than derived from a shipped installation recipe.

`LocalPreflight` keeps a fail-closed guard for a trio that fails either rule,
and refuses the whole step rather than skipping the untrusted occurrence, which
would report a local check nothing verified. That guard is defense in depth
rather than an independently reachable branch: `run/4` revalidates both seals
first, so a value failing it crossed a constructor that should not have admitted
it.

The limit of both rules is recorded rather than closed, because closing it costs
more than it buys. They bound what may be *declared*; they do not attest that an
admitted callback came from a shipped recipe. An embedder holding sealed host
services can bind a catalog it assembled itself and register its own closure
under a shipped-source descriptor, and phase 7 will run it before the marker.
Enforcing provenance is possible — an audited-local implementation could be
required to be a closure defined in `HostInstallation` — but it would also make
the step untestable: every phase-7 fixture, including the reason-translation
table, injects a callback, and no shipped callback can be made to return each
reachable reason on demand. The trade is accepted because the embedder in
question is already trusted code that can run anything in this VM without
phase 7, hostile same-VM containment stays an explicit non-goal, and the
guarantee that actually matters is unaffected: manifest input selects installed
aliases and never registers an implementation, so nothing an application
declares can introduce a callback into this step.

**Complete (phase-7 timeout code):** `local_preflight` / `local_check_timeout`
is catalogued and reports an exhausted audited-local budget, whether the budget
ran out before an occurrence started or while one was running. Before it, phase
7 reported `internal_error` for a spent budget: safe and fail-closed, but
misleading for an expected operational outcome — a slow filesystem or adapter
load is not an internal defect.

The exhausted budget is deliberately reported outside the internal-reason
translation table above. A callback that returns `:local_check_timeout` as its
own reason is an unrecognised result and still fails closed, so a defect cannot
be passed off as an operational outcome.

Success is confirmed against the anchored deadline rather than accepted from the
worker alone. The worker's bound is relative and starts after the step computed
what remained, so scheduling delay between the two can deliver a success past
the absolute cutoff; that success is reported as the timeout instead. The branch
cannot be forced deterministically — it needs exactly that skew — so it is
covered by reasoning rather than by a timing test that would flake either way.

**Gate:** default doctor performs no provider activity; connect checks use the
selected occurrences, the same shared activation prefix as a run, their
declared connectivity modes, and intersected operation/intrinsic deadlines.
Acquisition-backed discovery closes every provisional and acquired resource on
the shared stack. Credentials and response material never reach logs,
telemetry, or envelopes; transport status, headers, and body remain bounded. An
adversarial peer cannot deliver a transport-sized binary into the command
process before the response limit rejects it. Fixtures prove validate/models
invoke no local callback, default doctor invokes only audited-local callbacks,
and an unverified check cannot run before activity is true. Connectivity
fixtures prove that either deadline-candidate ordering and an exact tie retain
the connectivity operation-class diagnostic.

The current active-mode Mint loop applies cumulative limits only after one
socket message has already reached the command process, so finite response
fixtures cannot establish this hard bound. First prove and test an authoritative
per-message maximum through socket-buffer configuration; otherwise use Mint's
passive receive mode with an explicit byte cap. Keep the adapter as the public
boundary. A minimal native or port receive helper is a last resort only if
neither shipped mechanism can prove the bound, and any such helper is its own
narrowly reviewed commit. Do not add a second general HTTP stack.

### Slice 8: destination preflight and publication

- complete exclusive destination handles and trace-directory naming;
- implement normal/private result, trace, and inspection ordering;
- implement the minimal private-result recovery protocol; and
- preserve path-free execution and envelopes.

**Gate:** collision, symlink, permissions, partial failure, cleanup failure,
and private no-discard tests pass without provider activity before destination
authorization. Normal and private `--trace-dir` fixtures publish and discover
exactly `<run_ref>.jsonl` and `<run_ref>.private.jsonl`, respectively.

### Slice 9: commands and REPL parity

Checkpoint B left three transitional execution paths, not two: one-shot runs
through `ExecutionSessionOwner` and `build_active_owned/5`, `--check` opens its
own session and calls `build_active/4`, and the REPL opens no active session at
all and calls `load_and_build/3` with an empty registry. Behavioural drift
between them has already produced one reachable privacy defect, so treat this
slice as early simplification rather than work deferred behind later features.

Checkpoint C pulls descriptor-authoritative acquisition, the recorded
runtime-activation bootstrap exception, `.env` ordering, listener expiry, and
`--check` ownership parity forward from this slice. This section retains the broader
command and REPL cutover after destination publication is complete:

- finish shared `help`, `version`, `validate`, `models`, `doctor`, `run`, and
  `init` rendering and dispatch;
- route Mix one-shot and existing REPL modes through the shared preparation and
  session boundaries;
- add manifest-only `--host-config HOST.json` to the REPL, require it for a
  provider-bearing manifest, and reject it in direct and profile modes; and
- remove obsolete option names.

Application-request and host-catalog duplication is removed in Checkpoint B;
slice 9 is a rendering, dispatch, and REPL-parity cutover rather than another
acquisition refactor.

**Gate:** Mix/direct parity fixtures produce the same safe outcomes; help,
version, validate, models, and default doctor have zero provider activity;
`init` never merges with or overwrites an existing path. Fault injection after
each child creation proves caught failure removes only identity-matching
invocation-owned entries and permits a clean retry when rollback succeeds. A
provider-backed Mix
REPL obtains the same trusted installation as `mix ptc.run` from its required
host configuration and opens one command-VM session for its lifetime. A
provider-free manifest may omit the option. After classification and during
phase 6, a private manifest REPL requires an attached explicitly authorized
terminal and rejects detached, script, stdin, load, eval, and JSONL modes before
phase 7 or `open_execution/2`. Rejection proves `provider_activity: false` and no
provider callback, credential, store, application, process, port, or network
work.

### Slice 10: standalone packaging

- add the release entrypoint, launcher framing, and a small outer wrapper for
  the standalone BEAM VM; the existing MCP launcher cannot fill this role;
- enforce the retained standalone process contract for stdout, stderr, and
  exit status; and
- capture or redirect the VM child's stderr behind that code-owned boundary,
  with targeted sentinels for known direct-descriptor and bypass routes; and
- verify descriptor and signal behavior on supported release targets.

**Gate:** packaged conformance tests cover stdin, stdout, stderr, exit status,
broken pipes, descriptor inheritance, and startup identity. Sentinels cover
`IO.warn`, `:standard_error`, Logger/SASL, optional console handlers, child
stderr, and known NIF/direct-descriptor paths; any reachable route that can
render caller/provider material must be removed or captured behind a closed
code-owned boundary. Signal tests verify only the retained contract's explicit
non-guarantees and characterize child lifecycle. If a supported target cannot
preserve the required stream and descriptor contract, or deployment requires
bounded application bootstrap or reliable signal cleanup, start the separate
outer-supervisor plan.

### Slice 11: acceptance and documentation

- update retained CLI, host-configuration, Kernel-maintainer, OAuth, and
  packaging documentation;
- run memory-vs-directory, provider-free, MCP OAuth, live-model, filesystem,
  and packaged acceptance matrices.

**Gate:** all generated docs/schemas are current, documentation builds with
warnings as errors, `mix precommit` passes, credentialed acceptance passes when
configured, and the complete branch receives a clean independent review.

## Delivery and review protocol

Use the merge checkpoints above as sequential PRs targeting `origin/main`.
Do not keep later checkpoints on an unmerged branch merely to preserve the
original one-PR delivery shape.

Before every commit:

1. keep the diff within the review budget or split it;
2. run focused tests and `mix precommit`; and
3. record any intentionally deferred limitation in the checkpoint description.

The incremental independent review is the required local review before each
commit. External PR review remains useful but does not replace it or require a
duplicate local pass over byte-identical content. Fix every actionable finding
and rerun the affected gates before committing.

Documentation changes also run:

```text
MIX_ENV=dev mix docs --warnings-as-errors
```

Record verification and review status in the PR body. Before merging each
checkpoint, reconcile it with the latest `origin/main`, rerun the full gates,
and complete the chosen local or external review. If a later finding belongs
to an earlier unmerged commit, fix the owning boundary and recheck affected
descendants instead of papering over the defect.

For each commit, review only its uncommitted incremental delta, batch any
findings, and use focused follow-up review until that exact tree is clean. Run
the relevant tests and `mix precommit`, then commit and push without changing
the reviewed tree. At the checkpoint boundary, run one fresh cumulative review
against a freshly fetched `origin/main`; if the base advances, rebase and repeat
that cumulative review.

## Required acceptance properties

The final branch must demonstrate these behaviors through integration or
conformance tests:

- memory and directory packages compile to identical identities and behavior;
- provider-free commands perform no provider, credential, OAuth,
  provider-owned/external-process, or network work; bounded internal validation
  and compilation workers remain permitted;
- activity becomes true immediately before the first allowed active action and
  never reverts;
- selected provider ordering and cleanup are deterministic;
- deadlines cannot be reset by nested calls or commit a late queued mutation;
- caller death and timeout terminate session-owned work and close acquired
  resources; VM-owned optional applications live until command-VM shutdown,
  their bootstrap retains the explicit non-bounded exception, and only a safely
  self-owned/adopted unsettled OAuth terminalization root may outlive cleanup;
- cleanup uses one terminal absolute deadline, never a fresh budget per closer,
  gives every registered closer a bounded attempt in reverse order, and
  force-closes registered process/port roots when that deadline expires except
  for the fenced OAuth terminalization roots above;
- public output conforms to the envelope schema and contains no private data,
  path, credential, arbitrary term, or raw provider response;
- private results cannot be reported successful without an authorized,
  owner-only sink;
- provider cleanup precedes final result publication;
- Mix and standalone frontends share parsing and command semantics except for
  the explicit Mix-only authorization option;
- private manifest REPL values reach only an attached explicitly authorized
  terminal and never detached, scripted, stdin, or JSONL output;
- standalone release streams, descriptors, and documented exit behavior
  conform on every supported target, while signals retain their explicit V1
  non-guarantee; and
- generated schemas, semantic projections, and retained documentation agree
  with the implementation.

## Explicit deferrals

The following are out of scope until a concrete adapter or deployment requires
them:

- remote OAuth stores, cross-clock deadline translation, possibly-dispatched
  mutation algebra, generated replay catalogs, and store-local identity;
- durable cleanup journals, reservation generations, restart reconstruction,
  and exact restoration of prior OTP application-controller state;
- multiple OAuth context groups inside one command;
- an HTTP service, job queue, tenant authentication/isolation, scheduling,
  service cancellation, or concurrency quotas;
- a general object/transactional artifact store;
- standalone durable OAuth authorization;
- a two-phase ownership handoff that makes host-bound runtime activation
  hard-cancellable; its trigger is a supported deployment that cannot accept
  the bootstrap exception above, and decrypting in a worker is not an
  acceptable substitute;
- a new LLM adapter or removal of `req_llm`/`llm_db`;
- a second general HTTP stack; a minimal native/port receive helper is allowed
  only when the shipped boundary cannot prove and enforce the slice-7 cap;
- hostile same-user or same-VM containment; and
- backward-compatible CLI aliases.

Start a new retained design only when its trigger exists. In particular, use
[the durable OAuth store plan](../future/mcp-oauth-durable-store.md) when a real
durable adapter is chosen, and define hosted-service security at the boundary
where untrusted tenants actually enter.

## Completion criterion

This plan is complete when slices 5–11 are delivered, the old speculative
slice-5 machinery is absent, every commit has a clean exact-commit review, all
gates pass after the final rebase, and the PR is ready for human review. A
smaller implementation with explicit deferrals is preferred over satisfying
future scenarios through unused abstractions.
