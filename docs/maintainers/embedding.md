# Embedding PtcRunner in Elixir

> **Audience:** package integrators and PtcRunner maintainers working with the
> host API or source-checkout tooling.

Use the Elixir API when an application needs custom providers, an HTTP or job
frontend, application-owned configuration, or integration with an existing
supervision tree. PTC-Lisp authors can normally use manifests and `mix ptc`
without writing Elixir.

The embedded path uses the same immutable bundles, separate environments,
limits, results, and event contracts as manifest execution.

## Run one workflow directly

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
    missions: %{"default" => mission},
    input: %{"input" => %{"n" => 21}},
    limits: limits,
    event_sink: sink
  )

{:ok, %{value: 42}} = Kernel.run("(example/run data/input)", config)
events = EventSink.events(sink)
EventSink.stop(sink)
```

The host creates every authority-bearing value. `PtcRunner.Kernel.run/2`
derives nothing from application environment, the process dictionary, or a
mission's sibling workflow environment. A `RunConfig` and its event sink are
one-shot; construct fresh values for every run.

The exact constructors, accepted options, and errors live with these public
modules:

- `PtcRunner.Kernel.Component`
- `PtcRunner.Kernel.WorkflowEnvironment`
- `PtcRunner.Kernel.MissionEnvironment`
- `PtcRunner.Kernel.Limits`
- `PtcRunner.Kernel.EventSink`
- `PtcRunner.Kernel.RunConfig`
- `PtcRunner.Kernel`

## Resolve shipped libraries

The direct example has no dependencies. Resolve the installed closure before
compiling components that use a shipped library:

```elixir
{:ok, components} =
  PtcRunner.Kernel.Library.resolve_components([{:library, "analysis"}])

{:ok, bundle} = PtcRunner.Kernel.compile_bundle(components)
```

`PtcRunner.Kernel.Library.component/1` returns one component without expanding
dependencies. `resolve_components/1` returns the closed component set that
`compile_bundle/1` requires.

## Prefer the manifest acquisition path

Use `PtcRunner.Kernel.ApplicationPackage.request_directory/2` or
`request_memory/3` when an embedded frontend should accept the same strict
manifest contract as the CLI. Each returns a sealed, path-free
`PtcRunner.Kernel.RunRequest`; pass it to
`PtcRunner.Kernel.RunBuilder.build/3` with a trusted provider registry.

Do not create a separate manifest loader, provider path, or event path in a web
controller or worker. `ApplicationPackage` owns bounded document acquisition
and input selection. `RunBuilder` owns provider resolution, compilation,
environment assembly, sinks, result projection, and cleanup.

Package acquisition and the `PtcRunner.Kernel.ProviderRegistry` passed to the
builder must use the same installed limit ceilings. Trusted embedding may
replace them for one construction only by supplying the same
`:installed_limits` to acquisition and `RunBuilder.build/3`.

Direct embedding defaults to native result projection. JSON-emitting commands
select JSON projection explicitly. Native projection supports continuation
values that JSON projection rejects; choose the projection at the frontend
boundary.

## Own provider applications

PtcRunner does not start optional provider dependencies merely because the
library is in your release. The CLI admits them through
`PtcRunner.Kernel.ProviderApplicationGate`; a frontend that drives
`ProviderRegistry` and `RunBuilder` directly owns that lifecycle.

The optional `c:PtcRunner.LLM.provider_application/1` callback reports whether a
configured model needs `:req_llm`. Start the application before dispatch. If
the host owns credential loading, disable dependency `.env` loading first:

```elixir
Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
Application.put_env(:llm_db, :load_dotenv, false, persistent: true)
{:ok, _started} = Application.ensure_all_started(:req_llm)
```

Command frontends read only the exact dotenv file named by `--env-file`; they
do not search for one. Embedded hosts do not load dotenv files implicitly and
must acquire environment-backed credentials themselves.

An unstarted required application is a non-retryable host configuration error,
not a transient model failure. Hosts that configure custom ReqLLM pools also
own their pool geometry; the CLI uses installed `live_provider_tasks`, not one
manifest's narrower limit, for its VM-lifetime pool.

An adapter may implement `c:PtcRunner.LLM.prepare_model/1` to resolve its model
selector once before requester construction. Return an immutable request target
and its catalog status; do not return processes, ports, credentials, or other
resources that need cleanup. `PtcRunner.LLM.callback/2` returns
`{:ok, requester}` only after preparation succeeds, so embedding callers must
propagate its error tuple before dispatch.

An adapter may implement `c:PtcRunner.LLM.public_model/1` to attest that its exact
configured target is safe to publish. Missing, altered, invalid, oversized, or
raising attestations remain private without preventing execution. Treat the
callback as information-release policy because targets may contain private
deployment data.

## Install custom providers only for native authority

`PtcRunner.Kernel.ProviderRegistry.new/2` accepts trusted staged builders keyed
by the bounded names a manifest may select. Register a builder only when the
built-in host installation sources cannot express the authority; ordinary
models, MCP servers, snapshots, traces, inspection sources, and replay belong
in [Host configuration](../guides/host-configuration.md).

Builders receive a path-free application digest, target environment, owner,
effective limits, and installed ceilings. They return bounded capabilities,
safe snapshots, and optional cleanup. Keep credentials, endpoints, handles,
and cleanup functions out of Lisp values, prompts, events, and inspection
records.

The Kernel owns returned resources across success, failure, timeout,
cancellation, and owner death. Cleanup must be idempotent and return exactly
`:ok`; cleanup failure can replace a completed run with
`:provider_cleanup_error`. The complete staged-builder, resource-registration,
data-policy, and cleanup contracts live in
`PtcRunner.Kernel.ProviderRegistry` and
`PtcRunner.Kernel.ResourceRegistrar`.

## Drive REPL sessions from one process

`PtcRunner.Kernel.ReplSession` provides the continuation used by the Kernel
REPL. The process that calls `new/1` must also call every `eval/2`, `close/1`,
and `abort/2`. Passing the public struct to another process does not transfer
continuation or cleanup authority.

Each evaluation returns an observation projection and updated public session;
the authoritative definitions and `*1`/`*2`/`*3` history stay inside the owner.
Call `close/1` for normal finalization or `abort/2` after an early frontend
exit. If trace persistence or provider cleanup fails after finalization, the
error includes the frozen terminal events so the host can preserve evidence.
See `PtcRunner.Kernel.ReplSession` for exact return shapes and failure modes.

## Start the Viewer

`ptc viewer PROJECT.json` covers the project-document case in both frontends.
An embedding host that has no project document can instead start the Viewer
directly with `PtcViewer.start/1`, supplying its trace and optional inspection
roots, the same private-data decision the command would make, and optionally
`:ip` to choose between the loopback default and `{0, 0, 0, 0}`. `PtcViewer` is
present in the standalone release and absent from the published Hex package, so
probe it with `Code.ensure_loaded?/1` before calling it.

## Keep policy in PTC-Lisp

Embedding should not move prompts, model-turn logic, retries, delegation, or
task orchestration into Elixir. Keep those policies in PTC-Lisp unless the code
establishes native authority or enforces the sandbox boundary.

## Materialize candidate source

The standalone executable can evaluate a candidate descriptor but does not
create one. In a source checkout, materialize model-authored source with:

```console
mix ptc.materialize ptc.json \
  --workflow \
  --component my.helper \
  --out private/candidate \
  --source authored.clj \
  --origin-run-id run-2026-08-03-0001
```

Select exactly one target with `--workflow` or `--target-mission NAME`.
Candidate source comes from `--source`, or from one string selected with
`--from-result PATH --result-pointer POINTER`. The new directory and both files
are owner-only and never replace an existing path.

The task re-acquires the candidate through its descriptor, verifies compilation
and prompt-visible contracts, and compares reachable effects with the base.
Effect widening requires `--accept-widened-effect`. The task creates evidence;
it never installs the candidate or acquires a provider.

## Next steps

- [Manifests and capabilities](../guides/manifests-and-capabilities.md) defines the
  strict manifest contract used by `RunBuilder`.
- [Host configuration](../guides/host-configuration.md) defines provider installations.
- [Running and debugging](../guides/running-and-debugging.md) covers trace and inspection
  artifacts.
- [Kernel maintainer](kernel.md) maps ownership, lifecycle, and
  extension points. Exact API contracts live with the public modules.
