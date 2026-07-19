defmodule PtcRunner.Kernel.LogAnalysisProfile do
  @moduledoc """
  Fixed authority recipe for the local Viewer log-analysis session.

  `log-analysis-v1` installs only the shipped `log.core` mission component,
  four read-only snapshot capabilities, empty mission data, and the ordinary
  implicit mission introspection routes. The profile is application code, not
  browser or deployment data; changing its authority incompatibly requires a
  new profile ID.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SessionTrace
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Kernel.WorkflowEnvironment

  @id "log-analysis-v1"
  @capabilities ~w(trace-counters trace-get-run trace-list-runs trace-list-turns)
  @persistence "canonical-trace-on-close"
  @result_policy "bounded-json-v1"

  @spec id() :: binary()
  def id, do: @id

  @spec component_selections() :: [{:library, binary()}]
  def component_selections, do: [{:library, "log.core"}]

  @spec explicit_capabilities() :: [binary()]
  def explicit_capabilities, do: @capabilities

  @spec persistence_policy() :: binary()
  def persistence_policy, do: @persistence

  @spec result_policy() :: binary()
  def result_policy, do: @result_policy

  @spec limits() :: Limits.t()
  def limits do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 1_800_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 64,
        mission_capability_calls: 512,
        mission_capability_calls_per_name: 256,
        subordinate_source_bytes: 65_536,
        protocol_errors: 32,
        normal_event_count: 1_408
      )

    limits
  end

  @doc false
  @spec assemble(TraceSnapshot.t(), PtcRunner.Kernel.EventSink.t()) ::
          {:ok, %{config: RunConfig.t(), profile: map()}} | {:error, atom()}
  def assemble(%TraceSnapshot{} = snapshot, sink) do
    limits = limits()

    with {:ok, components} <- Library.resolve_components(component_selections()),
         {:ok, bundle} <- PtcRunner.Kernel.compile_bundle(components),
         {:ok, capabilities} <- TraceCapability.from_snapshot(snapshot),
         true <- capability_names(capabilities) == explicit_capabilities(),
         {:ok, mission} <-
           MissionEnvironment.new(bundle: bundle, capabilities: capabilities, data: %{}),
         {:ok, workflow} <- WorkflowEnvironment.new([]),
         {:ok, profile} <- descriptor(bundle, mission, limits),
         {:ok, config} <- fixed_config(workflow, mission, limits, sink, profile) do
      {:ok, %{config: config, profile: profile}}
    else
      _ -> {:error, :invalid_log_analysis_profile}
    end
  end

  @doc false
  @spec valid_assembly?(term(), term(), term(), term()) :: boolean()
  def valid_assembly?(config, profile, %TraceSnapshot{} = snapshot, session_trace) do
    with {:ok, sink} <- SessionTrace.sink(session_trace),
         {:ok, expected} <- assemble(snapshot, sink) do
      config === expected.config and profile === expected.profile
    else
      _ -> false
    end
  catch
    :exit, _reason -> false
  end

  def valid_assembly?(_config, _profile, _snapshot, _session_trace), do: false

  @doc false
  @spec descriptor(map(), map(), Limits.t()) :: {:ok, map()} | {:error, atom()}
  def descriptor(bundle, mission, %Limits{} = limits) do
    with {:ok, inventory} <- MissionInventory.build(mission, limits),
         identity = identity(bundle, inventory, limits),
         {:ok, encoded} <- DeterministicJSON.encode(identity) do
      digest = "sha256:" <> sha256(encoded)

      {:ok,
       %{
         id: @id,
         digest: digest,
         namespaces: namespaces(bundle),
         identity: identity,
         mission_inventory: inventory
       }}
    else
      _ -> {:error, :invalid_log_analysis_profile}
    end
  end

  defp identity(bundle, inventory, limits) do
    %{
      "profile_id" => @id,
      "bundle_hash" => bundle.hash,
      "mission_inventory_hash" => inventory.hash,
      "implicit_runtime" => RuntimeTools.mission_contract_descriptor(),
      "limits" => limits |> Map.from_struct() |> stringify_keys(),
      "explicit_capabilities" => @capabilities,
      "components" => ["log.core"],
      "mission_data" => %{},
      "persistence_policy" => @persistence,
      "result_policy" => @result_policy
    }
  end

  defp fixed_config(workflow, mission, limits, sink, profile) do
    RunConfig.new(
      workflow_environment: workflow,
      mission_environment: mission,
      input: %{},
      limits: limits,
      event_sink: sink,
      labels: %{
        "name" => "ptc.viewer.repl",
        "tags" => %{"mode" => "repl"}
      },
      session_profile: %{"id" => profile.id, "digest" => profile.digest}
    )
  end

  defp capability_names(capabilities),
    do: capabilities |> Enum.map(& &1.name) |> Enum.sort()

  defp namespaces(bundle) do
    bundle.components
    |> Enum.flat_map(& &1.namespaces)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
