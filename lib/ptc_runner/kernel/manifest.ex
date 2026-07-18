defmodule PtcRunner.Kernel.Manifest do
  @moduledoc """
  Strict, path-confined version 1 JSON manifest loader.

  The supported top-level shape is:

      {
        "version": 1,
        "workflow": {
          "components": [
            {"id": "workflow.main", "path": "workflow.lisp", "dependencies": ["agent.core"]},
            {"library": "agent.core"}
          ],
          "entry": "workflow.main/run"
        },
        "mission": {"components": [], "data": {}},
        "input": {"value": {}},
        "providers": {"workflow": [], "mission": []},
        "limits": {},
        "events": {"policy": "normal"},
        "labels": {}
      }

  Required top-level fields are `version`, `workflow`, and `input`. Every
  object rejects unknown and duplicate keys.

  `workflow.components` and optional `mission.components` contain a strict
  tagged union: local `id`/`path`/optional `dependencies` objects or exact
  `{"library": id}` selections resolved only through
  `PtcRunner.Kernel.Library`. Installed dependencies expand deterministically;
  explicit duplicates, missing dependencies, cycles, and local/installed ID
  collisions fail loading. The workflow `entry` is a qualified function name;
  `PtcRunner.Kernel.RunBuilder` renders the executable entry expression. Input
  contains exactly one of a JSON object in `value` or a manifest-relative JSON
  file in `path`.

  Provider entries contain a bounded `name` and JSON `config`. The manifest can
  select only builders installed in `PtcRunner.Kernel.ProviderRegistry`.
  Built-in `file-read` accepts `root`, optional `max_bytes`, and optional
  `model_visible`; installed MCP providers may accept a `model_visible` subset
  of their authorized `allow` names. Visibility controls discovery and model
  context only, never authority.
  Limit names match `PtcRunner.Kernel.Limits`; version 1 accepts values no
  greater than the host-supplied installed ceilings. Omitted values use the
  normal runtime defaults, capped by a lower host ceiling. Event policy is
  `normal` or `private` with optional run and trace IDs. Labels use the closed
  `name`, `model`, `provider`, and flat `tags` safe-metadata profile. Identifier
  fields become SHA-256 fingerprints and tags use finite enumerated values, so
  arbitrary text and secrets are never copied into traces.

  The loader resolves paths relative to the canonical manifest directory and
  rejects absolute paths, traversal, devices, non-regular files, and symlink
  escape. Loading performs no workflow execution.
  """

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.FileCapability
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata

  @max_manifest_bytes 1_000_000
  @max_input_bytes 2_000_000
  @entry ~r/\A[a-z][a-z0-9._-]{0,127}\/[a-z][a-z0-9._?!-]{0,127}\z/
  @top_keys ~w(version workflow mission input providers limits events labels)

  @enforce_keys [
    :path,
    :directory,
    :workflow_components,
    :mission_components,
    :entry,
    :input,
    :mission_data,
    :providers,
    :limits,
    :installed_limits,
    :events,
    :labels
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          path: binary(),
          directory: binary(),
          workflow_components: [Component.t()],
          mission_components: [Component.t()],
          entry: binary(),
          input: map(),
          mission_data: map(),
          providers: %{workflow: [map()], mission: [map()]},
          limits: Limits.t(),
          installed_limits: Limits.t(),
          events: %{policy: :normal | :private, run_id: binary() | nil, trace_id: binary() | nil},
          labels: map()
        }

  @doc "Loads and validates one manifest and all referenced source/input files."
  @spec load(binary(), Limits.t()) :: {:ok, t()} | {:error, term()}
  def load(path, installed_limits \\ Limits.installed_defaults())

  def load(path, %Limits{} = installed_limits) when is_binary(path) do
    with {:ok, path} <- resolve_absolute(Path.expand(path)),
         directory = Path.dirname(path),
         {:ok, source} <- read_relative(directory, Path.basename(path), @max_manifest_bytes),
         {:ok, decoded} <- Jason.decode(source, objects: :ordered_objects),
         {:ok, manifest} <- ordered_map(decoded),
         :ok <- exact_keys(manifest, @top_keys, ~w(version workflow input)),
         1 <- manifest["version"],
         {:ok, workflow} <- workflow(manifest["workflow"], directory),
         {:ok, mission} <- mission(Map.get(manifest, "mission", %{}), directory),
         {:ok, input} <- input(manifest["input"], directory),
         {:ok, providers} <- providers(Map.get(manifest, "providers", %{})),
         {:ok, limits} <- limits(Map.get(manifest, "limits", %{}), installed_limits),
         {:ok, events} <- events(Map.get(manifest, "events", %{})),
         {:ok, labels} <- SafeMetadata.normalize_labels(Map.get(manifest, "labels", %{})) do
      {:ok,
       %__MODULE__{
         path: path,
         directory: directory,
         workflow_components: workflow.components,
         mission_components: mission.components,
         entry: workflow.entry,
         input: input,
         mission_data: mission.data,
         providers: providers,
         limits: limits,
         installed_limits: installed_limits,
         events: events,
         labels: labels
       }}
    else
      {:error, :invalid_safe_metadata} -> {:error, :invalid_manifest}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_manifest}
    end
  end

  def load(_path, _installed_limits), do: {:error, :invalid_manifest}

  @doc """
  Replaces the decoded input with a manifest-relative JSON object file.

  The same path confinement and input-size rules as `load/1` apply.
  """
  @spec override_input(t(), binary()) :: {:ok, t()} | {:error, term()}
  def override_input(%__MODULE__{} = manifest, path) when is_binary(path) do
    with {:ok, value} <- input(%{"path" => path}, manifest.directory),
         do: {:ok, %{manifest | input: value}}
  end

  def override_input(_manifest, _path), do: {:error, :invalid_input}

  defp workflow(value, directory) when is_map(value) do
    with :ok <- exact_keys(value, ~w(components entry), ~w(components entry)),
         {:ok, components} <- components(value["components"], directory),
         entry when is_binary(entry) <- value["entry"],
         true <- String.valid?(entry),
         true <- entry =~ @entry do
      {:ok, %{components: components, entry: entry}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_workflow_manifest}
    end
  end

  defp workflow(_value, _directory), do: {:error, :invalid_workflow_manifest}

  defp mission(value, directory) when is_map(value) do
    with :ok <- exact_keys(value, ~w(components data), []),
         {:ok, components} <- components(Map.get(value, "components", []), directory),
         data when is_map(data) <- Map.get(value, "data", %{}),
         true <- JSONValue.map?(data) do
      {:ok, %{components: components, data: data}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_mission_manifest}
    end
  end

  defp mission(_value, _directory), do: {:error, :invalid_mission_manifest}

  defp components(values, directory) when is_list(values) and length(values) <= 128 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, components} ->
      case component(value, directory) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, components} -> components |> Enum.reverse() |> Library.resolve_components()
      error -> error
    end
  end

  defp components(_values, _directory), do: {:error, :invalid_components}

  defp component(%{"library" => library} = value, _directory) do
    with :ok <- exact_keys(value, ~w(library), ~w(library)),
         true <- is_binary(library) and String.valid?(library) do
      {:ok, {:library, library}}
    else
      _ -> {:error, :invalid_component}
    end
  end

  defp component(value, directory) when is_map(value) do
    with :ok <- exact_keys(value, ~w(id path dependencies), ~w(id path)),
         path when is_binary(path) <- value["path"],
         {:ok, source} <- read_relative(directory, path, 2_000_000),
         {:ok, component} <-
           Component.new(
             id: value["id"],
             source: source,
             dependencies: Map.get(value, "dependencies", []),
             origin: path
           ) do
      {:ok, component}
    else
      _ -> {:error, :invalid_component}
    end
  end

  defp component(_value, _directory), do: {:error, :invalid_component}

  defp input(%{"value" => value} = input, _directory) do
    with :ok <- exact_keys(input, ~w(value), ~w(value)),
         true <- JSONValue.map?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(%{"path" => path} = input, directory) when is_binary(path) do
    with :ok <- exact_keys(input, ~w(path), ~w(path)),
         {:ok, source} <- read_relative(directory, path, @max_input_bytes),
         {:ok, decoded} <- Jason.decode(source, objects: :ordered_objects),
         {:ok, value} <- ordered_map(decoded),
         true <- JSONValue.map?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input(_input, _directory), do: {:error, :invalid_input}

  defp providers(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(workflow mission), []),
         {:ok, workflow} <- provider_list(Map.get(value, "workflow", [])),
         {:ok, mission} <- provider_list(Map.get(value, "mission", [])) do
      {:ok, %{workflow: workflow, mission: mission}}
    end
  end

  defp providers(_value), do: {:error, :invalid_providers}

  defp provider_list(values) when is_list(values) and length(values) <= 32 do
    with true <- Enum.all?(values, &provider?/1),
         names = Enum.map(values, & &1["name"]),
         true <- names == Enum.uniq(names) do
      {:ok, values}
    else
      _ -> {:error, :invalid_providers}
    end
  end

  defp provider_list(_values), do: {:error, :invalid_providers}

  defp provider?(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(name config), ~w(name)),
         name when is_binary(name) <- value["name"],
         true <- name =~ ~r/\A[a-z][a-z0-9._-]{0,127}\z/,
         true <- JSONValue.map?(Map.get(value, "config", %{})) do
      true
    else
      _invalid -> false
    end
  end

  defp provider?(_value), do: false

  defp limits(value, %Limits{} = installed_limits) when is_map(value) do
    ceilings = Map.from_struct(installed_limits)
    defaults = Limits.defaults() |> Map.from_struct()
    names = ceilings |> Map.keys() |> Map.new(&{Atom.to_string(&1), &1})

    ceilings_by_name =
      Map.new(ceilings, fn {name, ceiling} -> {Atom.to_string(name), ceiling} end)

    requested = Map.new(defaults, fn {name, default} -> {name, min(default, ceilings[name])} end)

    value
    |> Map.to_list()
    |> normalize_limits(names, ceilings_by_name, requested)
  end

  defp limits(_value, _installed_limits), do: {:error, :invalid_limits}

  defp normalize_limits([], _names, _ceilings, normalized), do: Limits.new(normalized)

  defp normalize_limits([{key, number} | rest], names, ceilings, normalized)
       when is_integer(number) and number > 0 do
    case {Map.fetch(names, key), Map.fetch(ceilings, key)} do
      {{:ok, name}, {:ok, ceiling}} when number <= ceiling ->
        normalize_limits(rest, names, ceilings, Map.put(normalized, name, number))

      _invalid ->
        {:error, :invalid_limits}
    end
  end

  defp normalize_limits(_values, _names, _ceilings, _normalized),
    do: {:error, :invalid_limits}

  defp events(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(policy run_id trace_id), []),
         policy when policy in ["normal", "private"] <- Map.get(value, "policy", "normal"),
         true <- optional_id?(Map.get(value, "run_id")),
         true <- optional_id?(Map.get(value, "trace_id")) do
      {:ok,
       %{
         policy: String.to_existing_atom(policy),
         run_id: Map.get(value, "run_id"),
         trace_id: Map.get(value, "trace_id")
       }}
    else
      _ -> {:error, :invalid_events}
    end
  end

  defp events(_value), do: {:error, :invalid_events}
  defp optional_id?(nil), do: true

  defp optional_id?(id) when is_binary(id) and byte_size(id) in 1..256,
    do: String.valid?(id)

  defp optional_id?(_id), do: false

  defp exact_keys(map, allowed, required) do
    keys = Map.keys(map)

    case {keys -- allowed, required -- keys} do
      {[], []} -> :ok
      _unknown_or_missing -> {:error, :unknown_or_missing_keys}
    end
  end

  defp ordered_map(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      pairs
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, map} ->
        case ordered_map(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(map, key, value)}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp ordered_map(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_map(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp ordered_map(value), do: {:ok, value}

  defp read_relative(directory, path, max_bytes) do
    with true <- is_binary(path),
         true <- String.valid?(path),
         true <- byte_size(path) in 1..1_024,
         {:ok, path} <- resolve_relative(directory, path),
         {:ok, capability} <- FileCapability.new(root: directory, max_bytes: max_bytes),
         {:ok, %{"content" => content}} <- capability.callback.(%{"path" => path}) do
      {:ok, content}
    else
      _ -> {:error, :unsafe_or_unreadable_path}
    end
  end

  defp resolve_absolute(path) do
    relative = Path.relative_to(path, "/")

    case resolve_segments("/", Path.split(relative), 0) do
      {:ok, relative} -> {:ok, Path.join("/", relative)}
      error -> error
    end
  end

  defp resolve_relative(directory, path),
    do: resolve_segments(directory, Path.split(path), 0)

  defp resolve_segments(_root, _segments, depth) when depth > 16,
    do: {:error, :symlink_depth_exceeded}

  defp resolve_segments(root, segments, depth) do
    Enum.reduce_while(segments, {:ok, {root, []}}, fn segment, {:ok, {parent, consumed}} ->
      candidate = Path.join(parent, segment)

      case File.lstat(candidate) do
        {:ok, %{type: :symlink}} ->
          with {:ok, target} <- File.read_link(candidate),
               target = Path.expand(target, parent),
               true <- within_root?(root, target) do
            remaining = Enum.drop(segments, length(consumed) + 1)
            target_segments = target |> Path.relative_to(root) |> Path.split()
            {:halt, resolve_segments(root, target_segments ++ remaining, depth + 1)}
          else
            _ -> {:halt, {:error, :symlink_escape}}
          end

        {:ok, _stat} ->
          {:cont, {:ok, {candidate, consumed ++ [segment]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {resolved, _consumed}} -> {:ok, Path.relative_to(resolved, root)}
      error -> error
    end
  end

  defp within_root?("/", target), do: Path.type(target) == :absolute

  defp within_root?(root, target) do
    if target == root, do: true, else: String.starts_with?(target, root <> "/")
  end
end
