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
  `PtcRunner.Kernel.Library`. Installed dependencies expand deterministically
  and their invalid closures fail loading. Explicit duplicates and
  local/installed ID collisions also fail loading; local missing dependencies
  and cycles survive until bounded bundle compilation. The workflow `entry` is
  a qualified function name; `PtcRunner.Kernel.RunBuilder` renders the
  executable entry expression. Input
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
  Limit names are the `:manifest_narrowable` rows in
  `PtcRunner.Kernel.LimitCatalog`; version 1 accepts values no greater than the
  host-supplied installed ceilings. Omitted values use the normal runtime
  defaults, capped by a lower host ceiling. Installed-only rows remain
  host-owned. Event policy is `normal` or `private` with optional run and trace
  IDs. Labels use the closed `name`, `model`, `provider`, and flat `tags`
  safe-metadata profile. Identifier fields become SHA-256 fingerprints and tags
  use finite enumerated values, so arbitrary text and secrets are never copied
  into traces.

  An application's own failure kinds and annotation types are declared by the
  component that emits them, in its `(ns ...)` metadata, not here — the
  manifest selects components, it does not restate their vocabulary.

  The loader resolves paths relative to the canonical manifest directory and
  rejects absolute paths, traversal, devices, non-regular files, and symlink
  escape. Loading performs no workflow execution.
  """

  alias PtcRunner.Kernel.ApplicationSource
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.LimitCatalog
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.SafeMetadata
  alias PtcRunner.Kernel.StrictJSON
  alias PtcRunner.Kernel.ValueContract

  @max_manifest_bytes 1_000_000
  @max_input_bytes 2_000_000
  @max_contract_bytes 65_536
  @component_id ~r/\A[a-z][a-z0-9._-]{0,127}\z/
  @entry ~r/\A[a-z][a-z0-9._-]{0,127}\/[a-z][a-z0-9._?!-]{0,127}\z/
  @top_keys ~w($schema version workflow mission input contracts providers limits events labels)
  @label_keys ~w(name model provider tags)
  @tag_keys ~w(environment mode stage suite)
  @label_identifier ~r/\A(?:[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,255}|sha256:[0-9a-f]{64})\z/
  @tag_values %{
    "environment" => ~w(development test staging production),
    "mode" => ~w(agent deterministic direct wrapper repl),
    "stage" => ~w(started planning executing validating completed failed),
    "suite" => ~w(unit integration e2e conformance privacy)
  }

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
    if Limits.valid?(installed_limits) do
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
    else
      {:error, :invalid_manifest}
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
    if Limits.valid?(installed_limits) do
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
    else
      {:error, :invalid_manifest}
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

    with :ok <- validate_installed_limits(installed_limits),
         {:ok, raw} <- ApplicationSource.manifest(source),
         true <- byte_size(raw) <= @max_manifest_bytes,
         {:ok, manifest} <- decode_manifest(raw),
         true <- is_map(manifest) and not is_struct(manifest),
         :ok <- root_keys(manifest, @top_keys, ~w(version workflow input)),
         :ok <- optional_schema(manifest),
         :ok <- version(manifest["version"]),
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
         {:ok, labels} <- labels(Map.get(manifest, "labels", %{})) do
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
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_manifest}
    end
  end

  def load_source(_source, _installed_limits, _opts), do: {:error, :invalid_manifest}

  defp validate_installed_limits(installed_limits) do
    if Limits.valid?(installed_limits), do: :ok, else: {:error, :invalid_limits}
  end

  defp decode_manifest(raw) do
    case StrictJSON.decode_with_locations(raw) do
      {:error, {:duplicate_json_key, path}} ->
        {:error, {:manifest_path, safe_manifest_path(path), :duplicate_json_key}}

      result ->
        result
    end
  end

  defp optional_schema(manifest) do
    case Map.fetch(manifest, "$schema") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) and byte_size(value) in 1..2_048 ->
        if String.valid?(value),
          do: :ok,
          else:
            manifest_value_error(
              [{:property, "$schema"}],
              :invalid_schema_identifier
            )

      {:ok, _value} ->
        manifest_value_error([{:property, "$schema"}], :invalid_schema_identifier)
    end
  end

  defp version(1), do: :ok

  defp version(_version),
    do: manifest_value_error([{:property, "version"}], :invalid_manifest_version)

  defp workflow(value, source) when is_map(value) do
    with :ok <- section_keys(value, "workflow", ~w(components entry), ~w(components entry)),
         {:ok, component_result} <- components(value["components"], source, :workflow),
         {:ok, entry} <- workflow_entry(value["entry"]) do
      {:ok,
       %{components: component_result.components, kinds: component_result.kinds, entry: entry}}
    end
  end

  defp workflow(_value, _source),
    do: manifest_value_error([{:property, "workflow"}], :invalid_workflow_manifest)

  defp workflow_entry(entry)
       when is_binary(entry) do
    if String.valid?(entry) and entry =~ @entry,
      do: {:ok, entry},
      else:
        manifest_value_error(
          [{:property, "workflow"}, {:property, "entry"}],
          :invalid_workflow_entry
        )
  end

  defp workflow_entry(_entry),
    do:
      manifest_value_error(
        [{:property, "workflow"}, {:property, "entry"}],
        :invalid_workflow_entry
      )

  defp mission(value, source) when is_map(value) do
    with :ok <- section_keys(value, "mission", ~w(components data), []),
         {:ok, component_result} <-
           components(Map.get(value, "components", []), source, :mission),
         {:ok, data} <- mission_data(Map.get(value, "data", %{})) do
      {:ok, %{components: component_result.components, kinds: component_result.kinds, data: data}}
    end
  end

  defp mission(_value, _source),
    do: manifest_value_error([{:property, "mission"}], :invalid_mission_manifest)

  defp mission_data(data) when is_map(data) and not is_struct(data) do
    case StrictJSON.admit(data) do
      {:ok, admitted} when is_map(admitted) -> {:ok, admitted}
      _invalid -> invalid_mission_data()
    end
  end

  defp mission_data(_data), do: invalid_mission_data()

  defp invalid_mission_data,
    do:
      manifest_value_error(
        [{:property, "mission"}, {:property, "data"}],
        :invalid_mission_data
      )

  defp components(values, source, destination)
       when is_list(values) and length(values) <= 128 do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, selections} ->
      case component(value, source) do
        {:ok, selection} ->
          {:cont, {:ok, [selection | selections]}}

        {:error, {:component_structure, reason}} ->
          path = [
            {:property, Atom.to_string(destination)},
            {:property, "components"},
            {:index, index}
          ]

          {:halt, {:error, {:manifest_path, path, reason}}}

        {:error, {:component_value, suffix, reason}} ->
          path = [
            {:property, Atom.to_string(destination)},
            {:property, "components"},
            {:index, index}
          ]

          {:halt, {:error, {:manifest_path, path ++ suffix, reason}}}

        {:error, _reason} = error ->
          {:halt, error}
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

  defp components(_values, _source, destination),
    do:
      manifest_value_error(
        [{:property, Atom.to_string(destination)}, {:property, "components"}],
        :invalid_components
      )

  defp component(%{"library" => library} = value, _source) do
    with :ok <- structural_keys(value, ~w(library), ~w(library)),
         :ok <- component_id(library, "library") do
      {:ok, {{:library, library}, :library}}
    else
      {:error, reason} -> {:error, {:component_structure, reason}}
      {:value_error, suffix, reason} -> {:error, {:component_value, suffix, reason}}
    end
  end

  defp component(value, source) when is_map(value) do
    with :ok <- structural_keys(value, ~w(id path dependencies), ~w(id path)),
         :ok <- component_id(value["id"], "id"),
         {:ok, path} <- component_path(value["path"]),
         :ok <- component_dependencies(Map.get(value, "dependencies", [])),
         {:ok, component_source} <- read_component_source(source, path),
         {:ok, component} <-
           Component.new(
             id: value["id"],
             source: component_source,
             dependencies: Map.get(value, "dependencies", []),
             origin: path
           ) do
      {:ok, {component, :local}}
    else
      {:error, :unknown_properties} ->
        {:error, {:component_structure, :unknown_properties}}

      {:error, {:required_property_missing, _name} = reason} ->
        {:error, {:component_structure, reason}}

      {:error, {:source_role, :component, _name, _reason}} = error ->
        error

      {:value_error, suffix, reason} ->
        {:error, {:component_value, suffix, reason}}

      _ ->
        {:error, :invalid_component}
    end
  end

  defp component(_value, _source),
    do: {:error, {:component_value, [], :invalid_component}}

  defp component_id(id, field) when is_binary(id) do
    if String.valid?(id) and id =~ @component_id,
      do: :ok,
      else: {:value_error, [{:property, field}], :invalid_component_id}
  end

  defp component_id(_id, field),
    do: {:value_error, [{:property, field}], :invalid_component_id}

  defp component_path(path) when is_binary(path) do
    if ApplicationSource.valid_name?(path),
      do: {:ok, path},
      else: {:value_error, [{:property, "path"}], :invalid_component_path}
  end

  defp component_path(_path),
    do: {:value_error, [{:property, "path"}], :invalid_component_path}

  defp component_dependencies(dependencies)
       when is_list(dependencies) and length(dependencies) <= 128 do
    cond do
      dependencies != Enum.sort(Enum.uniq(dependencies)) ->
        {:value_error, [{:property, "dependencies"}], :invalid_component_dependencies}

      invalid_index = Enum.find_index(dependencies, &(not valid_component_id?(&1))) ->
        {:value_error, [{:property, "dependencies"}, {:index, invalid_index}],
         :invalid_component_dependency}

      true ->
        :ok
    end
  end

  defp component_dependencies(_dependencies),
    do: {:value_error, [{:property, "dependencies"}], :invalid_component_dependencies}

  defp valid_component_id?(id),
    do: is_binary(id) and String.valid?(id) and id =~ @component_id

  defp structural_keys(map, allowed, required) do
    case exact_keys(map, allowed, required) do
      {:error, :required_properties_missing} ->
        missing = Enum.find(required, &(not Map.has_key?(map, &1)))
        {:error, {:required_property_missing, missing}}

      result ->
        result
    end
  end

  defp read_component_source(source, path) do
    case ApplicationSource.read_reference(source, path, 2_000_000) do
      {:ok, _source} = success ->
        success

      {:error, :invalid_logical_name} ->
        {:error, {:source_role, :component, path, :reference_missing}}

      {:error, reason} ->
        {:error, {:source_role, :component, path, reason}}
    end
  end

  defp input_declaration(%{"value" => value} = input) do
    with :ok <- section_keys(input, "input", ~w(value), ~w(value)),
         :ok <- inline_input(value) do
      {:ok, input}
    else
      {:error, {:manifest_path, _path, _reason}} = error -> error
    end
  end

  defp input_declaration(%{"path" => path} = input) do
    with :ok <- section_keys(input, "input", ~w(path), ~w(path)),
         :ok <- input_path(path) do
      {:ok, input}
    else
      {:error, {:manifest_path, _path, _reason}} = error -> error
    end
  end

  defp input_declaration(input) when is_map(input) and not is_struct(input) do
    case section_keys(input, "input", ~w(value path), []) do
      :ok -> invalid_input_declaration()
      {:error, {:manifest_path, _path, _reason}} = error -> error
    end
  end

  defp input_declaration(_input), do: invalid_input_declaration()

  defp invalid_input_declaration do
    {:error, {:manifest_path, [{:property, "input"}], :invalid_input_declaration}}
  end

  defp inline_input(value) when is_map(value) and not is_struct(value), do: :ok

  defp inline_input(_value),
    do:
      manifest_value_error(
        [{:property, "input"}, {:property, "value"}],
        :invalid_input_declaration
      )

  defp input_path(path) when is_binary(path) do
    if ApplicationSource.valid_name?(path),
      do: :ok,
      else:
        manifest_value_error(
          [{:property, "input"}, {:property, "path"}],
          :invalid_input_declaration
        )
  end

  defp input_path(_path),
    do:
      manifest_value_error(
        [{:property, "input"}, {:property, "path"}],
        :invalid_input_declaration
      )

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
    with :ok <- section_keys(value, "contracts", ~w(input_schema result_schema), []),
         {:ok, input, input_source} <-
           optional_contract(value, "input_schema", source, :input_contract),
         {:ok, result, result_source} <-
           optional_contract(value, "result_schema", source, :result_contract) do
      {:ok,
       %{
         contracts: %{input: input, result: result},
         sources: %{input: input_source, result: result_source}
       }}
    else
      {:error, {:source_role, _role, _name, _reason}} = error ->
        error

      {:error, {:manifest_path, _path, _reason}} = error ->
        error
    end
  end

  defp contracts(_value, _source),
    do: {:error, {:manifest_path, [{:property, "contracts"}], :invalid_contracts_section}}

  defp optional_contract(contracts, name, source, role) do
    case Map.fetch(contracts, name) do
      :error -> {:ok, nil, nil}
      {:ok, reference} -> contract(reference, source, role)
    end
  end

  defp contract(reference, source, role) when is_map(reference) do
    case structural_keys(reference, ~w(path), ~w(path)) do
      :ok ->
        contract_path(reference["path"], source, role)

      {:error, reason} ->
        {:error, {:manifest_path, contract_reference_path(role), reason}}
    end
  end

  defp contract(_reference, _source, role),
    do: {:error, {:manifest_path, contract_reference_path(role), :invalid_contract_reference}}

  defp contract_path(path, source, role) when is_binary(path) do
    if ApplicationSource.valid_name?(path),
      do: load_contract(source, role, path),
      else: invalid_contract_path(role)
  end

  defp contract_path(_path, _source, role), do: invalid_contract_path(role)

  defp invalid_contract_path(role) do
    {:error,
     {:manifest_path, contract_reference_path(role) ++ [{:property, "path"}],
      :invalid_contract_reference}}
  end

  defp contract_reference_path(:input_contract),
    do: [{:property, "contracts"}, {:property, "input_schema"}]

  defp contract_reference_path(:result_contract),
    do: [{:property, "contracts"}, {:property, "result_schema"}]

  defp load_contract(source, role, path) do
    result =
      with {:ok, raw} <- ApplicationSource.read_reference(source, path, @max_contract_bytes),
           {:ok, schema} <- StrictJSON.decode(raw),
           true <- is_map(schema) and not is_struct(schema),
           {:ok, contract} <- ValueContract.compile(schema) do
        {:ok, contract, raw}
      end

    case result do
      {:ok, _contract, _raw} = success ->
        success

      {:error, reason} ->
        {:error, {:source_role, role, path, reason}}

      _invalid ->
        {:error, {:source_role, role, path, :invalid_contracts}}
    end
  end

  defp validate_input(nil, _input), do: :ok

  defp validate_input(%ValueContract{} = contract, input) do
    if ValueContract.valid?(contract, input),
      do: :ok,
      else: {:error, :input_contract_failed}
  end

  defp providers(value) when is_map(value) do
    with :ok <- section_keys(value, "providers", ~w(workflow mission), []),
         {:ok, workflow} <- provider_list(Map.get(value, "workflow", []), :workflow),
         {:ok, mission} <- provider_list(Map.get(value, "mission", []), :mission) do
      {:ok, %{workflow: workflow, mission: mission}}
    end
  end

  defp providers(_value),
    do: manifest_value_error([{:property, "providers"}], :invalid_providers)

  defp provider_list(values, destination) when is_list(values) and length(values) <= 32 do
    with :ok <- validate_provider_entries(values, destination) do
      names = Enum.map(values, & &1["name"])

      if names == Enum.uniq(names),
        do: {:ok, values},
        else:
          manifest_value_error(
            [{:property, "providers"}, {:property, Atom.to_string(destination)}],
            :invalid_providers
          )
    end
  end

  defp provider_list(_values, destination),
    do:
      manifest_value_error(
        [{:property, "providers"}, {:property, Atom.to_string(destination)}],
        :invalid_providers
      )

  defp validate_provider_entries(values, destination) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case provider(value) do
        :ok ->
          {:cont, :ok}

        {:error, {:provider_structure, reason}} ->
          path = [
            {:property, "providers"},
            {:property, Atom.to_string(destination)},
            {:index, index}
          ]

          {:halt, {:error, {:manifest_path, path, reason}}}

        {:error, {:provider_value, suffix, reason}} ->
          path = [
            {:property, "providers"},
            {:property, Atom.to_string(destination)},
            {:index, index}
          ]

          {:halt, {:error, {:manifest_path, path ++ suffix, reason}}}
      end
    end)
  end

  defp provider(value) when is_map(value) do
    with :ok <- structural_keys(value, ~w(name config), ~w(name)),
         :ok <- provider_name(value["name"]),
         :ok <- provider_config(Map.get(value, "config", %{})) do
      :ok
    else
      {:error, reason} -> {:error, {:provider_structure, reason}}
      {:value_error, suffix, reason} -> {:error, {:provider_value, suffix, reason}}
    end
  end

  defp provider(_value),
    do: {:error, {:provider_value, [], :invalid_provider}}

  defp provider_name(name) when is_binary(name) do
    if String.valid?(name) and name =~ @component_id,
      do: :ok,
      else: {:value_error, [{:property, "name"}], :invalid_provider_name}
  end

  defp provider_name(_name),
    do: {:value_error, [{:property, "name"}], :invalid_provider_name}

  defp provider_config(config) do
    if JSONValue.map?(config),
      do: :ok,
      else: {:value_error, [{:property, "config"}], :invalid_provider_config}
  end

  defp limits(value, %Limits{} = installed_limits) when is_map(value) do
    ceilings = Map.from_struct(installed_limits)
    defaults = Limits.defaults() |> Map.from_struct()
    manifest_rows = LimitCatalog.rows(:manifest_narrowable)
    names = Map.new(manifest_rows, &{&1.name, &1.field})

    ceilings_by_name =
      Map.new(manifest_rows, &{&1.name, Map.fetch!(ceilings, &1.field)})

    requested =
      Map.new(LimitCatalog.rows(), fn row ->
        value =
          case row.scope do
            :manifest_narrowable ->
              min(Map.fetch!(defaults, row.field), Map.fetch!(ceilings, row.field))

            :installed_only ->
              Map.fetch!(ceilings, row.field)
          end

        {row.field, value}
      end)

    with :ok <- section_keys(value, "limits", LimitCatalog.names(:manifest_narrowable), []) do
      value
      |> Map.to_list()
      |> Enum.sort_by(&elem(&1, 0))
      |> normalize_limits(names, ceilings_by_name, requested)
    end
  end

  defp limits(_value, _installed_limits),
    do: manifest_value_error([{:property, "limits"}], :invalid_limits)

  defp normalize_limits([], _names, _ceilings, normalized), do: Limits.new(normalized)

  defp normalize_limits([{key, number} | rest], names, ceilings, normalized) do
    case {Map.fetch(names, key), Map.fetch(ceilings, key), number} do
      {{:ok, name}, {:ok, ceiling}, number}
      when is_integer(number) and number > 0 and number <= ceiling ->
        normalize_limits(rest, names, ceilings, Map.put(normalized, name, number))

      _invalid ->
        manifest_value_error(
          [{:property, "limits"}, {:property, key}],
          :invalid_limits
        )
    end
  end

  defp events(value) when is_map(value) do
    with :ok <- section_keys(value, "events", ~w(policy run_id trace_id), []),
         {:ok, policy} <- event_policy(Map.get(value, "policy", "normal")),
         :ok <- event_id(value, "run_id"),
         :ok <- event_id(value, "trace_id") do
      {:ok,
       %{
         policy: policy,
         run_id: Map.get(value, "run_id"),
         trace_id: Map.get(value, "trace_id")
       }}
    end
  end

  defp events(_value),
    do: manifest_value_error([{:property, "events"}], :invalid_events)

  defp event_policy(policy) when policy in ["normal", "private"],
    do: {:ok, String.to_existing_atom(policy)}

  defp event_policy(_policy),
    do:
      manifest_value_error(
        [{:property, "events"}, {:property, "policy"}],
        :invalid_event_policy
      )

  defp event_id(events, field) do
    case Map.fetch(events, field) do
      :error ->
        :ok

      {:ok, id} when is_binary(id) and byte_size(id) in 1..256 ->
        if String.valid?(id),
          do: :ok,
          else:
            manifest_value_error(
              [{:property, "events"}, {:property, field}],
              :invalid_event_id
            )

      {:ok, _id} ->
        manifest_value_error(
          [{:property, "events"}, {:property, field}],
          :invalid_event_id
        )
    end
  end

  defp labels(value) when is_map(value) and not is_struct(value) do
    with :ok <- section_keys(value, "labels", @label_keys, []),
         :ok <- label_identifiers(value),
         :ok <- label_tags(value),
         {:ok, labels} <- SafeMetadata.normalize_labels(value) do
      {:ok, labels}
    else
      {:error, :invalid_safe_metadata} ->
        manifest_value_error([{:property, "labels"}], :invalid_manifest)

      {:error, _reason} = error ->
        error
    end
  end

  defp labels(_value),
    do: manifest_value_error([{:property, "labels"}], :invalid_manifest)

  defp label_identifiers(labels) do
    Enum.reduce_while(~w(name model provider), :ok, fn name, :ok ->
      case Map.fetch(labels, name) do
        :error ->
          {:cont, :ok}

        {:ok, value} when is_binary(value) ->
          if String.valid?(value) and value =~ @label_identifier,
            do: {:cont, :ok},
            else: {:halt, invalid_label(name)}

        {:ok, _value} ->
          {:halt, invalid_label(name)}
      end
    end)
  end

  defp invalid_label(name),
    do:
      manifest_value_error(
        [{:property, "labels"}, {:property, name}],
        :invalid_manifest
      )

  defp label_tags(labels) do
    case Map.fetch(labels, "tags") do
      :error -> :ok
      {:ok, tags} -> validate_label_tags(tags)
    end
  end

  defp validate_label_tags(tags) when is_map(tags) and not is_struct(tags) do
    with :ok <-
           section_keys(
             tags,
             [{:property, "labels"}, {:property, "tags"}],
             @tag_keys,
             []
           ) do
      Enum.reduce_while(@tag_keys, :ok, fn name, :ok ->
        case validate_label_tag(tags, name) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp validate_label_tags(_tags),
    do:
      manifest_value_error(
        [{:property, "labels"}, {:property, "tags"}],
        :invalid_manifest
      )

  defp validate_label_tag(tags, name) do
    allowed = Map.fetch!(@tag_values, name)

    case Map.fetch(tags, name) do
      :error -> :ok
      {:ok, value} -> if(value in allowed, do: :ok, else: invalid_label_tag(name))
    end
  end

  defp invalid_label_tag(name),
    do:
      manifest_value_error(
        [{:property, "labels"}, {:property, "tags"}, {:property, name}],
        :invalid_manifest
      )

  defp manifest_value_error(path, reason),
    do: {:error, {:manifest_path, path, reason}}

  defp section_keys(map, section, allowed, required) when is_binary(section),
    do: section_keys(map, [{:property, section}], allowed, required)

  defp section_keys(map, path, allowed, required) when is_list(path) do
    case structural_keys(map, allowed, required) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_path, path, reason}}
    end
  end

  defp root_keys(map, allowed, required) do
    case structural_keys(map, allowed, required) do
      :ok ->
        :ok

      {:error, {:required_property_missing, _name} = reason} ->
        {:error, {:manifest_path, [], reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp exact_keys(map, allowed, required) do
    keys = Map.keys(map)

    case {keys -- allowed, required -- keys} do
      {[], []} -> :ok
      {[_unknown | _rest], _missing} -> {:error, :unknown_properties}
      {[], [_missing | _rest]} -> {:error, :required_properties_missing}
    end
  end

  defp safe_manifest_path(path), do: safe_schema_path(path, schema(), [])

  defp safe_schema_path([], _schema, retained), do: Enum.reverse(retained)

  defp safe_schema_path([segment | rest], schema, retained) do
    case next_schema(schema, segment) do
      {:ok, child} when is_binary(segment) ->
        safe_schema_path(rest, child, [{:property, segment} | retained])

      {:ok, child} when is_integer(segment) and segment >= 0 ->
        safe_schema_path(rest, child, [{:index, segment} | retained])

      :error ->
        Enum.reverse(retained)
    end
  end

  defp next_schema(%{"properties" => properties}, segment)
       when is_map(properties) and is_binary(segment),
       do: Map.fetch(properties, segment)

  defp next_schema(%{"items" => items}, segment) when is_integer(segment) and segment >= 0,
    do: {:ok, items}

  defp next_schema(%{"oneOf" => branches}, segment) when is_list(branches) do
    Enum.find_value(branches, :error, fn branch ->
      case next_schema(branch, segment) do
        {:ok, _child} = found -> found
        :error -> false
      end
    end)
  end

  defp next_schema(_schema, _segment), do: :error

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
    :manifest
    |> LimitCatalog.schema_properties()
    |> closed_object()
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
