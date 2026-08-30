defmodule PtcRunner.Kernel.RunCatalogProfile do
  @moduledoc """
  Fixed private authority recipe for safe-metadata cohort discovery.

  The recipe captures exactly one immutable `RunCatalogSnapshot`, exposes the
  single `analysis-catalog` capability, and retains the private destination
  authorization used by the existing private analysis profile. Discovery does
  not admit a run and never opens a private payload.

  `analysis.catalog` is deliberately profile-local rather than a selectable
  `PtcRunner.Kernel.Library` component. Its backing requirement exists only in
  this closed recipe; registering it as a general library would advertise an
  export that no workflow or manifest environment is allowed to satisfy.
  """

  alias PtcRunner.Kernel.AnalysisProfile
  alias PtcRunner.Kernel.AnalysisResources
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.RunAnalysisProfile
  alias PtcRunner.Kernel.RunCatalog
  alias PtcRunner.Kernel.RunCatalogCapability
  alias PtcRunner.Kernel.RunCatalogSnapshot

  @id "private-run-catalog-v1"
  @components ["cap", "analysis.catalog"]
  @namespaces ["analysis", "cap"]
  @capabilities ["analysis-catalog"]
  @persistence "canonical-trace-on-close"
  @catalog_path Path.expand("../../../priv/preludes/kernel/analysis.catalog.clj", __DIR__)
  @external_resource @catalog_path
  @catalog_source File.read!(@catalog_path)

  def id, do: @id
  def component_ids, do: @components

  def component_selections do
    {:ok, catalog} =
      Component.new(
        id: "analysis.catalog",
        source: @catalog_source,
        dependencies: ["cap"],
        origin: "priv/preludes/kernel/analysis.catalog.clj"
      )

    [catalog, {:library, "cap"}]
  end

  def namespaces, do: @namespaces
  def explicit_capabilities, do: @capabilities
  def persistence_policy, do: @persistence
  def result_policy, do: "private-terminal-v1"

  def identity_extension do
    %{
      "source_data_class" => "private_inspection",
      "result_data_class" => "private_inspection",
      "catalog_generation" => RunCatalog.catalog_version()
    }
  end

  def labels,
    do: %{"name" => "ptc.private-run-catalog.repl", "tags" => %{"mode" => "repl"}}

  def resource_names, do: ["inspection", "traces"]
  def frontend, do: RunAnalysisProfile.frontend(:private)
  def limits, do: RunAnalysisProfile.limits()
  def usage_capability_key, do: :capability_calls

  def description do
    %{
      "id" => @id,
      "summary" => "Discover safe metadata in one immutable private run catalog",
      "components" => @components,
      "namespaces" => @namespaces,
      "explicit_capabilities" => @capabilities,
      "limits" => limits() |> Map.from_struct() |> stringify_keys(),
      "persistence_policy" => @persistence,
      "result_policy" => result_policy(),
      "resources" => %{
        "traces" => %{
          "required" => true,
          "kind" => "private-catalog-trace-directory",
          "summary" => "Bounded head and tail probes of canonical trace files"
        },
        "inspection" => %{
          "required" => true,
          "kind" => "private-catalog-inspection-directory",
          "summary" => "Bounded header and footer probes of sealed inspection files"
        }
      }
    }
    |> Map.merge(identity_extension())
  end

  def capture(
        %{"inspection" => inspection, "traces" => traces} = resources,
        opts
      )
      when map_size(resources) == 2 and is_binary(inspection) and is_binary(traces) and
             is_list(opts) do
    snapshot_opts =
      [owner: self()]
      |> put_optional(:listing_hook, Keyword.get(opts, :listing_hook))
      |> put_optional(:file_probe_hook, Keyword.get(opts, :file_probe_hook))
      |> put_optional(:max_result_bytes, Keyword.get(opts, :max_result_bytes))

    case RunCatalogSnapshot.start(
           {:private_authorized_catalog, traces, inspection},
           snapshot_opts
         ) do
      {:ok, catalog} ->
        case AnalysisResources.new(@id, %{catalog: catalog}) do
          {:ok, _resources} = success -> success
          {:error, _reason} = error -> stop_catalog(catalog, error)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def capture(_resources, _opts), do: {:error, invalid_source_error()}

  def capabilities(%AnalysisResources{} = resources) do
    resources
    |> AnalysisResources.handle(:catalog)
    |> RunCatalogCapability.from_snapshot()
  end

  def assemble(resources, sink), do: AnalysisProfile.assemble(__MODULE__, resources, sink)

  def valid_assembly?(config, profile, resources, session_trace),
    do: AnalysisProfile.valid_assembly?(__MODULE__, config, profile, resources, session_trace)

  def invalid_profile_error, do: :invalid_private_run_catalog_profile
  def invalid_assembly_error, do: :invalid_private_run_catalog_assembly
  def invalid_source_error, do: :invalid_private_run_catalog_source
  def session_failed_error, do: :private_run_catalog_session_failed
  def session_closed_error, do: :private_run_catalog_session_closed
  def run_id_prefix, do: "private-run-catalog-"
  def result_limit_message, do: "private catalog evaluation result exceeded its byte limit"

  defp stop_catalog(catalog, error) do
    RunCatalogSnapshot.stop(catalog)
    error
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
