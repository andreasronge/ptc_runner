defmodule PtcRunner.Kernel.MissionInventory do
  @moduledoc """
  Builds the exact frozen model-facing inventory for one mission environment.

  Version 2 contains prompt-visible prelude exports, model-visible capability
  schemas, and the mission execution limits relevant to generated programs.
  A separate version 2 model-contract rendering normalizes prompt-visible
  exports and directly callable capabilities into one structured API list.
  Arrays are sorted by public form. Both UTF-8 renderings and lower-case SHA-256
  hashes are frozen into `PtcRunner.Kernel.RunConfig` and are identical for
  normal runs and `PtcRunner.Kernel.ReplSession`.

  Every bare capability entry carries a frozen `call` form. In the secondary
  model-contract projection, required input fields are expanded into the
  literal argument map, for example `(tool/search {"query" query})`; the
  authoritative inventory retains its generic one-map form and full schemas.
  Live models given only a capability name invent invalid invocation syntax,
  so the model projection teaches the exact required-field form.

  Rendering uses `PtcRunner.Kernel.DeterministicJSON`. The installed ceiling
  is 256 KiB; callers may lower it but inventory is never truncated.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ModelContract
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export

  @max_bytes 256 * 1_024
  @max_model_bytes 256 * 1_024
  @enforce_keys [
    :schema_version,
    :rendered,
    :hash,
    :bytes,
    :model_schema_version,
    :model_rendered,
    :model_hash,
    :model_bytes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 2,
          rendered: binary(),
          hash: binary(),
          bytes: non_neg_integer(),
          model_schema_version: 2,
          model_rendered: binary(),
          model_hash: binary(),
          model_bytes: non_neg_integer()
        }

  @spec build(MissionEnvironment.t(), Limits.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_mission_inventory | :mission_inventory_exceeded}
  @doc "Builds one bounded version 2 mission inventory."
  def build(mission, limits, opts \\ [])

  def build(%MissionEnvironment{} = mission, %Limits{} = limits, opts) when is_list(opts) do
    with true <- Keyword.keys(opts) -- [:max_bytes, :max_model_bytes] == [],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <-
           Keyword.get(opts, :max_bytes, @max_bytes),
         max_model_bytes when is_integer(max_model_bytes) and max_model_bytes > 0 <-
           Keyword.get(opts, :max_model_bytes, @max_model_bytes),
         {:ok, rendered} <- DeterministicJSON.encode(projection(mission, limits)),
         true <- byte_size(rendered) <= max_bytes,
         {:ok, model_projection} <- model_projection(mission, limits),
         {:ok, model_rendered} <- DeterministicJSON.encode(model_projection),
         true <- byte_size(model_rendered) <= max_model_bytes do
      {:ok,
       %__MODULE__{
         schema_version: 2,
         rendered: rendered,
         hash: sha256(rendered),
         bytes: byte_size(rendered),
         model_schema_version: 2,
         model_rendered: model_rendered,
         model_hash: sha256(model_rendered),
         model_bytes: byte_size(model_rendered)
       }}
    else
      false -> {:error, :mission_inventory_exceeded}
      _reason -> {:error, :invalid_mission_inventory}
    end
  end

  def build(_mission, _limits, _opts), do: {:error, :invalid_mission_inventory}

  defp projection(mission, limits) do
    {:object,
     [
       {"schema_version", 2},
       {"exports", exports(mission)},
       {"capabilities", capabilities(mission)},
       {"limits", limit_projection(limits)}
     ]}
  end

  defp model_projection(mission, limits) do
    with {:ok, entries} <- model_entries(mission) do
      {:ok,
       {:object,
        [
          {"schema_version", 2},
          {"namespaces", model_namespaces(mission)},
          {"entries", Enum.sort_by(entries, &entry_form/1)},
          {"limits", limit_projection(limits)}
        ]}}
    end
  end

  # A facade's own docstring states the contract its functions share — which
  # source is authoritative, how cursors behave, what a citation must carry.
  # Only per-function docs used to reach the model, so that guidance had to be
  # restated in every task prompt, and the copies drifted. The namespace states
  # it once and the model reads it from the same place the code declares it.
  defp model_namespaces(%{bundle: %{prelude: prelude}}) do
    prompt_namespaces =
      prelude
      |> Prelude.prompt_exports()
      |> MapSet.new(&namespace_of/1)

    prelude.metadata
    |> Map.get(:namespaces, %{})
    |> Enum.filter(fn {name, meta} ->
      MapSet.member?(prompt_namespaces, name) and is_binary(Map.get(meta, :doc))
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, meta} ->
      {:object, [{"namespace", name}, {"doc", meta.doc}]}
    end)
  end

  defp model_namespaces(_mission), do: []

  defp namespace_of(%Export{ref: ref}) do
    case String.split(ref, "/", parts: 2) do
      [namespace, _rest] -> namespace
      _other -> ref
    end
  end

  defp exports(%{bundle: %{prelude: prelude}} = mission) do
    prelude
    |> Prelude.prompt_exports()
    |> Enum.sort_by(& &1.ref)
    |> Enum.map(&export_projection(&1, mission))
  end

  defp exports(_mission), do: []

  defp export_projection(%Export{} = export, mission) do
    {:object,
     [
       {"ref", export.ref},
       {"kind", Atom.to_string(export.kind)},
       {"call", export_call(export)},
       {"doc", export.doc},
       {"effect", export |> resolved_export_effect(mission) |> Atom.to_string()},
       {"contract", export.signature || export.type}
     ]}
  end

  defp export_call(%Export{} = export), do: Export.call_form(export)

  defp model_entries(mission) do
    with {:ok, exports} <- model_exports(mission),
         {:ok, capabilities} <- model_capabilities(mission),
         {:ok, data} <- model_data(mission) do
      {:ok, exports ++ capabilities ++ data}
    end
  end

  defp model_data(%{data: data}) when is_map(data) and not is_struct(data) do
    data
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, value}, {:ok, entries} ->
      with {:ok, form} <- data_form(name),
           {:ok, contract} <- ModelContract.json_value(value) do
        entry =
          model_entry(
            "value",
            form,
            contract,
            :read,
            "Mission data supplied by the application manifest."
          )

        {:cont, {:ok, [entry | entries]}}
      else
        :skip -> {:cont, {:ok, entries}}
        {:error, :unsupported_contract} -> {:cont, {:ok, entries}}
      end
    end)
    |> reverse_entries()
  end

  defp model_data(_mission), do: {:ok, []}

  defp data_form(name) when is_binary(name) do
    case Parser.parse("data/" <> name) do
      {:ok, {:ns_symbol, :data, parsed}} ->
        if to_string(parsed) == name, do: {:ok, "data/" <> name}, else: :skip

      _not_a_source_reference ->
        :skip
    end
  end

  defp data_form(_name), do: :skip

  defp model_exports(%{bundle: %{prelude: prelude}} = mission) do
    prelude
    |> Prelude.prompt_exports()
    |> Enum.reduce_while({:ok, []}, fn export, {:ok, entries} ->
      case model_export(export, mission) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> reverse_entries()
  end

  defp model_exports(_mission), do: {:ok, []}

  defp model_export(%Export{kind: :function, parsed_signature: signature} = export, mission) do
    with {:ok, contract} <- optional_function_contract(signature) do
      {:ok,
       model_entry(
         "call",
         export_call(export),
         contract,
         resolved_export_effect(export, mission),
         export.doc
       )}
    end
  end

  defp model_export(%Export{kind: :constant, parsed_type: type} = export, mission) do
    with {:ok, contract} <- optional_value_contract(type) do
      {:ok,
       model_entry(
         "value",
         export_call(export),
         contract,
         resolved_export_effect(export, mission),
         export.doc
       )}
    end
  end

  defp capabilities(mission) do
    mission
    |> Environment.metadata()
    |> Enum.map(fn capability ->
      {:object,
       [
         {"name", capability.name},
         {"call", "(tool/#{capability.name} arguments)"},
         {"description", capability.description},
         {"effect", Atom.to_string(capability.effect)},
         {"input_schema", capability.input_schema},
         {"output_schema", capability.output_schema}
       ]}
    end)
  end

  defp model_capabilities(mission) do
    mission
    |> Environment.metadata()
    |> Enum.reduce_while({:ok, []}, fn capability, {:ok, entries} ->
      case ModelContract.capability(capability.input_schema, capability.output_schema) do
        {:ok, contract} ->
          form = ModelContract.capability_call(capability.name, capability.input_schema)

          entry =
            model_entry(
              "call",
              form,
              contract,
              capability.effect,
              capability.description
            )

          {:cont, {:ok, [entry | entries]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> reverse_entries()
  end

  defp optional_function_contract(nil), do: {:ok, nil}
  defp optional_function_contract(signature), do: ModelContract.function(signature)

  defp optional_value_contract(nil), do: {:ok, nil}
  defp optional_value_contract(type), do: ModelContract.value(type)

  defp model_entry(kind, form, contract, effect, docs) do
    {:object,
     [
       {"kind", kind},
       {"form", form},
       {"contract", contract},
       {"effect", Atom.to_string(effect)},
       {"docs", docs}
     ]}
  end

  defp entry_form({:object, pairs}), do: pairs |> Map.new() |> Map.fetch!("form")

  defp resolved_export_effect(export, %{capabilities: capabilities}) do
    required_names =
      export.requires
      |> Enum.flat_map(fn
        "tool:" <> name -> [name]
        _requirement -> []
      end)

    dependency_effects =
      (export.tool_refs ++ required_names)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        case Map.fetch(capabilities, name) do
          {:ok, capability} -> capability.effect
          :error -> :unknown
        end
      end)

    join_effects([export.effect | dependency_effects])
  end

  defp join_effects(effects) do
    cond do
      :write in effects -> :write
      :unknown in effects -> :unknown
      :read in effects -> :read
      true -> :unknown
    end
  end

  defp reverse_entries({:ok, entries}), do: {:ok, Enum.reverse(entries)}
  defp reverse_entries({:error, _} = error), do: error

  defp limit_projection(limits) do
    {:object,
     [
       {"evaluation_timeout_ms", limits.evaluation_timeout_ms},
       {"parallel_timeout_ms", limits.parallel_timeout_ms},
       {"subordinate_source_bytes", limits.subordinate_source_bytes},
       {"subordinate_source_checks", limits.subordinate_source_checks},
       {"mission_capability_calls", limits.mission_capability_calls},
       {"mission_capability_calls_per_name", limits.mission_capability_calls_per_name},
       {"capability_argument_bytes", limits.capability_argument_bytes},
       {"capability_result_bytes", limits.capability_result_bytes}
     ]}
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
