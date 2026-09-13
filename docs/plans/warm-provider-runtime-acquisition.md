# Plan: acquire providers once for a warm provider runtime

Status: planned. Nothing here is implemented. This plan is the prerequisite
that #1919 (host-owned warm provider runtime) stopped on: there is no way to
acquire a serving template's providers once, without a per-call input, and
let many short runs use them.

## Current behaviour this plan builds on

- `RunRequest.new/3` seals package, input and policy, and `ExecutionInput`
  must be contract-valid. Every valid `RunRequest` therefore carries admitted
  input. That invariant stays.
- `RunCoordinator.prepare/2` seals a `PreparedRun` from a `RunRequest` and an
  `InstallationCatalog`: bundles, `provider_declarations` (which carry a fresh
  `execution_scope_id` per preparation), `installation_config_digests`,
  `effective_application_digest`, `catalog_attestation`, and a
  `ProviderActivity` marker owned by the preparing process.
- Provider work for an active command runs only through
  `ProviderExecution.execute/*` and `open_repl/*`: local checks, an active
  `ProviderSession` bound to the prepared run and an operation deadline
  (`ProviderActiveSession.begin_owned_operation/*`), a runtime registry
  derived by `InstallationCatalog.runtime_registry/5` under
  `ProviderRuntimeServices`, OAuth authorities, credential resolution by
  `ProviderCredentials.resolve/*` at phase-8 step 5, and only then
  `ProviderAcquisition.acquire/6`. Nothing in this plan calls
  `ProviderSession.start/1` or `ProviderAcquisition.acquire/6` directly.
- `ProviderAcquisition.acquire/6` returns the acquired capabilities together
  with `provider_session` and provider-name-keyed `snapshots`. `RunBuilder`
  stores that session in `RunConfig.provider_session`; a build failure closes
  it, and `RunConfig.close_provider_session/1` closes it at run end.
- The manifest REPL is the one long-lived provider owner today.
  `ManifestReplOpening` holds the session opened by `open_repl/6`, starts one
  `RunState` with `RunState.start_repl/4`, and binds the session to that run
  with `RunState.use_provider_session/2` and `RunConfig.bind_provider_session/4`
  (which calls `ProviderSession.bind_lifecycle/4`). One session, one run
  state, many evaluations.
- `ServingTemplate.from_directory/3` refuses provider-bearing packages with
  `:provider_runtime_required`. `ServingCall.reserve/4` and `activate/2`
  seal a real per-call `RunRequest`, then build a `PreparedRun` by hand from
  the template's cached bundles with an empty catalog and no declarations,
  and never call `RunCoordinator.prepare/2`.

## Goal

A host starts one long-lived provider runtime per provider-bearing serving
template. The runtime acquires the template's selected providers exactly
once through the active pipeline, with no per-call input, verifies the pins
recorded on #1919, and lets every call run a fresh short run that borrows the
acquired providers without owning them. Per-call values stay per call: run and
trace identities, execution ownership, sinks, publication authority, registry
authority, admission lease.

## Non-goals

- Changing `ptc run`, `doctor --connect`, replay, or the manifest REPL.
- Provider-call admission, leases, deadlines and the precedence table: #1919
  keeps those on `ProviderCallAdmission` from #1290.
- Credential capture, MCP OAuth durable state, and the HTTP gateway (#1920).
- Reacquiring on drift or loss: a runtime that loses its session becomes not
  ready and the operator restarts it.
- Sharing anything but LLM installations. A template that selects any other
  provider kind is refused at runtime start with
  `:provider_runtime_unsupported`. MCP sessions are stateful and are not
  shareable across runs; that is a later plan.

## Design

### 1. A sealed serving request, distinct from a run request

Add `PtcRunner.Kernel.ServingRequest`: a sealed tuple of `ApplicationPackage`
and `ExecutionPolicy` with no input, input authority fixed to `:normal`, and
its own attestation. `RunRequest` is untouched and keeps rejecting an
input-free value.

`RunCoordinator.prepare/2` gains a clause for `%ServingRequest{}`. Phases 4
and 5 depend on the package and policy only; the sealed `PreparedRun` carries
the serving request in `request`, and `entry_source` is unchanged. After
provider planning, preparation of a serving request rejects
`effective_data_class == :private_inspection` and `effective_flow == :private`
with the closed code `:private_result_unservable`, because a selected provider
can promote the class even when the declared policy is normal (#1939).

Refusal is structural, not a check to remember: `RunBuilder.build/3`,
`build_prepared/3`, `build_prepared_owned/4`, `build_active_owned/*`, the
mission REPL entries and `ProviderExecution.execute/*` and `open_repl/*` match
`%PreparedRun{request: %RunRequest{}}` and answer `:invalid_prepared_run` for
anything else. A serving-prepared run is consumable only by the `:serve`
operation below.

`ServingTemplate.from_directory/3` compiles provider-bearing packages only
with the explicit option `providers: %InstallationCatalog{}`; without it the
existing `:provider_runtime_required` refusal stands, and a provider-free
package ignores the option. The catalog must be sealed and its installed
limits must equal the `installed_limits` argument, else construction refuses
with `:invalid_installation_catalog`. With it, construction seals the serving
request, prepares it through the coordinator with that catalog, and retains
the sealed catalog and the provider-inert parts of the `PreparedRun`
(bundles, declarations projection, `installation_config_digests`,
`effective_application_digest`, `catalog_attestation`) as template metadata.
The `ProviderActivity` marker is consumed and closed during construction; the
template remains process-independent. `installation_config_digests/1` returns
the real map instead of `%{}`.

### 2. The `:serve` operation in `ProviderExecution`

Add `ProviderExecution.open_serving/5` taking the serving-prepared run, the
execution value (`ProviderExecution.new/3` from the catalog and
`ProviderRuntimeServices`), a tracker, the runtime process as lifecycle
owner, and the acquisition `Deadline`. It runs `do_execute/8` with scope
`{:serve, :all}` and no publication authority or sinks: the same local
checks, `open_consumed_setup/*`, owned operation, OAuth authorities, runtime
registry owned by the runtime process, credential resolution at the existing
point, and acquisition. Unlike `open_repl/6`, which builds a run and embeds
the session in a `RunConfig`, the `:serve` branch of `complete/*` stops after
acquisition and returns
`{:ok, %ProviderExecution.Opened{session, providers, snapshot_sites, registry}}`
or `{:error, term()}`; no `RunConfig` exists at this point.

The operation deadline bounds startup only. The session's run deadline is the
runtime's acquisition deadline; per-call deadlines come from each call's own
`RunState`, not from the session. `provider_operation(:serve)` maps to `:run`
as `:repl` does.

Snapshot maps are not changed: `ProviderSnapshot.llm_identity/1` validates
exact key sets and recomputes `snapshot_hash`, so a tagged snapshot would be
unattributable. Instead the acquired result gains a parallel `snapshot_sites`
list with one entry per selected occurrence:
`%{destination: :workflow | :mission, name: binary(), acquisition_identity_hash: binary() | nil}`.
Names are unique per destination in a manifest, so `"<destination>/<name>"`
identifies a selection; `nil` marks a provider that emitted no snapshot.

### 3. `PtcRunner.Kernel.ProviderRuntime`

A supervised process the host starts per provider-bearing template:

```
ProviderRuntime.start_link(
  template: ServingTemplate.t(),   # built with providers: catalog; retains it
  services: ProviderRuntimeServices.t(),
  pins: %{installation_config_pins: map(), provider_snapshot_pins: map()} | :discover
)
```

Init, in order:

1. Refuse unless every selected installation is an LLM installation
   (`:provider_runtime_unsupported`).
2. `ProviderExecution.new/3`, then `open_serving/5` with `self()` as the
   lifecycle owner. Any failure returns the closed acquisition or connectivity
   code and retains nothing.
3. Pin verification against the acquired result:
   `installation_config_pins` must equal the prepared run's
   `installation_config_digests`; `provider_snapshot_pins` must equal the map
   of `"<destination>/<name>"` to `sha256:<acquisition_identity_hash>` over
   `snapshot_sites`. A selected LLM installation whose adapter emitted no
   snapshot is unpinnable and refuses readiness with
   `:provider_pin_unavailable`. Missing, extra or mismatched entries refuse with
   `:installation_pin_mismatch` or `:provider_pin_mismatch`, and the session is
   closed before init returns.
4. With `pins: :discover` the runtime performs the same acquisition, prints
   the two maps, and closes the session. Discovery is a real acquisition with
   credentials and provider side effects, followed by the ordinary cleanup;
   its failures use the same closed codes. #1919's operator command wraps it.

The runtime records its plan identity as `{catalog_attestation,
effective_application_digest, installation_config_digests}`; the raw
declarations are not part of it because they carry per-preparation scope
references.

Public functions:

- `status/1`: `:ready`, `{:not_ready, code}`, or `:draining`.
- `borrow/2`: given the absolute admission-owned execution deadline, while
  ready it calls `ProviderSession.borrow/2` with that deadline and returns
  `{:ok, %Borrow{}}`: a monitored, caller-bound token carrying the
  `%ProviderSession.Borrowed{}` (which holds the deadline), the plan identity
  and the shared capabilities. A borrow is released by `return/1` or by the
  caller's exit; the runtime counts outstanding borrows. Nothing else carries
  a deadline.
- `drain/2`: refuses new borrows, waits for outstanding ones up to the given
  deadline, then closes the session once with `ProviderSession.close/1`;
  borrows still outstanding at the deadline are reported and the session is
  closed anyway.
- Loss: the runtime monitors the session and the registry owner it created;
  any of them going down moves the runtime to `{:not_ready,
  :provider_runtime_lost}`. That is the only generic health signal available;
  provider-specific health is out of scope.

### 4. Borrowing a session from a per-call run

The REPL binds one session to one run state for its lifetime. Serving needs
many short runs against one session, so:

- Creation and binding are split, because `RunConfig` is built before the
  run state and tracker exist. `ProviderSession.borrow/2` takes the owner's
  session and an absolute deadline and returns a `%ProviderSession.Borrowed{}` value that exposes the
  capabilities and owns nothing; `RunBuilder` stores it in
  `RunConfig.provider_session`. Later, `RunConfig.bind_provider_session/4`
  with a borrowed value calls the new `ProviderSession.bind_borrowed/4` with
  the per-call run state and tracker, registering only the run-scoped
  lifecycle and counting the run under the session. A borrowed value carries
  the absolute execution deadline the caller supplies to
  `ProviderSession.borrow/2` (the admission-owned deadline `ServingCall`
  already holds), and `ProviderSession.execution_deadline/1` returns it, so
  `RunConfig.new/1` needs no new option and `ExecutionPolicy` gains no field.
  `RunConfig.close_provider_session/1` and `close_provider_session_detailed/1`
  return `:ok` for a borrowed value without touching the session, and
  `RunBuilder`'s build-failure cleanup does the same.
- Add a retained acquisition context to `RunBuilder`. `providers/6` receives
  `nil`, the active tuple, or the mission REPL tuple today; add
  `%RunBuilder.Retained{borrow: Borrow.t()}`. `acquire_providers/6` with it
  returns the borrowed capabilities and never opens a session.
- Add `RunBuilder.build_borrowed_owned/5` taking the per-call `PreparedRun`,
  registry, publication authority, opened sinks and the `%Borrow{}`, whose
  borrowed session it stores in `RunConfig.provider_session`. It runs the
  same validations as `build_active_owned/*`, refuses with
  `:provider_runtime_mismatch` unless the per-call prepared run's plan
  identity equals the borrow's, and then assembles through the existing
  `assemble_environments/4` and builds with the borrowed session bound.

Per call, `ServingCall` seals a real `RunRequest` and calls a new sealed
constructor `ServingTemplate.prepare_call/2`. `PreparedRun.new/7` requires the
actual `InstallationCatalog` and revalidates the complete eight-field metadata
set (effective policy, projection, post-selection context and the rest), so a
provider-bearing template retains at construction the sealed catalog it was
prepared against and that complete metadata map, both provider-inert, and
`prepare_call/2` reuses them with the per-call request. Nothing is recompiled
or re-planned per call, and the per-call plan identity equals the runtime's by
construction. `prepare_call/2` is the only per-call path; the hand-built
`PreparedRun` in `ServingCall` today moves behind it.

`ServingCall` obtains a borrow before activation and returns it in every
outcome path, including the existing `cleanup_failed` branches. The borrow
reaches the build through a sealed
`%ProviderExecution.Retained{execution, borrow, plan_identity}` value:
`RunAdmission.activate/*` accepts it wherever it accepts an optional
`ProviderExecution`, and `ExecutionSessionOwner` treats it as the bound
execution a provider-bearing preparation requires, dispatching
`RunBuilder.build_borrowed_owned/5` instead of the active build.

`ServingTemplate` maps a missing or not-ready runtime to the existing
`:provider_runtime_required` for construction and to a new closed call outcome
`:provider_runtime_unavailable`.

### 5. Safety rules

- A serving request never reaches an evaluator: the build entries refuse it by
  type, tested at every entry.
- Credentials are resolved only inside the active pipeline from the sealed
  declarations; the runtime never accepts a credential map.
- Borrowed capabilities are shared among concurrent runs. Only LLM
  installations qualify, and #1290's admission lease serialises their
  concurrent use; the borrow adds no second lock.
- Per-call runs create their own registrar roots and close only those; the
  session's roots belong to the runtime and close once in `drain/2`.

## Workstreams

1. `ServingRequest`, the coordinator clause with the private-class refusal,
   and the structural `:invalid_prepared_run` refusals with boundary tests on
   every build entry. `ServingTemplate` construction for provider-bearing
   packages with real `installation_config_digests/1`.
2. `ProviderExecution.open_serving/5`, tagged snapshots, and
   `ProviderRuntime` with pins, discovery, borrow accounting, drain and loss
   handling. Tests use the acquisition tracing from
   `serving_template_acquisition_test.exs` to prove one acquisition across
   many concurrent calls, plus each pin failure, an unpinnable installation,
   session loss, and a drain with outstanding borrows.
3. `ProviderSession.borrow/2` and `bind_borrowed/4`, the borrowed `RunConfig`
   binding and no-op close, the `Retained` execution value through admission, the `Retained` context and `build_borrowed_owned/5`, with tests that
   a borrowed run closes no provider on success or failure and that a plan
   identity mismatch is refused before any provider is touched.
4. `ServingCall` and `ServingTemplate` wiring and the closed outcome codes.

Workstreams 1 to 3 are one issue. Workstream 4 belongs to #1919, which then
implements admission, leases and the precedence table on top. The pin key on
#1919 changes from `<destination>/<index>` to `<destination>/<name>`.

## Acceptance

- A provider-bearing serving template starts a runtime with no input, and a
  trace shows one acquisition for N concurrent calls.
- Every pin failure and an unpinnable installation refuse readiness with closed
  codes and retain nothing.
- Drain closes the session exactly once; no run built on a borrow closes a
  provider, on success or on any failure path.
- Every `RunBuilder` and `ProviderExecution` entry refuses a serving-prepared
  run.
- `ptc run`, `doctor --connect`, replay and the manifest REPL are unchanged,
  proven by the existing suites.
