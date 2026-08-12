defmodule PtcRunner.Kernel.InspectionAnalysisProfile do
  @moduledoc """
  Fixed private authority recipe for correlated trace and inspection analysis.

  `inspection-analysis-v3` captures one canonical trace directory and one
  private inspection directory, validates the private records against the
  captured canonical runs, and exposes the shipped primitive and bounded
  traversal functions for both sources. It grants no model, filesystem,
  network, MCP, write, or inspection-capture authority.

  It also installs `prompt.audit`, whose pure string functions measure a
  rendered system prompt. Reading one back out of a recorded run is an
  inspection query, so the measurement belongs to the session that can already
  reach the recorded model exchange rather than to a second tool.
  """

  alias PtcRunner.Kernel.AnalysisProfile
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.InspectionCapability
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceSnapshot

  @id "inspection-analysis-v3"
  @component_ids [
    "cap",
    "inspection.core",
    "inspection.analysis",
    "log.core",
    "log.analysis",
    "prompt.audit"
  ]
  @namespaces [
    "cap",
    "inspection",
    "inspection.analysis",
    "log",
    "log.analysis",
    "prompt.audit"
  ]
  @trace_capabilities ~w(trace-counters trace-get-run trace-list-runs trace-list-turns)
  @inspection_capabilities ~w(
    inspection-capability-calls
    inspection-effective-preludes
    inspection-execution-errors
    inspection-execution-prints
    inspection-generated-sources
    inspection-list-runs
    inspection-model-exchanges
    inspection-provider-exchanges
  )
  @capabilities Enum.sort(@trace_capabilities ++ @inspection_capabilities)
  @persistence "canonical-trace-on-close"
  @result_policy "private-terminal-v1"

  @spec id() :: binary()
  def id, do: @id

  @doc false
  def component_ids, do: @component_ids

  @doc false
  def component_selections, do: Enum.map(@component_ids, &{:library, &1})

  @doc false
  def namespaces, do: @namespaces

  @doc false
  def explicit_capabilities, do: @capabilities

  @doc false
  def persistence_policy, do: @persistence

  @doc false
  def result_policy, do: @result_policy

  @doc false
  def identity_extension do
    %{
      "source_data_class" => "private_inspection",
      "result_data_class" => "private_inspection"
    }
  end

  @doc false
  def labels do
    %{
      "name" => "ptc.inspection-analysis.repl",
      "tags" => %{"mode" => "repl"}
    }
  end

  @doc false
  def invalid_profile_error, do: :invalid_inspection_analysis_profile

  @doc false
  def invalid_assembly_error, do: :invalid_inspection_analysis_assembly

  @doc false
  def invalid_source_error, do: :invalid_inspection_analysis_source

  @doc false
  def session_failed_error, do: :inspection_analysis_session_failed

  @doc false
  def session_closed_error, do: :inspection_analysis_session_closed

  @doc false
  def run_id_prefix, do: "inspection-analysis-"

  @doc false
  def usage_capability_key, do: :capability_calls

  @doc false
  def result_limit_message,
    do: "private terminal evaluation result exceeded its byte limit"

  @doc false
  def resource_names, do: ["inspection", "traces"]

  @doc false
  def frontend do
    %{
      input_modes: [:interactive],
      output_formats: [:clojure],
      continue_on_error: :forbidden,
      private_terminal: :required
    }
  end

  @doc "Returns the safe, static discovery contract for `inspection-analysis-v3`."
  @spec description() :: map()
  def description do
    %{
      "id" => @id,
      "summary" => "Analyze exact private evidence correlated to canonical traces",
      "resources" => %{
        "traces" => %{
          "required" => true,
          "kind" => "normal-trace-directory",
          "summary" => "Immutable capture of canonical sanitized trace files"
        },
        "inspection" => %{
          "required" => true,
          "kind" => "private-inspection-directory",
          "summary" => "Immutable private records validated against the trace capture"
        }
      },
      "components" => @component_ids,
      "namespaces" => @namespaces,
      "explicit_capabilities" => @capabilities,
      "limits" => limits() |> Map.from_struct() |> stringify_keys(),
      "source_data_class" => "private_inspection",
      "result_data_class" => "private_inspection",
      "persistence_policy" => @persistence,
      "result_policy" => @result_policy
    }
  end

  @doc false
  def limits do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 1_800_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 64,
        subordinate_source_checks: 64,
        mission_capability_calls: 512,
        mission_capability_calls_per_name: 256,
        subordinate_source_bytes: 65_536,
        protocol_errors: 32,
        normal_event_count: 1_408
      )

    limits
  end

  @doc false
  def capture(
        %{"inspection" => inspection, "traces" => traces} = resources,
        opts
      )
      when map_size(resources) == 2 and is_binary(inspection) and is_binary(traces) and
             is_list(opts) do
    with {:ok, trace_snapshot} <-
           TraceSnapshot.start({:directory, traces},
             owner: self(),
             capture_hook: Keyword.get(opts, :capture_hook),
             listing_hook: Keyword.get(opts, :listing_hook)
           ) do
      case AnalysisProfile.refuse_empty_capture(
             TraceSnapshot.info(trace_snapshot),
             :empty_traces_resource
           ) do
        :ok ->
          capture_inspection(trace_snapshot, inspection, opts)

        {:error, _reason} = error ->
          TraceSnapshot.stop(trace_snapshot)
          error
      end
    end
  end

  def capture(_resources, _opts), do: {:error, :invalid_inspection_analysis_source}

  @doc false
  def capabilities(%AnalysisResources{} = resources) do
    with {:ok, trace_capabilities} <-
           resources
           |> AnalysisResources.handle(:traces)
           |> TraceCapability.from_snapshot(),
         {:ok, inspection_capabilities} <-
           resources
           |> AnalysisResources.handle(:inspection)
           |> InspectionCapability.from_snapshot() do
      {:ok, trace_capabilities ++ inspection_capabilities}
    end
  end

  @doc false
  def assemble(resources, sink), do: AnalysisProfile.assemble(__MODULE__, resources, sink)

  @doc false
  def valid_assembly?(config, profile, resources, session_trace) do
    AnalysisProfile.valid_assembly?(
      __MODULE__,
      config,
      profile,
      resources,
      session_trace
    )
  end

  defp capture_inspection(trace_snapshot, directory, opts) do
    case InspectionSnapshot.start({:directory, directory}, trace_snapshot,
           owner: self(),
           capture_hook: Keyword.get(opts, :inspection_capture_hook),
           listing_hook: Keyword.get(opts, :inspection_listing_hook)
         ) do
      {:ok, inspection_snapshot} ->
        with :ok <-
               AnalysisProfile.refuse_empty_capture(
                 InspectionSnapshot.info(inspection_snapshot),
                 :empty_inspection_resource
               ),
             {:ok, _resources} = success <-
               AnalysisResources.new(@id, %{
                 traces: trace_snapshot,
                 inspection: inspection_snapshot
               }) do
          success
        else
          {:error, _reason} = error ->
            InspectionSnapshot.stop(inspection_snapshot)
            TraceSnapshot.stop(trace_snapshot)
            error
        end

      {:error, _reason} = error ->
        TraceSnapshot.stop(trace_snapshot)
        error
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
