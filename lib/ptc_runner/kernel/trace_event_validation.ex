defmodule PtcRunner.Kernel.TraceEventValidation do
  @moduledoc false

  alias PtcRunner.Kernel.JSONValue
  alias PtcRunner.Kernel.LLMBudget
  alias PtcRunner.Kernel.LLMUsageSummary
  alias PtcRunner.Kernel.ResultIdentity

  @event_type ~r/\A[a-z][a-z0-9-]{0,127}\z/
  @bundle_hash ~r/\A[0-9a-f]{64}\z/
  @event_keys ~w(schema_version run_id trace_id sequence timestamp type data)
  @max_string_bytes 256

  @spec validate([map()]) :: :ok | {:error, :malformed_source | :unsupported_version}
  def validate(events) when is_list(events) do
    initial = %{
      sequences: %{},
      run_traces: %{},
      trace_runs: %{},
      run_lifecycles: %{},
      evaluation_lifecycles: %{}
    }

    Enum.reduce_while(events, {:ok, initial}, fn event, {:ok, state} ->
      with :ok <- validate_event(event),
           trace_id = event["trace_id"],
           run_id = event["run_id"],
           sequence = event["sequence"],
           previous = Map.get(state.sequences, trace_id, 0),
           true <- sequence > previous,
           :ok <- same_identity(state, run_id, trace_id),
           {:ok, run_lifecycles} <-
             advance_run_lifecycle(state.run_lifecycles, run_id, event["type"]),
           {:ok, evaluation_lifecycles} <-
             advance_evaluation_lifecycle(state.evaluation_lifecycles, run_id, event) do
        {:cont,
         {:ok,
          %{
            sequences: Map.put(state.sequences, trace_id, sequence),
            run_traces: Map.put(state.run_traces, run_id, trace_id),
            trace_runs: Map.put(state.trace_runs, trace_id, run_id),
            run_lifecycles: run_lifecycles,
            evaluation_lifecycles: evaluation_lifecycles
          }}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _invalid -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, _state} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec directory_reasons([map()]) ::
          [
            :unsupported_version
            | :sequence_conflict
            | :lifecycle_conflict
            | :malformed_event
          ]
  def directory_reasons(events) when is_list(events) do
    []
    |> maybe_directory_reason(unsupported_directory_version?(events), :unsupported_version)
    |> maybe_directory_reason(directory_sequence_conflict?(events), :sequence_conflict)
    |> maybe_directory_reason(directory_lifecycle_conflict?(events), :lifecycle_conflict)
    |> maybe_directory_reason(directory_malformed_event?(events), :malformed_event)
  end

  defp unsupported_directory_version?(events) do
    Enum.any?(events, fn event ->
      case Map.fetch(event, "schema_version") do
        {:ok, version} when is_integer(version) -> version != 2
        _other -> false
      end
    end)
  end

  defp directory_sequence_conflict?(events) do
    Enum.reduce_while(events, %{}, fn event, sequences ->
      case {event["trace_id"], event["sequence"]} do
        {trace_id, sequence} when is_binary(trace_id) and is_integer(sequence) and sequence > 0 ->
          cond do
            valid_event_id(trace_id) != :ok ->
              {:cont, sequences}

            sequence > Map.get(sequences, trace_id, 0) ->
              {:cont, Map.put(sequences, trace_id, sequence)}

            true ->
              {:halt, :conflict}
          end

        {trace_id, _sequence} when is_binary(trace_id) ->
          if valid_event_id(trace_id) == :ok,
            do: {:halt, :conflict},
            else: {:cont, sequences}

        _invalid_identity ->
          {:cont, sequences}
      end
    end) == :conflict
  end

  defp directory_lifecycle_conflict?(events) do
    Enum.reduce_while(events, %{}, &advance_directory_run_lifecycle/2) == :conflict or
      Enum.reduce_while(events, %{}, &advance_directory_evaluation_lifecycle/2) == :conflict
  end

  defp advance_directory_run_lifecycle(
         %{"run_id" => run_id, "type" => type},
         lifecycles
       )
       when is_binary(run_id) and is_binary(type) do
    if directory_lifecycle_identity?(run_id, type),
      do: lifecycle_reduction(advance_run_lifecycle(lifecycles, run_id, type)),
      else: {:cont, lifecycles}
  end

  defp advance_directory_run_lifecycle(_event, lifecycles), do: {:cont, lifecycles}

  defp advance_directory_evaluation_lifecycle(
         %{"run_id" => run_id, "type" => type, "data" => data} = event,
         lifecycles
       )
       when is_binary(run_id) and is_binary(type) and is_map(data) do
    if directory_lifecycle_identity?(run_id, type),
      do: lifecycle_reduction(advance_evaluation_lifecycle(lifecycles, run_id, event)),
      else: {:cont, lifecycles}
  end

  defp advance_directory_evaluation_lifecycle(_event, lifecycles),
    do: {:cont, lifecycles}

  defp lifecycle_reduction({:ok, advanced}), do: {:cont, advanced}
  defp lifecycle_reduction({:error, _reason}), do: {:halt, :conflict}

  defp directory_lifecycle_identity?(run_id, type),
    do: valid_event_id(run_id) == :ok and type =~ @event_type

  defp directory_malformed_event?(events),
    do: Enum.any?(events, &match?({:error, _reason}, directory_event_shape(&1)))

  defp directory_event_shape(event) when is_map(event) do
    event
    |> Map.put("schema_version", normalized_directory_version(event["schema_version"]))
    |> Map.put("sequence", normalized_directory_sequence(event["sequence"]))
    |> validate_event()
    |> case do
      :ok -> :ok
      {:error, _reason} -> {:error, :malformed_event}
    end
  end

  defp directory_event_shape(_event), do: {:error, :malformed_event}

  defp normalized_directory_version(version) when is_integer(version) and version != 2, do: 2
  defp normalized_directory_version(version), do: version

  defp normalized_directory_sequence(sequence)
       when not is_integer(sequence) or sequence <= 0,
       do: 1

  defp normalized_directory_sequence(sequence), do: sequence

  defp maybe_directory_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_directory_reason(reasons, false, _reason), do: reasons

  defp advance_run_lifecycle(run_lifecycles, run_id, type) do
    case {Map.get(run_lifecycles, run_id), type} do
      {nil, "run-started"} ->
        {:ok, Map.put(run_lifecycles, run_id, :open)}

      {:open, "run-stopped"} ->
        {:ok, Map.put(run_lifecycles, run_id, :stopped)}

      {:open, "run-started"} ->
        {:error, :malformed_source}

      {:open, _type} ->
        {:ok, run_lifecycles}

      {_lifecycle, _type} ->
        {:error, :malformed_source}
    end
  end

  defp advance_evaluation_lifecycle(evaluations, run_id, %{
         "type" => "evaluation-started",
         "data" => data
       }) do
    evaluation_id = data["evaluation_id"]
    environment = stringify(data["environment"])
    parent_evaluation_id = data["parent_evaluation_id"]
    key = {run_id, evaluation_id}

    with :ok <- valid_event_id(evaluation_id),
         false <- Map.has_key?(evaluations, key),
         :ok <- validate_parent_evaluation(evaluations, run_id, environment, parent_evaluation_id) do
      {:ok,
       Map.put(evaluations, key, %{
         environment: environment,
         parent_evaluation_id: parent_evaluation_id,
         lifecycle: :open
       })}
    else
      _invalid -> {:error, :malformed_source}
    end
  end

  defp advance_evaluation_lifecycle(evaluations, run_id, %{
         "type" => "evaluation-stopped",
         "data" => data
       }) do
    evaluation_id = data["evaluation_id"]
    environment = stringify(data["environment"])
    parent_evaluation_id = data["parent_evaluation_id"]
    key = {run_id, evaluation_id}

    with :ok <- valid_event_id(evaluation_id),
         %{lifecycle: :open} = started <- Map.get(evaluations, key),
         true <- started.environment == environment,
         true <- started.parent_evaluation_id == parent_evaluation_id do
      {:ok, put_in(evaluations, [key, :lifecycle], :stopped)}
    else
      nil when is_nil(parent_evaluation_id) -> {:ok, evaluations}
      _invalid -> {:error, :malformed_source}
    end
  end

  defp advance_evaluation_lifecycle(evaluations, _run_id, %{"data" => data}) do
    if Map.has_key?(data, "parent_evaluation_id"),
      do: {:error, :malformed_source},
      else: {:ok, evaluations}
  end

  defp validate_parent_evaluation(_evaluations, _run_id, _environment, nil), do: :ok

  defp validate_parent_evaluation(evaluations, run_id, "mission", parent_evaluation_id) do
    with :ok <- valid_event_id(parent_evaluation_id),
         %{environment: "workflow", lifecycle: :open, parent_evaluation_id: nil} <-
           Map.get(evaluations, {run_id, parent_evaluation_id}) do
      :ok
    else
      _invalid -> {:error, :malformed_source}
    end
  end

  defp validate_parent_evaluation(_evaluations, _run_id, _environment, _parent_evaluation_id),
    do: {:error, :malformed_source}

  defp valid_event_id(value), do: valid_string(value)

  defp same_identity(state, run_id, trace_id) do
    with existing_trace when existing_trace in [nil, trace_id] <-
           Map.get(state.run_traces, run_id),
         existing_run when existing_run in [nil, run_id] <- Map.get(state.trace_runs, trace_id) do
      :ok
    else
      _other -> {:error, :malformed_source}
    end
  end

  defp validate_event(event) when is_map(event) do
    with true <- Enum.sort(Map.keys(event)) == Enum.sort(@event_keys),
         2 <- event["schema_version"],
         :ok <- valid_string(event["run_id"]),
         :ok <- valid_string(event["trace_id"]),
         sequence when is_integer(sequence) and sequence > 0 <- event["sequence"],
         timestamp when is_binary(timestamp) <- event["timestamp"],
         {:ok, _datetime, 0} <- DateTime.from_iso8601(timestamp),
         type when is_binary(type) <- event["type"],
         true <- type =~ @event_type,
         true <- JSONValue.map?(event["data"]),
         :ok <- validate_event_data(type, event["data"]) do
      :ok
    else
      version when is_integer(version) and version != 2 -> {:error, :unsupported_version}
      _invalid -> {:error, :malformed_source}
    end
  end

  defp validate_event(_event), do: {:error, :malformed_source}

  defp validate_event_data(type, data) do
    with :ok <- validate_current_event_data(type, data),
         :ok <- validate_run_stopped_usage(type, data) do
      validate_run_stopped_result_hash(type, data)
    end
  end

  defp validate_run_stopped_result_hash("run-stopped", data) do
    case Map.fetch(data, "result_hash") do
      :error ->
        :ok

      {:ok, result_hash} ->
        if stringify(data["outcome"]) == "ok" and ResultIdentity.valid_hash?(result_hash),
          do: :ok,
          else: {:error, :malformed_source}
    end
  end

  defp validate_run_stopped_result_hash(_type, _data), do: :ok

  defp validate_current_event_data("run-started", data) do
    singular =
      ~w(mission_prelude mission_inventory_hash mission_inventory_bytes mission_model_context_hash mission_model_context_bytes)

    if is_map(data["missions"]) and Enum.all?(singular, &(not Map.has_key?(data, &1))) and
         not Map.has_key?(data, "mission_name") and
         valid_prelude_projection?(data["workflow_prelude"]) and
         valid_mission_preludes?(data["missions"]) do
      :ok
    else
      {:error, :malformed_source}
    end
  end

  defp validate_current_event_data(type, data) when type in ["run-stopped", "events-dropped"] do
    if Map.has_key?(data, "mission_name"), do: {:error, :malformed_source}, else: :ok
  end

  defp validate_current_event_data(_type, data) do
    case stringify(data["environment"]) do
      "mission" ->
        if valid_string(data["mission_name"]) == :ok,
          do: :ok,
          else: {:error, :malformed_source}

      "workflow" ->
        if Map.has_key?(data, "mission_name"), do: {:error, :malformed_source}, else: :ok

      _other ->
        if Map.has_key?(data, "mission_name"), do: {:error, :malformed_source}, else: :ok
    end
  end

  defp valid_mission_preludes?(missions) do
    Enum.all?(missions, fn {_name, metadata} ->
      is_map(metadata) and valid_prelude_projection?(metadata["prelude"])
    end)
  end

  defp valid_prelude_projection?(nil), do: true

  defp valid_prelude_projection?(prelude) when is_map(prelude) do
    component_ids = prelude["component_ids"]

    is_list(component_ids) and Enum.all?(component_ids, &(valid_string(&1) == :ok)) and
      component_ids == Enum.uniq(component_ids) and
      valid_prelude_hash?(prelude["hash"], component_ids) and
      valid_dependency_indices?(prelude["dependency_indices"], length(component_ids))
  end

  defp valid_prelude_projection?(_prelude), do: false

  defp valid_prelude_hash?(nil, component_ids), do: component_ids == []
  defp valid_prelude_hash?(hash, _component_ids) when is_binary(hash), do: hash =~ @bundle_hash
  defp valid_prelude_hash?(_hash, _component_ids), do: false

  defp valid_dependency_indices?(dependency_indices, count) when is_list(dependency_indices) do
    length(dependency_indices) == count and
      dependency_indices
      |> Enum.with_index()
      |> Enum.all?(fn {indices, position} -> valid_dependency_list?(indices, position) end)
  end

  defp valid_dependency_indices?(_dependency_indices, _count), do: false

  defp valid_dependency_list?(indices, position) when is_list(indices) do
    Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < position)) and
      indices == Enum.sort(indices) and indices == Enum.uniq(indices)
  end

  defp valid_dependency_list?(_indices, _position), do: false

  defp validate_run_stopped_usage("run-stopped", data) do
    case Map.fetch(data, "usage") do
      :error ->
        {:error, :malformed_source}

      {:ok, usage} when is_map(usage) ->
        with :ok <- validate_subordinate_source_checks(usage),
             :ok <- validate_terminal_llm_budget(usage),
             do: validate_terminal_llm_spend(usage)

      _invalid_usage ->
        {:error, :malformed_source}
    end
  end

  defp validate_run_stopped_usage(_type, _data), do: :ok

  defp validate_subordinate_source_checks(usage) do
    case Map.fetch(usage, "subordinate_source_checks") do
      :error -> :ok
      {:ok, count} when is_integer(count) and count >= 0 -> :ok
      _invalid_count -> {:error, :malformed_source}
    end
  end

  defp validate_terminal_llm_budget(usage) do
    case LLMBudget.validate_terminal_projection(Map.get(usage, "llm_budget")) do
      {:ok, _budget} -> :ok
      {:error, :invalid_llm_budget} -> {:error, :malformed_source}
    end
  end

  defp validate_terminal_llm_spend(usage) do
    case Map.fetch(usage, "llm_spend") do
      :error ->
        :ok

      {:ok, spend} ->
        case LLMUsageSummary.validate_spend(spend) do
          {:ok, _spend} -> :ok
          {:error, :invalid_llm_spend} -> {:error, :malformed_source}
        end
    end
  end

  defp valid_string(value)
       when is_binary(value) and byte_size(value) in 1..@max_string_bytes,
       do: if(String.valid?(value), do: :ok, else: {:error, :malformed_source})

  defp valid_string(_value), do: {:error, :malformed_source}

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
