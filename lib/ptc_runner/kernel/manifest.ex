defmodule PtcRunner.Kernel.Manifest do
  @moduledoc """
  Strict, path-confined version 1 JSON manifest loader.

  The supported top-level shape is:

      {
        "version": 1,
        "workflow": {
          "components": [
            {"id": "workflow.main", "path": "workflow.clj", "dependencies": ["agent.core"]},
            {"library": "agent.core"}
          ],
          "entry": "workflow.main/run"
        },
        "mission": {"components": [], "data": {}},
        "input": {"value": {}},
        "contracts": {
          "input_schema": {"path": "input.schema.json"},
          "result_schema": {"path": "result.schema.json"}
        },
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
  file in `path`. Optional manifest-local contracts validate input before
  provider activity and `Result.value` before publication. Contract schemas
  use the bounded `PtcRunner.Kernel.ValueContract` profile.

  Provider entries contain a bounded `name` and JSON `config`. The manifest can
  select only builders installed in `PtcRunner.Kernel.ProviderRegistry`; there
  are no implicit provider names. An MCP installation containing a write
  mapping requires an explicit, nonempty manifest `allow` list; omission is
  accepted only when every installed mapping is read-only. Installed MCP
  providers may accept a `model_visible` subset of their authorized `allow`
  names. Visibility controls discovery and model context only, never authority.
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

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ValueContract

  @max_manifest_bytes 1_000_000
  @max_input_bytes 2_000_000
  @max_contract_bytes 65_536
  @entry ~r/\A[a-z][a-z0-9._-]{0,127}\/[a-z][a-z0-9._?!-]{0,127}\z/
  @top_keys ~w($schema version workflow mission input contracts providers limits events labels)

  @enforce_keys [
    :document,
    :workflow_components,
    :workflow_component_kinds,
    :mission_components,
    :mission_component_kinds,
    :entry,
    :input_declaration,
    :input,
    :contracts,
    :contract_sources,
    :mission_data,
    :providers,
    :limits,
    :installed_limits,
    :events,
    :labels
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          document: map(),
          workflow_components: [Component.t()],
          workflow_component_kinds: %{binary() => :local | :library},
          mission_components: [Component.t()],
          mission_component_kinds: %{binary() => :local | :library},
          entry: binary(),
          input_declaration: map(),
          input: map() | nil,
          contracts: %{input: ValueContract.t() | nil, result: ValueContract.t() | nil},
          contract_sources: %{input: binary() | nil, result: binary() | nil},
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
    with {:ok, source} <- ApplicationSource.open_directory(path) do
      try do
        with {:ok, manifest} <- load_source(source, installed_limits),
             {:ok, _accounting} <- ApplicationSource.finish(source) do
          {:ok, manifest}
        end
      after
        ApplicationSource.close(source)
      end
    end
  end

  def load(_path, _installed_limits), do: {:error, :invalid_manifest}

  @doc """
  Loads one manifest from an in-memory portable logical-name/bytes map.

  Every supplied document must belong to the exact referenced closure; unused
  entries are rejected.
  """
  @spec load_memory(binary(), %{binary() => binary()}, Limits.t()) ::
          {:ok, t()} | {:error, term()}
  def load_memory(manifest_name, documents, installed_limits \\ Limits.installed_defaults())

  def load_memory(manifest_name, documents, %Limits{} = installed_limits) do
    with {:ok, source} <- ApplicationSource.open_memory(manifest_name, documents) do
      try do
        with {:ok, manifest} <- load_source(source, installed_limits),
             {:ok, _accounting} <- ApplicationSource.finish(source) do
          {:ok, manifest}
        end
      after
        ApplicationSource.close(source)
      end
    end
  end

  def load_memory(_manifest_name, _documents, _installed_limits),
    do: {:error, :invalid_manifest}

  @doc false
  @spec load_source(ApplicationSource.t(), Limits.t()) :: {:ok, t()} | {:error, term()}
  def load_source(source, installed_limits),
    do: load_source(source, installed_limits, materialize_input: true)

  @doc false
  @spec load_source(ApplicationSource.t(), Limits.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def load_source(%ApplicationSource{} = source, %Limits{} = installed_limits, opts)
      when is_list(opts) do
    materialize_input? = Keyword.get(opts, :materialize_input, true)

    with {:ok, raw} <- ApplicationSource.manifest(source),
         true <- byte_size(raw) <= @max_manifest_bytes,
         {:ok, manifest} <- StrictJSON.decode(raw),
         true <- is_map(manifest) and not is_struct(manifest),
         :ok <- exact_keys(manifest, @top_keys, ~w(version workflow input)),
         :ok <- optional_schema(manifest["$schema"]),
         1 <- manifest["version"],
         {:ok, workflow} <- workflow(manifest["workflow"], source),
         {:ok, mission} <- mission(Map.get(manifest, "mission", %{}), source),
         {:ok, contract_result} <- contracts(Map.get(manifest, "contracts", %{}), source),
         {:ok, input_declaration} <- input_declaration(manifest["input"]),
         {:ok, input} <-
           maybe_materialize_input(
             input_declaration,
             source,
             contract_result.contracts.input,
             materialize_input?
           ),
         {:ok, providers} <- providers(Map.get(manifest, "providers", %{})),
         {:ok, limits} <- limits(Map.get(manifest, "limits", %{}), installed_limits),
         {:ok, events} <- events(Map.get(manifest, "events", %{})),
         {:ok, labels} <- SafeMetadata.normalize_labels(Map.get(manifest, "labels", %{})) do
      {:ok,
       %__MODULE__{
         document: manifest,
         workflow_components: workflow.components,
         workflow_component_kinds: workflow.kinds,
         mission_components: mission.components,
         mission_component_kinds: mission.kinds,
         entry: workflow.entry,
         input_declaration: input_declaration,
         input: input,
         contracts: contract_result.contracts,
         contract_sources: contract_result.sources,
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

  def load_source(_source, _installed_limits, _opts), do: {:error, :invalid_manifest}

  defp optional_schema(nil), do: :ok

  defp optional_schema(value)
       when is_binary(value) and byte_size(value) in 1..2_048,
       do: if(String.valid?(value), do: :ok, else: {:error, :invalid_manifest})

  defp optional_schema(_value), do: {:error, :invalid_manifest}

  defp workflow(value, source) when is_map(value) do
    with :ok <- exact_keys(value, ~w(components entry), ~w(components entry)),
         {:ok, component_result} <- components(value["components"], source),
         entry when is_binary(entry) <- value["entry"],
         true <- String.valid?(entry),
         true <- entry =~ @entry do
      {:ok,
       %{components: component_result.components, kinds: component_result.kinds, entry: entry}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_workflow_manifest}
    end
  end

  defp workflow(_value, _source), do: {:error, :invalid_workflow_manifest}

  defp mission(value, source) when is_map(value) do
    with :ok <- exact_keys(value, ~w(components data), []),
         {:ok, component_result} <- components(Map.get(value, "components", []), source),
         data when is_map(data) <- Map.get(value, "data", %{}),
         {:ok, data} <- StrictJSON.admit(data),
         true <- JSONValue.map?(data) do
      {:ok, %{components: component_result.components, kinds: component_result.kinds, data: data}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_mission_manifest}
    end
  end

  defp mission(_value, _source), do: {:error, :invalid_mission_manifest}

  defp components(values, source) when is_list(values) and length(values) <= 128 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, selections} ->
      case component(value, source) do
        {:ok, selection} -> {:cont, {:ok, [selection | selections]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selections} ->
        selections = Enum.reverse(selections)
        local_ids = for {%Component{id: id}, :local} <- selections, into: MapSet.new(), do: id

        with {:ok, components} <-
               selections
               |> Enum.map(&elem(&1, 0))
               |> Library.resolve_components() do
          kinds =
            Map.new(components, fn component ->
              {component.id,
               if(MapSet.member?(local_ids, component.id), do: :local, else: :library)}
            end)

          {:ok, %{components: components, kinds: kinds}}
        end

      error ->
        error
    end
  end

  defp components(_values, _source), do: {:error, :invalid_components}

  defp component(%{"library" => library} = value, _source) do
    with :ok <- exact_keys(value, ~w(library), ~w(library)),
         true <- is_binary(library) and String.valid?(library) do
      {:ok, {{:library, library}, :library}}
    else
      _ -> {:error, :invalid_component}
    end
  end

  defp component(value, source) when is_map(value) do
    with :ok <- exact_keys(value, ~w(id path dependencies), ~w(id path)),
         path when is_binary(path) <- value["path"],
         {:ok, component_source} <-
           ApplicationSource.read_reference(source, path, 2_000_000),
         {:ok, component} <-
           Component.new(
             id: value["id"],
             source: component_source,
             dependencies: Map.get(value, "dependencies", []),
             origin: path
           ) do
      {:ok, {component, :local}}
    else
      _ -> {:error, :invalid_component}
    end
  end

  defp component(_value, _source), do: {:error, :invalid_component}

  defp input_declaration(%{"value" => value} = input) do
    with :ok <- exact_keys(input, ~w(value), ~w(value)),
         true <- is_map(value) and not is_struct(value) do
      {:ok, input}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input_declaration(%{"path" => path} = input) when is_binary(path) do
    with :ok <- exact_keys(input, ~w(path), ~w(path)),
         true <- ApplicationSource.valid_name?(path) do
      {:ok, input}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp input_declaration(_input), do: {:error, :invalid_input}

  defp maybe_materialize_input(_declaration, _source, _contract, false), do: {:ok, nil}

  defp maybe_materialize_input(declaration, source, contract, true) do
    with {:ok, input} <- materialize_input(declaration, source),
         :ok <- validate_input(contract, input) do
      {:ok, input}
    end
  end

  defp materialize_input(%{"value" => value}, _source) do
    with {:ok, value} <- StrictJSON.admit(value),
         true <- JSONValue.map?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp materialize_input(%{"path" => path}, source) do
    with {:ok, raw} <- ApplicationSource.read_reference(source, path, @max_input_bytes),
         {:ok, value} <- StrictJSON.decode(raw),
         true <- JSONValue.map?(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp materialize_input(_input, _source), do: {:error, :invalid_input}

  defp contracts(value, source) when is_map(value) do
    with :ok <- exact_keys(value, ~w(input_schema result_schema), []),
         {:ok, input, input_source} <- contract(Map.get(value, "input_schema"), source),
         {:ok, result, result_source} <- contract(Map.get(value, "result_schema"), source) do
      {:ok,
       %{
         contracts: %{input: input, result: result},
         sources: %{input: input_source, result: result_source}
       }}
    else
      {:error, :duplicate_json_key} = error -> error
      _invalid -> {:error, :invalid_contracts}
    end
  end

  defp contracts(_value, _source), do: {:error, :invalid_contracts}

  defp contract(nil, _source), do: {:ok, nil, nil}

  defp contract(%{"path" => path} = reference, source) when is_binary(path) do
    with :ok <- exact_keys(reference, ~w(path), ~w(path)),
         {:ok, raw} <- ApplicationSource.read_reference(source, path, @max_contract_bytes),
         {:ok, schema} <- StrictJSON.decode(raw),
         true <- is_map(schema) and not is_struct(schema),
         {:ok, contract} <- ValueContract.compile(schema) do
      {:ok, contract, raw}
    end
  end

  defp contract(_reference, _source), do: {:error, :invalid_contracts}

  defp validate_input(nil, _input), do: :ok

  defp validate_input(%ValueContract{} = contract, input) do
    if ValueContract.valid?(contract, input),
      do: :ok,
      else: {:error, :input_contract_failed}
  end

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

  @doc "Returns the generated JSON Schema 2020-12 structural manifest contract."
  @spec schema() :: map()
  def schema do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://ptc-runner.dev/schemas/ptc-application-manifest.schema.json",
      "title" => "PtcRunner application manifest",
      "description" =>
        "Model-authorable application selection. Runtime loading remains authoritative.",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["version", "workflow", "input"],
      "properties" => %{
        "$schema" => bounded_string(2_048),
        "version" => %{"const" => 1},
        "workflow" => workflow_schema(),
        "mission" => mission_schema(),
        "input" => input_schema(),
        "contracts" => contracts_schema(),
        "providers" => providers_schema(),
        "limits" => limits_schema(),
        "events" => events_schema(),
        "labels" => labels_schema()
      }
    }
  end

  defp workflow_schema do
    required_object(
      %{
        "components" => components_schema(),
        "entry" => %{
          "type" => "string",
          "pattern" => "^[a-z][a-z0-9._-]{0,127}/[a-z][a-z0-9._?!-]{0,127}$"
        }
      },
      ["components", "entry"]
    )
  end

  defp mission_schema do
    closed_object(%{
      "components" => components_schema(),
      "data" => %{"type" => "object"}
    })
  end

  defp components_schema do
    %{
      "type" => "array",
      "maxItems" => 128,
      "items" => %{
        "oneOf" => [
          required_object(%{"library" => component_id_schema()}, ["library"]),
          required_object(
            %{
              "id" => component_id_schema(),
              "path" => logical_name_schema(),
              "dependencies" => %{
                "type" => "array",
                "maxItems" => 128,
                "uniqueItems" => true,
                "items" => component_id_schema()
              }
            },
            ["id", "path"]
          )
        ]
      }
    }
  end

  defp input_schema do
    %{
      "oneOf" => [
        required_object(%{"value" => %{"type" => "object"}}, ["value"]),
        required_object(%{"path" => logical_name_schema()}, ["path"])
      ]
    }
  end

  defp contracts_schema do
    reference = required_object(%{"path" => logical_name_schema()}, ["path"])

    closed_object(%{
      "input_schema" => reference,
      "result_schema" => reference
    })
  end

  defp providers_schema do
    provider =
      required_object(%{"name" => component_id_schema(), "config" => %{"type" => "object"}}, [
        "name"
      ])

    closed_object(%{
      "workflow" => %{"type" => "array", "maxItems" => 32, "items" => provider},
      "mission" => %{"type" => "array", "maxItems" => 32, "items" => provider}
    })
  end

  defp limits_schema do
    properties =
      Limits.defaults()
      |> Map.from_struct()
      |> Map.new(fn {name, _value} ->
        {Atom.to_string(name), %{"type" => "integer", "minimum" => 1}}
      end)

    closed_object(properties)
  end

  defp events_schema do
    closed_object(%{
      "policy" => %{"enum" => ["normal", "private"], "default" => "normal"},
      "run_id" => bounded_string(256),
      "trace_id" => bounded_string(256)
    })
  end

  defp labels_schema do
    identifier = %{
      "type" => "string",
      "pattern" => "^(?:[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}|sha256:[0-9a-f]{64})$"
    }

    tags =
      closed_object(%{
        "environment" => %{"enum" => ~w(development test staging production)},
        "mode" => %{"enum" => ~w(agent deterministic direct wrapper repl)},
        "stage" => %{"enum" => ~w(started planning executing validating completed failed)},
        "suite" => %{"enum" => ~w(unit integration e2e conformance privacy)}
      })

    closed_object(%{
      "name" => identifier,
      "model" => identifier,
      "provider" => identifier,
      "tags" => tags
    })
  end

  defp required_object(properties, required) do
    properties
    |> closed_object()
    |> Map.put("required", required)
  end

  defp closed_object(properties),
    do: %{"type" => "object", "additionalProperties" => false, "properties" => properties}

  defp bounded_string(max_length),
    do: %{"type" => "string", "minLength" => 1, "maxLength" => max_length}

  defp logical_name_schema do
    bounded_string(1_024)
    |> Map.put("pattern", ApplicationSource.logical_name_pattern())
  end

  defp component_id_schema,
    do: %{"type" => "string", "pattern" => "^[a-z][a-z0-9._-]{0,127}$"}
end
