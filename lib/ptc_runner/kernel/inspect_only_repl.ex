defmodule PtcRunner.Kernel.InspectOnlyRepl do
  @moduledoc """
  Compile-and-inspect REPL preparation without providers or credentials.

  Acquires a package and compiles only the selected workflow or mission
  bundle. It does not call `PtcRunner.Kernel.RunCoordinator.prepare/2`, load
  a host document, start providers, grant workflow input, or install
  capabilities.
  """

  alias PtcRunner.Kernel.ApplicationPackage
  alias PtcRunner.Kernel.BundleCompiler
  alias PtcRunner.Kernel.ComponentCatalog
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ReplSession
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunCoordinator
  alias PtcRunner.Kernel.WorkflowEnvironment

  @compile_timeout_ms 5_000

  @startup_notice "compile-and-inspect environment; not a runnable application environment"

  @doc false
  @spec startup_notice() :: String.t()
  def startup_notice, do: @startup_notice

  @spec open(binary(), keyword()) :: {:ok, ReplSession.t()} | {:error, term()}
  def open(manifest_path, opts \\ [])

  def open(manifest_path, opts) when is_binary(manifest_path) and is_list(opts) do
    with :ok <- validate_opts(opts),
         {:ok, package, _input} <-
           ApplicationPackage.acquire_directory(manifest_path,
             installed_limits: Limits.installed_defaults(),
             omit_input: true,
             repl_interactive_loop: opts[:interactive_loop] == true
           ),
         {:ok, workflow, missions, mode} <- compile_selected(package, opts[:mission]),
         {:ok, sink} <- EventSink.start(:normal, package.limits) do
      start_session(workflow, missions, mode, package.limits, sink)
    end
  end

  def open(_manifest_path, _opts), do: {:error, :invalid_inspect_only_repl}

  defp start_session(workflow, missions, mode, limits, sink) do
    case RunConfig.new(
           workflow_environment: workflow,
           missions: missions,
           input: %{},
           limits: limits,
           event_sink: sink,
           result_projection: :native,
           inspect_only: true,
           labels: %{"name" => "ptc.repl"}
         ) do
      {:ok, config} ->
        case ReplSession.new(config: config, mode: mode) do
          {:ok, _session} = success ->
            success

          {:error, _reason} = error ->
            EventSink.stop(sink)
            error
        end

      {:error, _reason} = error ->
        EventSink.stop(sink)
        error
    end
  end

  defp validate_opts(opts) do
    allowed = [:mission, :interactive_loop]

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_inspect_only_repl}

      Keyword.keys(opts) -- allowed != [] ->
        {:error, :invalid_inspect_only_repl}

      not valid_optional_mission?(opts[:mission]) ->
        {:error, :invalid_inspect_only_repl}

      opts[:interactive_loop] not in [nil, true, false] ->
        {:error, :invalid_inspect_only_repl}

      true ->
        :ok
    end
  end

  defp valid_optional_mission?(nil), do: true
  defp valid_optional_mission?(name) when is_binary(name) and name != "", do: true
  defp valid_optional_mission?(_name), do: false

  defp compile_selected(package, nil) do
    deadline = System.monotonic_time(:millisecond) + @compile_timeout_ms

    with {:ok, bundle} <- BundleCompiler.compile(package.workflow_components, deadline),
         :ok <- RunCoordinator.validate_entry(bundle, package.entry),
         {:ok, _intern, catalog} <-
           ComponentCatalog.build(package.workflow_components, bundle),
         {:ok, workflow} <-
           WorkflowEnvironment.new(bundle: bundle, catalog: catalog, inspect_only: true) do
      declared_missions = package.missions |> Map.keys() |> Enum.sort()
      {:ok, workflow, %{}, %{kind: :workflow, declared_missions: declared_missions}}
    end
  end

  defp compile_selected(package, name) do
    case Map.fetch(package.missions, name) do
      {:ok, spec} ->
        compile_mission(name, spec)

      :error ->
        {:error,
         %{code: :unknown_mission, declared: package.missions |> Map.keys() |> Enum.sort()}}
    end
  end

  defp compile_mission(name, spec) do
    deadline = System.monotonic_time(:millisecond) + @compile_timeout_ms

    with {:ok, bundle} <- BundleCompiler.compile(spec.components, deadline),
         {:ok, _intern, catalog} <- ComponentCatalog.build(spec.components, bundle),
         {:ok, environment} <-
           MissionEnvironment.new(
             bundle: bundle,
             catalog: catalog,
             data: Map.get(spec, :data, %{}),
             inspect_only: true
           ),
         {:ok, workflow} <- WorkflowEnvironment.new([]) do
      mode = %{
        kind: :mission,
        name: name,
        component_ids: ComponentCatalog.ids(catalog),
        direct_provider_aliases: []
      }

      {:ok, workflow, %{name => environment}, mode}
    end
  end
end
