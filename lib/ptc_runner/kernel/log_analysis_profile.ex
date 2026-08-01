defmodule PtcRunner.Kernel.LogAnalysisProfile do
  @moduledoc """
  Fixed authority recipe for local log-analysis sessions.

  `log-analysis-v2` installs the shipped `cap`, `log.core`, and `log.analysis`
  mission components, four read-only snapshot capabilities, empty mission
  data, and the ordinary implicit mission introspection routes.
  """

  alias PtcRunner.Kernel.AnalysisProfile
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.TraceSnapshot

  @id "log-analysis-v2"
  @component_ids ["cap", "log.core", "log.analysis"]
  @namespaces ["cap", "log", "log.analysis"]
  @capabilities ~w(trace-counters trace-get-run trace-list-runs trace-list-turns)
  @persistence "canonical-trace-on-close"
  @result_policy "bounded-json-v1"

  @spec id() :: binary()
  def id, do: @id

  @doc false
  def component_ids, do: @component_ids

  @spec component_selections() :: [{:library, binary()}]
  def component_selections, do: Enum.map(@component_ids, &{:library, &1})

  @doc false
  def namespaces, do: @namespaces

  @spec explicit_capabilities() :: [binary()]
  def explicit_capabilities, do: @capabilities

  @spec persistence_policy() :: binary()
  def persistence_policy, do: @persistence

  @spec result_policy() :: binary()
  def result_policy, do: @result_policy

  @doc false
  def identity_extension, do: %{}

  @doc false
  def labels do
    %{
      "name" => "ptc.log-analysis.repl",
      "tags" => %{"mode" => "repl"}
    }
  end

  @doc false
  def invalid_profile_error, do: :invalid_log_analysis_profile

  @doc false
  def invalid_assembly_error, do: :invalid_log_analysis_assembly

  @doc false
  def invalid_source_error, do: :invalid_log_analysis_source

  @doc false
  def session_failed_error, do: :log_analysis_session_failed

  @doc false
  def session_closed_error, do: :log_analysis_session_closed

  @doc false
  def run_id_prefix, do: "log-analysis-"

  @doc false
  def usage_capability_key, do: :trace_calls

  @doc false
  def result_limit_message, do: "public evaluation result exceeded its byte limit"

  @doc false
  def resource_names, do: ["traces"]

  @doc false
  def frontend do
    %{
      input_modes: [:interactive, :eval, :load, :script, :stdin],
      output_formats: [:clojure, :jsonl],
      continue_on_error: :repeated_eval_only,
      private_terminal: :forbidden
    }
  end

  @doc "Returns the safe, static discovery contract for `log-analysis-v2`."
  @spec description() :: map()
  def description do
    %{
      "id" => @id,
      "summary" => "Analyze an immutable capture of canonical sanitized traces",
      "resources" => %{
        "traces" => %{
          "required" => true,
          "kind" => "normal-trace-directory",
          "summary" => "Immutable capture of canonical sanitized trace files"
        }
      },
      "components" => @component_ids,
      "namespaces" => @namespaces,
      "explicit_capabilities" => @capabilities,
      "limits" => limits() |> Map.from_struct() |> stringify_keys(),
      "persistence_policy" => @persistence,
      "result_policy" => @result_policy
    }
  end

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
  def capture(%{"traces" => directory} = resources, opts)
      when map_size(resources) == 1 and is_binary(directory) and is_list(opts) do
    case TraceSnapshot.start({:directory, directory},
           owner: self(),
           capture_hook: Keyword.get(opts, :capture_hook),
           listing_hook: Keyword.get(opts, :listing_hook)
         ) do
      {:ok, snapshot} ->
        case AnalysisResources.new(@id, %{traces: snapshot}) do
          {:ok, _resources} = success ->
            success

          {:error, _reason} = error ->
            TraceSnapshot.stop(snapshot)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def capture(_resources, _opts), do: {:error, :invalid_log_analysis_source}

  @doc false
  def capabilities(%AnalysisResources{} = resources) do
    resources
    |> AnalysisResources.handle(:traces)
    |> TraceCapability.from_snapshot()
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

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
