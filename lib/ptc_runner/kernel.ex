defmodule PtcRunner.Kernel do
  @moduledoc """
  Public execution boundary for bounded PTC-Lisp workflows.

  A host first compiles explicit `PtcRunner.Kernel.Component` values into
  immutable bundles, assembles separate workflow and mission environments,
  and supplies one validated `PtcRunner.Kernel.RunConfig` to `run/2`.

  The workflow environment contains trusted orchestration authority. The
  mission environment contains only the capabilities and data available to
  subordinate programs. `run/2` never derives authority from ambient process
  state.

  For the construction flow, ownership model, and internal module map, see the
  [Kernel maintainer guide](kernel.html).
  """

  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.Runner

  @doc """
  Compiles an explicit, closed component set into an immutable bundle.

  Component IDs are the dependency-graph identity. Compilation validates
  component bounds, dependencies, namespaces, exports, recorded tool
  requirements, provenance, and deterministic ordering. It does not grant
  capabilities; requirements are checked against actual grants when an
  environment is assembled.

  Bundle compilation has independent time, heap, source, artifact, and
  diagnostic limits. Errors are bounded diagnostic maps.
  """
  @spec compile_bundle([Component.t()]) :: {:ok, FrozenBundle.t()} | {:error, map()}
  def compile_bundle(components), do: BundleCompiler.compile(components)

  @doc """
  Runs one bounded workflow entry expression.

  The entry source executes with the workflow bundle, data, and capabilities
  in `config`. Calls across the reserved subordinate-evaluation boundary use
  only the mission environment. The run owns its resource counters,
  transactional native evaluation memory/history, deadline, and canonical
  events. Terminal publication is one atomic recorder operation: normal sinks
  reserve the loss summary and `run-stopped`, and no event can mutate the batch
  after finalization.

  Returns a bounded `PtcRunner.Kernel.Result` or
  `PtcRunner.Kernel.Error`. Capability failures normally remain recoverable
  Lisp values; workflow policy decides whether to retry, degrade, or fail. The
  supplied configuration is one-shot because this call finalizes its event
  sink; construct a fresh configuration for another run.
  """
  @spec run(binary(), RunConfig.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(entry_source, %RunConfig{} = config), do: Runner.run(entry_source, config)

  @doc false
  def run_and_events(entry_source, %RunConfig{} = config),
    do: Runner.run_and_events(entry_source, config)
end
