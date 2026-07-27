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

## Prefer manifests for deployable projects

`PtcRunner.Kernel.RunBuilder` is the shared construction path for manifests and
current Mix frontends. Reuse it when an application wants the standard strict
manifest contract. Do not build a parallel loader or another provider and
event path in a web controller or job worker.

## Install custom providers

Custom provider builders are trusted Elixir functions registered through
`PtcRunner.Kernel.ProviderRegistry.new/1`. A manifest may select their bounded
public names and JSON configuration, but it cannot provide executable callback
code.

Builders receive the canonical manifest directory, target environment,
construction owner, effective limits, and installed ceilings. They may return
capabilities and a safe connector snapshot, plus an idempotent close function
when the provider owns live resources. The Kernel owns cleanup across success,
failure, timeout, cancellation, and owner death. Every close function must
return exactly `:ok`; another return, an exception, or an exit is reported as
`:provider_cleanup_failed` and can replace a completed run with the terminal
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

If provider cleanup fails after terminal finalization, `close/1` and `abort/2`
return `{:error, :provider_cleanup_failed, events}` so the host can persist the
frozen batch before reporting the error. The Mix frontend does this for normal
closure and exception-driven aborts. Each bounded worker starts a small
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
  accepts the same projects as `mix ptc.run`.
- [Components and preludes](components-and-preludes.md) covers the bundle
  compiler that `compile_bundle/1` runs.
- [Running and debugging](running-and-debugging.md) documents the trace and
  inspection artifacts an embedded event sink produces.
- The [Kernel maintainer guide](kernel-maintainer.md) maps construction,
  ownership, lifecycle, observability, and extension points. Exact contracts
  live beside the public `PtcRunner.Kernel.*` modules.
