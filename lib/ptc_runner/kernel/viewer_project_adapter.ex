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

  This is a display projection, not a compilation step. It parses the manifest
  JSON directly instead of building a bundle, so it can still describe a
  project that would fail to compile, and it never guesses: a tool effect is
  reported only where the host configuration states one, and a component
  source only where the file or shipped library is readable.
  """

  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits

  @type environment :: %{
          name: binary(),
          kind: binary(),
          components: [map()],
          providers: [map()],
          tools: [map()]
        }

  @type project :: %{
          name: binary(),
          manifest: binary(),
          entry: binary() | nil,
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
    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(raw),
         {:ok, limits} <- limit_rows(manifest) do
      install = install_entries(Keyword.get(opts, :host_config))

      {:ok,
       %{
         name: Keyword.get(opts, :name) || display_name(manifest, manifest_path),
         manifest: manifest_path,
         entry: get_in(manifest, ["workflow", "entry"]),
         environments: environments(manifest, Path.dirname(manifest_path), install),
         limits: limits
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_manifest}
    end
  end

  defp display_name(manifest, manifest_path) do
    get_in(manifest, ["labels", "name"]) || Path.basename(manifest_path)
  end

  # --- environments -------------------------------------------------------

  defp environments(manifest, dir, install) do
    providers = Map.get(manifest, "providers", %{})
    workflow_pool = list(Map.get(providers, "workflow"))
    mission_pool = list(Map.get(providers, "mission"))

    workflow =
      environment(
        "workflow",
        "workflow",
        Map.get(manifest, "workflow", %{}),
        workflow_pool,
        dir,
        install
      )

    missions =
      manifest
      |> Map.get("missions", %{})
      |> then(&if is_map(&1), do: &1, else: %{})
      |> Enum.sort_by(fn {name, _spec} -> name end)
      |> Enum.map(fn {name, spec} ->
        environment(name, "mission", spec, mission_providers(spec, mission_pool), dir, install)
      end)

    [workflow | missions]
  end

  # A mission selects from the manifest's declared mission providers by name;
  # without a selection it sees the whole pool.
  defp mission_providers(spec, pool) do
    case Map.get(spec, "providers") do
      names when is_list(names) -> Enum.filter(pool, &(&1["name"] in names))
      _unselected -> pool
    end
  end

  defp environment(name, kind, spec, providers, dir, install) do
    spec = if is_map(spec), do: spec, else: %{}

    %{
      name: name,
      kind: kind,
      components: spec |> Map.get("components") |> list() |> Enum.map(&component(&1, dir)),
      providers: Enum.map(providers, &provider(&1, install)),
      tools: tools(providers, install)
    }
  end

  defp provider(%{"name" => name}, install) do
    %{name: name, source: get_in(install, [name, "source"])}
  end

  defp provider(_declaration, _install), do: %{name: nil, source: nil}

  defp tools(providers, install) do
    providers
    |> Enum.flat_map(fn
      %{"name" => name} -> install |> get_in([name, "tools"]) |> map() |> Map.values()
      _declaration -> []
    end)
    |> Enum.map(&%{name: Map.get(&1, "as"), effect: Map.get(&1, "effect")})
    |> Enum.sort_by(&(&1.name || ""))
  end

  # --- components ---------------------------------------------------------

  defp component(%{"library" => name}, _dir) when is_binary(name) do
    case Library.component(name) do
      {:ok, component} ->
        %{id: name, library: true, path: component.origin, source: component.source}

      {:error, _reason} ->
        %{id: name, library: true, path: nil, source: nil}
    end
  end

  defp component(%{"id" => id, "path" => path}, dir) when is_binary(id) and is_binary(path) do
    %{id: id, library: false, path: path, source: read_source(Path.join(dir, path))}
  end

  defp component(_declaration, _dir),
    do: %{id: nil, library: false, path: nil, source: nil}

  defp read_source(path) do
    case File.read(path) do
      {:ok, source} -> source
      {:error, _reason} -> nil
    end
  end

  # --- limits -------------------------------------------------------------

  # Every catalog row is reported, so the panel can show the full table and
  # still lead with the rows a manifest actually moved.
  defp limit_rows(manifest) do
    with {:ok, overrides} <- limit_overrides(Map.get(manifest, "limits", %{})),
         {:ok, effective} <- Limits.new(overrides) do
      defaults = Limits.defaults()

      {:ok,
       Enum.map(LimitCatalog.rows(), fn row ->
         %{
           name: row.name,
           unit: row.unit,
           effective: Map.fetch!(effective, row.field),
           default: Map.fetch!(defaults, row.field)
         }
       end)}
    end
  end

  defp limit_overrides(declared) when is_map(declared) do
    Enum.reduce_while(declared, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case Limits.name(name) do
        {:ok, field} -> {:cont, {:ok, Map.put(acc, field, value)}}
        :error -> {:halt, {:error, :invalid_manifest}}
      end
    end)
  end

  defp limit_overrides(_declared), do: {:error, :invalid_manifest}

  # --- host configuration -------------------------------------------------

  defp install_entries(nil), do: %{}

  defp install_entries(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{"install" => install}} when is_map(install) <- Jason.decode(raw) do
      install
    else
      _unavailable -> %{}
    end
  end

  defp install_entries(_path), do: %{}

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
end
