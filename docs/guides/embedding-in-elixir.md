# Embedding PtcRunner in Elixir

Ordinary PtcRunner users should be able to author PTC-Lisp and a manifest
without writing Elixir. The direct Elixir API exists for applications that
need custom installed providers, an HTTP or job frontend, application-owned
configuration, or integration with an existing supervision tree.

The embedded path uses the same immutable bundles, environments, limits,
result types, and event contracts as manifest execution.

## Run one embedded workflow

```elixir
alias PtcRunner.Kernel
alias PtcRunner.Kernel.Component
alias PtcRunner.Kernel.EventSink
alias PtcRunner.Kernel.Limits
alias PtcRunner.Kernel.MissionEnvironment
alias PtcRunner.Kernel.RunConfig
alias PtcRunner.Kernel.WorkflowEnvironment

{:ok, component} =
  Component.new(
    id: "example",
    source: "(ns example) (defn run [input] (return (* 2 (get input \"n\"))))"
  )

{:ok, bundle} = Kernel.compile_bundle([component])
{:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
{:ok, mission} = MissionEnvironment.new([])
{:ok, limits} = Limits.new()
{:ok, sink} = EventSink.start(:normal, limits, run_id: "embedded-example")

{:ok, config} =
  RunConfig.new(
    workflow_environment: workflow,
    mission_environment: mission,
    input: %{"input" => %{"n" => 21}},
    limits: limits,
    event_sink: sink
  )

{:ok, %{value: 42}} = PtcRunner.Kernel.run("(example/run data/input)", config)
events = EventSink.events(sink)
EventSink.stop(sink)
```

The host creates every authority-bearing value. `PtcRunner.Kernel.run/2` does not derive
capabilities from application environment, the process dictionary, or other
ambient state.

The example component has no dependencies. For shipped libraries, resolve the
installed closure before compiling it:

```elixir
{:ok, components} =
  PtcRunner.Kernel.Library.resolve_components([{:library, "log.analysis"}])

{:ok, bundle} = PtcRunner.Kernel.compile_bundle(components)
```

`Library.component/1` fetches exactly one component and does not expand its
dependencies. This makes incomplete direct API usage fail at compilation
instead of producing a partially functional bundle.

## Prefer manifests for deployable projects

`PtcRunner.Kernel.ApplicationPackage` is the shared acquisition path for
directory and in-memory applications. It produces a path-free package and
selected `ExecutionInput`; `request_directory/2` and `request_memory/3` also
seal the destination-free `ExecutionPolicy` into a `RunRequest`.
`PtcRunner.Kernel.RunBuilder` consumes that request. Reuse these boundaries
when an application wants the standard strict manifest contract. Do not build
a parallel loader or another provider and event path in a web controller or
job worker. Both embedding paths default to the native result projection;
JSON-emitting commands select the JSON projection explicitly, while the REPL
selects native continuation values explicitly.

A separately acquired request must use the same installed ceilings as the
`ProviderRegistry` passed to `RunBuilder.build/3`. The builder rejects a
mismatch by default. Trusted embedding may deliberately replace that authority
for one construction only by supplying the same explicit `:installed_limits`
to both package acquisition and `RunBuilder.build/3`.

## Start a provider's backing application

The core application deliberately starts no provider dependency on your behalf,
so depending on `ptc_runner` never starts `req_llm` or `llm_db` inside your
release. A run admits the application it needs through
`PtcRunner.Kernel.ProviderApplicationGate`. `mix ptc run` reaches it through the execution-owned
`ProviderActiveSession.open_consumed_setup/5`, where the execution-session owner
already owns the prepared run and the session's lifecycle. There is no
creator-owned variant.

An embedded frontend that drives `ProviderRegistry` and `RunBuilder` directly
does not pass through that gate, so it owns the admission itself:

```elixir
Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
{:ok, _started} = Application.ensure_all_started(:req_llm)
```

Set `load_dotenv` to `false` first if the host resolves credentials itself; that
is what the command-owned gate branch does before starting the application, and
it keeps the dependency from reading a `.env` the host did not choose.

A request issued while that application is stopped fails with a non-retryable
`:internal` provider error naming the application, rather than a retryable
transport outage, because retrying cannot start an OTP application. Adapters
declare what they need through the optional `provider_application/1` callback on
`PtcRunner.LLM`, which receives the resolved model and answers `:req_llm` or
`nil`: one adapter may route some models through a dependency and serve others
directly over HTTP, and only the former fail this way.

Run admission is deliberately coarser. Catalog construction is inert and invokes
no provider implementation, so it admits every shipped LLM installation against
`:req_llm` regardless of route. A host-owned run therefore still expects that
application even for a direct `ollama:` or `openai-compat:` model.

Credential loading is decided separately. `mix ptc run` reads the nearest `.env`
whenever a selected LLM installation declares an `env` credential, including for
direct routes that need no backing application at all.

## Install custom providers

Custom provider builders are trusted Elixir functions registered through
`PtcRunner.Kernel.ProviderRegistry.new/1`. A manifest may select their bounded
public names and JSON configuration, but it cannot provide executable callback
code. Register a builder only for authority the five built-in sources cannot
express; [Host configuration](host-configuration.md) covers what a plain
operator document already installs.

Builders receive the path-free application-content digest, target environment,
construction owner, effective limits, and installed ceilings. Application
directories and document readers never enter provider selection context;
provider-owned roots must come from trusted host installation. Builders may
return capabilities and a safe connector snapshot, plus an idempotent close
function when the provider owns live resources. The Kernel owns cleanup across
success, failure, timeout, cancellation, and owner death. Every close function
must return exactly `:ok`; another return, an exception, or an exit is reported
as `:provider_cleanup_failed` and can replace a completed run with the terminal
`:provider_cleanup_error` outcome. Cleanup still attempts every registered
resource. `ReplSession.close/1` and `abort/2` return
`{:error, :provider_cleanup_failed, events}` when that failure follows a
successfully frozen terminal batch; persist those canonical events before
surfacing the cleanup error.

Keep credentials, endpoints, native handles, and close functions out of
capability results, PTC-Lisp data, prompts, canonical events, and inspection
records.

## Drive REPL sessions programmatically

The interactive sessions described in the [Kernel REPL guide](kernel-repl.md)
are also available through `PtcRunner.Kernel.ReplSession`. Each session must
stay in the process that created it. That process performs every evaluation and
the final close or abort. Sending the struct to another process does not
transfer its continuation or cleanup authority; `eval/2`, `close/1`, and
`abort/2` return `{:error, :session_owner_mismatch}` without changing the
session.

The public value contains an opaque ID resolved through a shared table only the
creator can read; closed entries are deleted. It contains no owner PID, token,
continuation value, or raw run-state, configuration, sink, or provider
capability. The internal owner binds the run state to the configured event and
optional inspection sinks. Each `eval/2` result is an inert observation
projection; its memory is not the authoritative continuation and must not be
threaded back into the session. Preflight errors preserve the committed public
memory view, and projection is validated before continuation commit.

If the internal owner terminates before or during teardown, `close/1` reports
`{:error, :session_closed}` and `abort/2` returns `:ok`; both paths also remove
the creator-side lookup entry for the dead session.

If provider cleanup fails after terminal finalization, `close/1` and `abort/2`
return `{:error, :provider_cleanup_failed, events}` so the host can persist the
frozen batch before reporting the error. If an authorized trace cannot be
persisted after finalization, `close/1` and `abort/2` similarly return
`{:error, :trace_persistence_failed, events}` so the already frozen evidence is
not lost. The Mix frontend reports either failure after owner cleanup. Each
bounded worker starts a small
monitor-only watchdog before running the workload. The watchdog cancels the
worker when the creator exits, without changing its trap-exit behavior or
holding an unbounded workload copy, before retained resources are closed.

## Preserve the product boundary

Embedding should not move agent behavior back into Elixir. Keep prompts,
model-turn logic, retries, delegation, feedback, and task orchestration in
PTC-Lisp unless the behavior establishes native authority or enforces the
sandbox boundary.

## Next steps

- [Manifests and capabilities](manifests-and-capabilities.md) defines the
  strict manifest contract `RunBuilder` implements, so an embedded frontend
  accepts the same projects as `mix ptc run`.
- [Host configuration](host-configuration.md) defines the operator document
  `HostConfig` loads and `HostInstallation` turns into a provider registry.
- [Components and preludes](components-and-preludes.md) covers the bundle
  compiler that `compile_bundle/1` runs.
- [Running and debugging](running-and-debugging.md) documents the trace and
  inspection artifacts an embedded event sink produces.
- The [Kernel maintainer guide](kernel-maintainer.md) maps construction,
  ownership, lifecycle, observability, and extension points. Exact contracts
  live beside the public `PtcRunner.Kernel.*` modules.
