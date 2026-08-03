# Stable CLI and transport-neutral application plan

**Status:** accepted; implementation in progress.
**Revised:** 2026-08-02 after the first implementation of slice 5 proved too
large to review or maintain safely.

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

## Existing foundation

The runtime already provides the evaluator, bounded workers, provider
registry, confined reads, artifact formats, strict validators, an in-memory
OAuth store, and a bounded MCP HTTP adapter. This plan composes those pieces;
it does not introduce another evaluator, HTTP stack, general artifact store,
or service supervisor.

Completed commits on `codex/stable-cli-contract`:

| Slice | Commit | Result |
| --- | --- | --- |
| 0 | `3f628776` | Bundle hashes include canonical dependency edges. |
| 1 | `496cbd18` | Sealed, transport-neutral run requests and content identity. |
| 2 | `4ebfc302` | Closed command preparation, diagnostics, and envelopes. |
| 3 | `54c26bb7` | Closed generated limit catalog. |
| 4 | `416e9346` | Inert provider declarations and effective identity. |
| 5a | `9db10af5` | Shared absolute-monotonic deadline type and migrated provider activity. |
| 5b | `e957cc21` | Process-free catalogs and sealed runtime activation. |
| 5c1 | `804582d9` | One provider-session owner with scoped, bounded LIFO cleanup. |
| 5c2a | `5ee24051` | Bounded scoped process-root admission and terminal handoff. |
| 5c2b | `c46a7d2d` | Shipped process and port roots use scoped registration. |

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
they are different user operations. Each bounded nested operation also keeps
its intrinsic absolute deadline: active selection validation uses its installed
validation limit, and provider work uses the selected provider's normalized
timeout when it has one. Work receives the earlier of the top-level and
intrinsic deadlines while retaining both candidates and which one bound; the
top-level deadline wins an exact tie. A run-bound expiry is `run_timeout`, while
a strictly earlier intrinsic expiry uses that sub-operation's closed diagnostic.
Doctor connectivity retains its connectivity diagnostic mapping, with
selection-validator expiry remaining `selection_validation_timeout`. Passing
either deadline through nested work may narrow it but never resets it.
For an ordinary run or doctor operation, shared OAuth context construction,
principal claim, and authority-claim batch use the minimum intrinsic deadline
across all selected OAuth occurrences in the session, intersected with the
applicable top-level deadline; alias ordering therefore cannot choose or extend
the shared bound.

For a Mix run with explicit authorization, phase 8 first creates one
`authorization_setup_deadline` from the minimum configured
`authorization_timeout_ms` among the selected OAuth aliases, before lazily
constructing the shared context. The effective setup deadline is the minimum of
that deadline and every selected OAuth occurrence's intrinsic deadline, all
anchored when setup begins; it retains both candidates and the authorization
setup deadline wins an exact tie. `Context.new`, its principal claim, and one
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
network work. A custom `:unverified` callback is active work: default doctor
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
- 5d2a (current): optional application admission inside the new active-session
  boundary;
- 5d2b: atomically cut the command frontend over to that boundary and remove
  optional provider applications from the core OTP startup set; and
- 5d3: bounded credential resolution.

The 5d2a foundation does not change the legacy `RunBuilder` command path. Its
runtime-services mode is consumed only by `ProviderActiveSession`. Removing
`:req_llm` from generated OTP application metadata is intentionally deferred
to 5d2b, because doing so before the command cutover would strand the legacy
provider path without its eagerly started application. The cutover and metadata
removal must land together; no intermediate commit may claim CLI enforcement.

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
startup leaves every optional provider application stopped. Catalog
construction and every provider-free command create no provider-owned process.
A provider-backed startup regression places a unique sentinel credential in
`.env`, omits it from the explicit environment and resolver, and proves that
neither `:req_llm` nor `:llm_db` reads or exposes it after both `load_dotenv`
flags are disabled and the applications start.
A hung closer proves the one cleanup cutoff terminates remaining registered
process/port roots without resetting the budget, while every later callback is
still attempted in reverse order for its reserved share. A builder that starts
a root and then hangs proves provisional registration closes that root even
though no final close callback was returned.

### Slice 6: process-local OAuth and acquisition

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

- implement the default doctor applicability matrix from inert declarations;
- keep validate/models inert, audited-local checks in phase 7, and every
  unverified callback behind the phase-8 marker;
- run `doctor --connect` through the ordinary provider-session prefix and its
  connectivity branch: probe `:probe`, use bounded acquisition/discovery for
  `:acquisition`, and skip `:none`;
- keep `MCPHTTPAdapter` as the single shipped HTTP boundary while adding an
  authoritative cap at or before the transport receive boundary; and
- add shipped live-model probes with retries and redirects disabled.

**Gate:** default doctor performs no provider activity; connect checks use the
selected occurrences, the same shared activation prefix as a run, their
declared connectivity modes, and intersected operation/intrinsic deadlines.
Acquisition-backed discovery closes every provisional and acquired resource on
the shared stack. Credentials and response material never reach logs,
telemetry, or envelopes; transport status, headers, and body remain bounded. An
adversarial peer cannot deliver a transport-sized binary into the command
process before the response limit rejects it. Fixtures prove validate/models
invoke no local callback, default doctor invokes only audited-local callbacks,
and an unverified check cannot run before activity is true.

The current Mint loop applies cumulative limits only after receiving a complete
transport message, so finite response fixtures cannot establish this hard
bound. Keep the adapter as the public boundary, but configure a proven
transport-level maximum or put the smallest passive/capped receive mechanism
behind it. Any backend or port-helper change is its own narrowly reviewed
commit; do not add a second general HTTP stack.

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

- finish shared `help`, `version`, `validate`, `models`, `doctor`, `run`, and
  `init` dispatch;
- route Mix one-shot and existing REPL modes through the shared preparation and
  session boundaries;
- add manifest-only `--host-config HOST.json` to the REPL, require it for a
  provider-bearing manifest, and reject it in direct and profile modes; and
- remove obsolete option names and duplicate frontend logic.

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

- add the release entrypoint and launcher framing;
- enforce the retained standalone process contract for stdout, stderr, and
  exit status; and
- add a dependency-version-pinned inventory of reachable direct descriptor and
  secret-bearing stderr writes, failing on unclassified dependency drift; and
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
  and packaged acceptance matrices; and
- delete dead scaffolding exposed by the completed integration.

**Gate:** all generated docs/schemas are current, documentation builds with
warnings as errors, `mix precommit` passes, credentialed acceptance passes when
configured, and the complete branch receives a clean independent review.

## Delivery and review protocol

Use one feature branch and one PR targeting `origin/main`.

Before every commit:

1. keep the diff within the review budget or split it;
2. run focused tests and `mix precommit`;
3. run an independent adversarial review of the exact proposed commit in the
   context of preceding commits;
4. fix every actionable finding and repeat focused review; and
5. obtain a fresh clean review of the immutable commit before pushing it.

Documentation changes also run:

```text
MIX_ENV=dev mix docs --warnings-as-errors
```

Push only after the exact commit is clean. Record verification and the clean
review result in the PR body. After the final slice, rebase on `origin/main`,
rerun the full gates, run a fresh full-branch review against `origin/main`, and
open or update the PR. If a later finding belongs to an earlier unmerged
commit, rewrite that commit and re-review affected descendants instead of
papering over the defect.

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
