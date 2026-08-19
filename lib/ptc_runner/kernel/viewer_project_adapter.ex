defmodule PtcRunner.Kernel.ViewerProjectAdapter do
  @moduledoc """
  Project details for the Viewer's Live tab (#1444).

  Reads a manifest — and optionally the host configuration that installs its
  providers — from disk, and projects what an operator wants beside a running
  dashboard: the environments the manifest declares, the components and
  shipped preludes each one compiles, the tools its providers install, and
  every Kernel limit with both its effective and its default value.

  Hosts wire the result into `PtcViewer.start/1` as a zero-arity function:

      project_adapter: fn -> ViewerProjectAdapter.describe("app/ptc.json") end

  This is a display projection, not a compilation step. It uses the canonical
  manifest and host loaders, so component sources keep the same confinement,
  size, UTF-8, and effective-limit contract as the run the Viewer launches. It
  can still describe a project that fails later compilation, and it never
  guesses a tool effect that the host did not install.
  """

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.Manifest
  alias PtcRunner.Kernel.SafeMetadata

  @type environment :: %{
          name: binary(),
          kind: binary(),
          components: [map()],
          providers: [map()],
          tools: [map()]
        }

  @type project :: %{
          name: binary(),
          name_fingerprint: binary() | nil,
          manifest: binary(),
          entry: binary(),
          input: map(),
          environments: [environment()],
          limits: [map()]
        }

  @doc """
  Describes the manifest at `manifest_path`.

  Options:

    * `:host_config` — path to the host configuration JSON whose `install`
      entries name the tools each provider exposes, with their effects.
      Without it, providers are reported by name and every `tools` list is
      empty rather than guessed.
    * `:name` — display name override; otherwise the manifest's
      `labels.name`, else the manifest's file name.

  The `manifest` field echoes the path exactly as configured, because that is
  the string the operator recognises.
  """
  @spec describe(binary(), keyword()) ::
          {:ok, project()} | {:error, :invalid_manifest | File.posix()}
  def describe(manifest_path, opts \\ []) when is_binary(manifest_path) do
    host = host_context(Keyword.get(opts, :host_config))

    case Manifest.load(manifest_path, host.limits) do
      {:ok, manifest} ->
        document = manifest.document
        label_name = get_in(document, ["labels", "name"])

        {:ok,
         %{
           name: Keyword.get(opts, :name) || display_name(document, manifest_path),
           name_fingerprint: if(label_name, do: SafeMetadata.fingerprint(label_name)),
           manifest: manifest_path,
           entry: manifest.entry,
           input: manifest.input,
           environments: environments(manifest, host.install),
           limits: limit_rows(manifest.limits, host.limits)
         }}

      {:error, :not_found} ->
        {:error, :enoent}

      {:error, _reason} ->
        {:error, :invalid_manifest}
    end
  end

  defp display_name(manifest, manifest_path) do
    get_in(manifest, ["labels", "name"]) || Path.basename(manifest_path)
  end

  # --- environments -------------------------------------------------------

  defp environments(%Manifest{} = manifest, install) do
    workflow =
      environment(
        "workflow",
        "workflow",
        get_in(manifest.document, ["workflow", "components"]),
        manifest.workflow_components,
        manifest.workflow_component_kinds,
        manifest.providers.workflow,
        install
      )

    missions =
      manifest.missions
      |> Enum.sort_by(fn {name, _spec} -> name end)
      |> Enum.map(fn {name, mission} ->
        providers =
          Enum.map(mission.provider_occurrences, &Enum.fetch!(manifest.providers.mission, &1))

        environment(
          name,
          "mission",
          get_in(manifest.document, ["missions", name, "components"]),
          mission.components,
          mission.kinds,
          providers,
          install
        )
      end)

    [workflow | missions]
  end

  defp environment(name, kind, declarations, components, kinds, providers, install) do
    %{
      name: name,
      kind: kind,
      components: project_components(declarations, components, kinds),
      providers: Enum.map(providers, &provider(&1, install)),
      tools: tools(providers, install)
    }
  end

  defp provider(%{"name" => name}, install) do
    source = install |> Map.get(name, %{}) |> Map.get(:source)
    %{name: name, source: source && to_string(source)}
  end

  defp provider(_declaration, _install), do: %{name: nil, source: nil}

  defp tools(providers, install) do
    providers
    |> Enum.flat_map(fn
      %{"name" => name} -> install |> Map.get(name, %{}) |> Map.get(:tools, %{}) |> Map.values()
      _declaration -> []
    end)
    |> Enum.map(&%{name: Map.get(&1, :as), effect: &1 |> Map.get(:effect) |> to_string()})
    |> Enum.sort_by(&(&1.name || ""))
  end

  # --- components ---------------------------------------------------------

  defp project_components(declarations, components, kinds) do
    by_id = Map.new(components, &{&1.id, &1})

    declarations
    |> list()
    |> Enum.map(fn declaration ->
      id = Map.get(declaration, "id") || Map.get(declaration, "library")
      component(Map.get(by_id, id), Map.get(kinds, id))
    end)
  end

  defp component(component, kind) when is_struct(component),
    do: %{
      id: component.id,
      library: kind == :library,
      path: component.origin,
      source: component.source
    }

  defp component(_component, _kind),
    do: %{id: nil, library: false, path: nil, source: nil}

  # --- limits -------------------------------------------------------------

  # Every catalog row is reported, so the panel can show the full table and
  # still lead with the rows a manifest actually moved. The installed ceiling
  # rides along only for application-narrowable rows: that is the answer to
  # "how much further can this manifest raise it?" Installed-only operational
  # timeouts have no application ceiling, and attaching one would make every
  # untouched host timeout look like an operator-gated row.
  defp limit_rows(effective, installed) do
    defaults = Limits.defaults()

    Enum.map(LimitCatalog.rows(), fn row ->
      %{
        name: row.name,
        unit: row.unit,
        effective: Map.fetch!(effective, row.field),
        default: Map.fetch!(defaults, row.field),
        ceiling: installed_ceiling(row, installed)
      }
    end)
  end

  defp installed_ceiling(%{scope: :manifest_narrowable, field: field}, installed),
    do: Map.fetch!(installed, field)

  defp installed_ceiling(_row, _installed), do: nil

  # --- host configuration -------------------------------------------------

  defp host_context(nil), do: %{limits: Limits.installed_defaults(), install: %{}}

  defp host_context(path) when is_binary(path) do
    case HostConfig.load(path) do
      {:ok, host} -> %{limits: host.limits, install: host.install}
      {:error, _reason} -> host_context(nil)
    end
  end

  defp host_context(_path), do: host_context(nil)

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []
end
