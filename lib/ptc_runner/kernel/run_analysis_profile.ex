defmodule PtcRunner.Kernel.RunAnalysisProfile do
  @moduledoc false

  alias PtcRunner.Kernel.AnalysisProfile
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceSnapshot

  @components ["cap", "analysis"]
  @namespaces ["analysis", "cap"]
  @capabilities ~w(
    analysis-activity
    analysis-conversation
    analysis-failure
    analysis-overview
    analysis-runs
    analysis-source
  )
  @persistence "canonical-trace-on-close"
  @trace_capture_policy "private-authorized-canonical-v1"

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    quote do
      alias PtcRunner.Kernel.RunAnalysisProfile

      def component_ids, do: RunAnalysisProfile.component_ids()
      def component_selections, do: RunAnalysisProfile.component_selections()
      def namespaces, do: RunAnalysisProfile.namespaces()
      def explicit_capabilities, do: RunAnalysisProfile.explicit_capabilities()
      def persistence_policy, do: RunAnalysisProfile.persistence_policy()
      def result_policy, do: RunAnalysisProfile.result_policy(unquote(kind))
      def identity_extension, do: RunAnalysisProfile.identity_extension(unquote(kind))
      def labels, do: RunAnalysisProfile.labels(unquote(kind))
      def resource_names, do: RunAnalysisProfile.resource_names(unquote(kind))
      def frontend, do: RunAnalysisProfile.frontend(unquote(kind))
      def description, do: RunAnalysisProfile.description(unquote(kind), __MODULE__)
      def limits, do: RunAnalysisProfile.limits()

      def capture(resources, opts),
        do: RunAnalysisProfile.capture(unquote(kind), __MODULE__, resources, opts)

      def capabilities(resources), do: RunAnalysisProfile.capabilities(resources)
      def assemble(resources, sink), do: RunAnalysisProfile.assemble(__MODULE__, resources, sink)

      def valid_assembly?(config, profile, resources, session_trace),
        do:
          RunAnalysisProfile.valid_assembly?(
            __MODULE__,
            config,
            profile,
            resources,
            session_trace
          )

      def usage_capability_key, do: :capability_calls
    end
  end

  def component_ids, do: @components
  def component_selections, do: Enum.map(@components, &{:library, &1})
  def namespaces, do: @namespaces
  def explicit_capabilities, do: @capabilities
  def persistence_policy, do: @persistence
  def resource_names(:public), do: ["traces"]
  def resource_names(:private), do: ["inspection", "traces"]

  def result_policy(:public), do: "bounded-json-v1"
  def result_policy(:private), do: "private-terminal-v1"

  def identity_extension(:public), do: %{}

  def identity_extension(:private) do
    %{
      "source_data_class" => "private_inspection",
      "result_data_class" => "private_inspection",
      "trace_capture_policy" => @trace_capture_policy
    }
  end

  def labels(:public), do: %{"name" => "ptc.run-analysis.repl", "tags" => %{"mode" => "repl"}}

  def labels(:private),
    do: %{"name" => "ptc.private-run-analysis.repl", "tags" => %{"mode" => "repl"}}

  def frontend(:public) do
    %{
      input_modes: [:interactive, :eval, :load, :script, :stdin],
      output_formats: [:clojure, :jsonl],
      continue_on_error: :repeated_eval_only,
      private_terminal: :forbidden
    }
  end

  def frontend(:private) do
    %{
      input_modes: [:interactive],
      output_formats: [:clojure],
      continue_on_error: :forbidden,
      private_terminal: :required
    }
  end

  def description(:public, recipe) do
    base_description(recipe, "Analyze an immutable capture of canonical sanitized traces")
    |> Map.put("resources", %{
      "traces" => %{
        "required" => true,
        "kind" => "normal-trace-directory",
        "summary" => "Immutable capture of canonical sanitized trace files"
      }
    })
  end

  def description(:private, recipe) do
    base_description(recipe, "Analyze exact private evidence correlated to canonical traces")
    |> Map.merge(identity_extension(:private))
    |> Map.put("resources", %{
      "traces" => %{
        "required" => true,
        "kind" => "private-authorized-trace-directory",
        "summary" => "Immutable capture of canonical normal and private trace files"
      },
      "inspection" => %{
        "required" => true,
        "kind" => "private-inspection-directory",
        "summary" => "Immutable private records validated against the trace capture"
      }
    })
  end

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

  def capture(:public, recipe, %{"traces" => directory} = resources, opts)
      when map_size(resources) == 1 and is_binary(directory) and is_list(opts) do
    capture_trace(recipe, {:directory, directory}, opts)
  end

  def capture(
        :private,
        recipe,
        %{"inspection" => inspection, "traces" => traces} = resources,
        opts
      )
      when map_size(resources) == 2 and is_binary(inspection) and is_binary(traces) and
             is_list(opts) do
    with {:ok, trace} <- start_trace({:private_authorized_directory, traces}, opts) do
      case AnalysisProfile.refuse_empty_capture(TraceSnapshot.info(trace), :empty_traces_resource) do
        :ok -> capture_inspection(recipe, trace, inspection, opts)
        {:error, _reason} = error -> stop_trace(trace, error)
      end
    end
  end

  def capture(_kind, recipe, _resources, _opts), do: {:error, recipe.invalid_source_error()}

  def capabilities(%AnalysisResources{} = resources) do
    RunAnalysisCapability.from_snapshots(
      AnalysisResources.handle(resources, :traces),
      AnalysisResources.handle(resources, :inspection)
    )
  end

  def assemble(recipe, resources, sink), do: AnalysisProfile.assemble(recipe, resources, sink)

  def valid_assembly?(recipe, config, profile, resources, session_trace),
    do: AnalysisProfile.valid_assembly?(recipe, config, profile, resources, session_trace)

  defp capture_trace(recipe, source, opts) do
    with {:ok, trace} <- start_trace(source, opts) do
      case AnalysisProfile.refuse_empty_capture(TraceSnapshot.info(trace), :empty_traces_resource) do
        :ok ->
          case AnalysisResources.new(recipe.id(), %{traces: trace}) do
            {:ok, _resources} = success -> success
            {:error, _reason} = error -> stop_trace(trace, error)
          end

        {:error, _reason} = error ->
          stop_trace(trace, error)
      end
    end
  end

  defp start_trace(source, opts) do
    TraceSnapshot.start(source,
      owner: self(),
      capture_hook: Keyword.get(opts, :capture_hook),
      listing_hook: Keyword.get(opts, :listing_hook)
    )
  end

  defp capture_inspection(recipe, trace, directory, opts) do
    case InspectionSnapshot.start({:directory, directory}, trace,
           owner: self(),
           capture_hook: Keyword.get(opts, :inspection_capture_hook),
           listing_hook: Keyword.get(opts, :inspection_listing_hook),
           artifact_verification_hook: Keyword.get(opts, :inspection_artifact_verification_hook)
         ) do
      {:ok, inspection} ->
        finish_private_capture(recipe, trace, inspection)

      {:error, _reason} = error ->
        stop_trace(trace, error)
    end
  end

  defp finish_private_capture(recipe, trace, inspection) do
    with :ok <-
           AnalysisProfile.refuse_empty_capture(
             InspectionSnapshot.info(inspection),
             :empty_inspection_resource
           ),
         {:ok, _resources} = success <-
           AnalysisResources.new(recipe.id(), %{traces: trace, inspection: inspection}) do
      success
    else
      {:error, _reason} = error ->
        InspectionSnapshot.stop(inspection)
        stop_trace(trace, error)
    end
  end

  defp stop_trace(trace, error) do
    TraceSnapshot.stop(trace)
    error
  end

  defp base_description(recipe, summary) do
    %{
      "id" => recipe.id(),
      "summary" => summary,
      "components" => @components,
      "namespaces" => @namespaces,
      "explicit_capabilities" => @capabilities,
      "limits" => limits() |> Map.from_struct() |> stringify_keys(),
      "persistence_policy" => @persistence,
      "result_policy" => recipe.result_policy()
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
