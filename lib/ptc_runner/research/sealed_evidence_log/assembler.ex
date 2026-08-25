defmodule PtcRunner.Research.SealedEvidenceLog.Assembler do
  @moduledoc """
  Builds ETS indexes from one streaming evidence record at a time.

  Collection order, filter postings, turn projections, and relationship rows are
  inserted after the last frame, once joins and conversation facts are closed.
  """

  alias PtcRunner.Kernel.RunAnalysisRelationships
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Research.SealedEvidenceLog.Conversation
  alias PtcRunner.Research.SealedEvidenceLog.Format
  alias PtcRunner.Research.SealedEvidenceLog.Indexes
  alias PtcRunner.Research.SealedEvidenceLog.ValueHash

  @spec new(Indexes.t(), map()) :: map()
  def new(indexes, limits) do
    %{
      indexes: indexes,
      limits: limits,
      run_id: nil,
      trace_id: nil,
      schema_version: 8,
      first_timestamp: nil,
      last_timestamp: nil,
      first_sequence: 0,
      last_sequence: 0,
      record_count: 0,
      conversation: Conversation.new(),
      inputs: %{},
      outputs: %{},
      exceptions: %{},
      mcp_requests: %{},
      mcp_responses: %{},
      mcp_stderrs: %{},
      analyses: %{},
      prelude_calls_by_eval: %{},
      generated_meta: [],
      prelude_meta: [],
      execution_meta: %{prints: [], errors: [], failures: []},
      result_sequence: nil
    }
  end

  @spec ingest(map(), map(), non_neg_integer(), non_neg_integer(), binary()) ::
          {:ok, map()} | {:error, atom()}
  def ingest(state, record, offset, length, digest) do
    record = RetainedSize.detach_binaries(record)

    with :ok <- schema_version(record),
         :ok <- identity(state, record),
         :ok <- next_sequence(state, record),
         {:ok, state} <- put_primary(state, record, offset, length, digest),
         {:ok, state} <- put_join(state, record) do
      {:ok,
       %{
         observe(state, record)
         | run_id: record["run_id"],
           trace_id: record["trace_id"],
           schema_version: record["schema_version"],
           first_timestamp: state.first_timestamp || record["timestamp"],
           last_timestamp: record["timestamp"],
           first_sequence: first_sequence(state, record["sequence"]),
           last_sequence: record["sequence"],
           record_count: state.record_count + 1
       }}
    end
  end

  @spec finish(map(), map()) :: {:ok, map()} | {:error, atom()}
  def finish(state, trace_facts) do
    state = Map.put(state, :pending_parents, Map.get(trace_facts, "parent_evaluation_ids", %{}))

    with :ok <- closed_joins(state),
         conversation <- Conversation.finish(state.conversation, trace_facts),
         {:ok, state} <- materialize_pairs(state),
         {:ok, state} <- materialize_sources(state),
         {:ok, state} <- materialize_preludes(state),
         {:ok, state} <- materialize_providers(state),
         {:ok, state} <- materialize_execution(state),
         {:ok, state} <- materialize_turns(state, conversation, trace_facts),
         {:ok, state} <- materialize_counts(state, conversation),
         {:ok, state} <- materialize_run(state),
         {:ok, state} <- materialize_result(state),
         {:ok, state} <- materialize_relationships(state, conversation, trace_facts) do
      {:ok, Map.put(state, :evidence, conversation.evidence)}
    end
  end

  defp schema_version(%{"schema_version" => version}) do
    if version == Format.schema_version(), do: :ok, else: {:error, :invalid_record}
  end

  defp schema_version(_record), do: {:error, :invalid_record}

  defp first_sequence(%{record_count: 0}, sequence), do: sequence
  defp first_sequence(%{first_sequence: first}, _sequence), do: first

  defp identity(%{run_id: nil}, %{"run_id" => run_id, "trace_id" => trace_id})
       when is_binary(run_id) and is_binary(trace_id),
       do: :ok

  defp identity(%{run_id: run_id, trace_id: trace_id}, record) do
    if record["run_id"] == run_id and record["trace_id"] == trace_id,
      do: :ok,
      else: {:error, :invalid_record}
  end

  defp next_sequence(%{record_count: 0}, %{"sequence" => sequence})
       when is_integer(sequence) and sequence > 0,
       do: :ok

  defp next_sequence(%{record_count: count}, %{"sequence" => sequence})
       when is_integer(sequence) and sequence == count + 1,
       do: :ok

  defp next_sequence(_state, _record), do: {:error, :invalid_record}

  defp put_primary(state, record, offset, length, digest) do
    insert(
      state,
      :primary,
      {record["run_id"], record["sequence"]},
      {record["record_type"], offset, length, digest}
    )
  end

  defp put_join(state, %{"record_type" => "capability-input"} = record) do
    id = record["correlation"]["capability_id"]

    if Map.has_key?(state.inputs, id) do
      {:error, :invalid_record}
    else
      payload = record["payload"]

      {:ok,
       %{
         state
         | inputs:
             Map.put(state.inputs, id, %{
               sequence: record["sequence"],
               environment: payload["environment"],
               mission_name: payload["mission_name"],
               name: payload["name"]
             })
       }}
    end
  end

  defp put_join(state, %{"record_type" => "capability-output"} = record) do
    id = record["correlation"]["capability_id"]
    input = Map.get(state.inputs, id)

    if compatible_capability?(input, record) and not Map.has_key?(state.outputs, id) and
         valid_exception_output?(state, id, record["payload"]["result"]) do
      {:ok, %{state | outputs: Map.put(state.outputs, id, record["sequence"])}}
    else
      {:error, :invalid_record}
    end
  end

  defp put_join(state, %{"record_type" => "capability-exception"} = record) do
    id = record["correlation"]["capability_id"]
    input = Map.get(state.inputs, id)

    if compatible_capability?(input, record) and not Map.has_key?(state.exceptions, id) and
         not Map.has_key?(state.outputs, id) do
      {:ok, %{state | exceptions: Map.put(state.exceptions, id, record["sequence"])}}
    else
      {:error, :invalid_record}
    end
  end

  defp put_join(state, %{"record_type" => "mcp-request"} = record) do
    key = mcp_key(record)

    if Map.has_key?(state.mcp_requests, key) do
      {:error, :invalid_record}
    else
      {:ok,
       %{
         state
         | mcp_requests:
             Map.put(state.mcp_requests, key, %{
               sequence: record["sequence"],
               transport: record["payload"]["transport"],
               mission_name: record["payload"]["mission_name"]
             })
       }}
    end
  end

  defp put_join(state, %{"record_type" => "mcp-response"} = record) do
    key = mcp_key(record)

    if Map.has_key?(state.mcp_responses, key) do
      {:error, :invalid_record}
    else
      {:ok,
       %{
         state
         | mcp_responses: Map.put(state.mcp_responses, key, record["sequence"])
       }}
    end
  end

  defp put_join(state, %{"record_type" => "mcp-stderr"} = record) do
    {:ok, %{state | mcp_stderrs: Map.put(state.mcp_stderrs, mcp_key(record), record["sequence"])}}
  end

  defp put_join(state, %{"record_type" => "evaluation-analysis"} = record) do
    id = record["correlation"]["evaluation_id"]

    with {:ok, state} <-
           insert(state, :join_evaluation, {record["run_id"], id, :analysis}, record["sequence"]) do
      {:ok,
       %{
         state
         | analyses: Map.put(state.analyses, id, record["sequence"]),
           prelude_calls_by_eval:
             Map.put(state.prelude_calls_by_eval, id, record["payload"]["prelude_calls"])
       }}
    end
  end

  defp put_join(state, %{"record_type" => "evaluation-source"} = record) do
    meta = %{
      sequence: record["sequence"],
      evaluation_id: record["correlation"]["evaluation_id"],
      environment: record["payload"]["environment"],
      mission_name: record["payload"]["mission_name"]
    }

    {:ok, %{state | generated_meta: [meta | state.generated_meta]}}
  end

  defp put_join(state, %{"record_type" => "prelude-source"} = record) do
    meta = %{
      sequence: record["sequence"],
      component_id: record["correlation"]["component_id"],
      environment: record["payload"]["environment"],
      mission_name: record["payload"]["mission_name"]
    }

    {:ok, %{state | prelude_meta: [meta | state.prelude_meta]}}
  end

  defp put_join(state, %{"record_type" => "execution-prints"} = record) do
    put_execution(state, :prints, record)
  end

  defp put_join(state, %{"record_type" => "execution-error"} = record) do
    put_execution(state, :errors, record)
  end

  defp put_join(state, %{"record_type" => "explicit-failure-value"} = record) do
    put_execution(state, :failures, record)
  end

  defp put_join(state, %{"record_type" => "run-result"} = record) do
    if state.result_sequence do
      {:error, :invalid_record}
    else
      insert(state, :result, record["run_id"], record["sequence"])
      |> case do
        {:ok, state} -> {:ok, %{state | result_sequence: record["sequence"]}}
        error -> error
      end
    end
  end

  defp put_join(_state, _record), do: {:error, :invalid_record}

  defp put_execution(state, field, record) do
    meta = %{
      sequence: record["sequence"],
      evaluation_id: record["correlation"]["evaluation_id"]
    }

    {:ok, update_in(state, [:execution_meta, field], &[meta | &1])}
  end

  defp observe(state, record) do
    conversation =
      record
      |> then(&Conversation.observe_input(state.conversation, &1))
      |> then(&Conversation.observe_output(&1, record))
      |> then(&Conversation.observe_source(&1, record))

    %{state | conversation: conversation}
  end

  defp capability_class(%{environment: "workflow", name: "llm-request"}), do: :model
  defp capability_class(_input), do: :capability

  defp compatible_capability?(nil, _record), do: false

  defp compatible_capability?(input, record) do
    payload = record["payload"]

    input.environment == payload["environment"] and
      input.mission_name == payload["mission_name"] and
      input.name == payload["name"]
  end

  defp valid_exception_output?(state, id, result) do
    not Map.has_key?(state.exceptions, id) or
      match?(
        %{
          "status" => "error",
          "kind" => "provider_error",
          "reason" => "exception",
          "retryable?" => false
        },
        result
      )
  end

  defp mcp_key(record) do
    correlation = record["correlation"]
    {correlation["capability_id"], correlation["request_id"]}
  end

  defp closed_joins(state) do
    request_keys = MapSet.new(Map.keys(state.mcp_requests))
    response_keys = MapSet.new(Map.keys(state.mcp_responses))

    if MapSet.equal?(request_keys, response_keys),
      do: :ok,
      else: {:error, :incomplete_inspection_correlation}
  end

  defp materialize_pairs(state) do
    state.inputs
    |> Enum.sort_by(fn {_id, input} -> input.sequence end)
    |> Enum.reduce_while({:ok, state}, fn {id, input}, {:ok, acc} ->
      output = Map.get(acc.outputs, id)
      exception = Map.get(acc.exceptions, id)
      class = capability_class(input)
      collection = if class == :model, do: :model_exchanges, else: :capability_calls

      locator = {:capability, id, input.sequence}

      join = %{
        input_sequence: input.sequence,
        exception_sequence: exception,
        output_sequence: output,
        environment: input.environment,
        mission_name: input.mission_name,
        name: input.name,
        class: class
      }

      with {:ok, acc} <- insert(acc, :join_capability, {acc.run_id, id}, join),
           {:ok, acc} <- order_and_filters(acc, collection, locator, pair_filters(input, id)) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_sources(state) do
    state.generated_meta
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, state}, fn meta, {:ok, acc} ->
      locator = {:record, meta.sequence}
      parent = Map.get(acc, :pending_parents, %{})[meta.evaluation_id]
      prelude_calls = Map.get(acc.prelude_calls_by_eval, meta.evaluation_id)

      meta =
        meta
        |> Map.put(:parent_evaluation_id, parent)
        |> Map.put(:prelude_calls, prelude_calls)

      filters = source_filters(meta)

      with {:ok, acc} <-
             insert(
               acc,
               :join_evaluation,
               {state.run_id, meta.evaluation_id, :source},
               meta.sequence
             ),
           {:ok, acc} <- order_and_filters(acc, :generated_sources, locator, filters) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_preludes(state) do
    state.prelude_meta
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, state}, fn meta, {:ok, acc} ->
      locator = {:record, meta.sequence}
      key = {state.run_id, meta.environment, meta.mission_name, meta.component_id}

      with {:ok, acc} <-
             insert(acc, :join_prelude, key, {meta.sequence, 1}),
           {:ok, acc} <-
             order_and_filters(acc, :effective_preludes, locator, prelude_filters(meta)) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_providers(state) do
    state.mcp_requests
    |> Enum.sort_by(fn {_key, request} -> request.sequence end)
    |> Enum.reduce_while({:ok, state}, fn {{capability_id, request_id}, request}, {:ok, acc} ->
      response = Map.fetch!(acc.mcp_responses, {capability_id, request_id})
      stderr = Map.get(acc.mcp_stderrs, {capability_id, request_id})
      locator = {:provider, capability_id, request_id, request.sequence}

      join = %{
        request_sequence: request.sequence,
        response_sequence: response,
        stderr_sequence: stderr,
        transport: request.transport,
        mission_name: request.mission_name
      }

      with {:ok, acc} <-
             insert(acc, :join_provider, {state.run_id, capability_id, request_id}, join),
           {:ok, acc} <-
             order_and_filters(
               acc,
               :provider_exchanges,
               locator,
               provider_filters(request, capability_id, request_id)
             ) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_execution(state) do
    [
      {:execution_prints, :prints, :prints},
      {:execution_errors, :errors, :error},
      {:explicit_failure_values, :failures, :failure}
    ]
    |> Enum.reduce_while({:ok, state}, fn {collection, field, role}, {:ok, acc} ->
      acc.execution_meta
      |> Map.fetch!(field)
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, acc}, fn meta, {:ok, inner} ->
        locator = {:record, meta.sequence}

        with {:ok, inner} <-
               insert(
                 inner,
                 :join_evaluation,
                 {state.run_id, meta.evaluation_id, role},
                 meta.sequence
               ),
             {:ok, inner} <-
               order_and_filters(inner, collection, locator, [
                 {"evaluation_id", meta.evaluation_id}
               ]) do
          {:cont, {:ok, inner}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_turns(state, conversation, _trace_facts) do
    conversation.turns
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, state}, fn {turn, ordinal}, {:ok, acc} ->
      locator = {:turn, ordinal}

      row = %{
        ordinal: ordinal,
        stream_id: turn.stream_id,
        turn: turn.turn,
        capability_id: turn.capability_id,
        input_sequence: turn.input_sequence,
        output_sequence: turn.output_sequence,
        generated: enrich_generated(state, turn.generated),
        messages_added_count: length(turn.messages_added_roles)
      }

      filters = turn_filters(turn)

      with {:ok, acc} <- insert(acc, :turn, {state.run_id, ordinal}, row),
           {:ok, acc} <- order_and_filters(acc, :turns, locator, filters) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp materialize_counts(state, conversation) do
    pairs = Enum.to_list(state.inputs)

    model =
      Enum.filter(pairs, fn {_id, input} -> capability_class(input) == :model end)

    calls =
      Enum.reject(pairs, fn {_id, input} -> capability_class(input) == :model end)

    counts = %{
      "model_exchanges" => length(model),
      "incomplete_model_exchanges" =>
        Enum.count(model, fn {id, _} -> not Map.has_key?(state.outputs, id) end),
      "capability_calls" => length(calls),
      "capability_exceptions" => map_size(state.exceptions),
      "incomplete_capability_calls" =>
        Enum.count(calls, fn {id, _} -> not Map.has_key?(state.outputs, id) end),
      "generated_sources" => length(state.generated_meta),
      "evaluation_analyses" => map_size(state.analyses),
      "effective_preludes" => length(state.prelude_meta),
      "provider_exchanges" => map_size(state.mcp_requests),
      "execution_prints" => length(state.execution_meta.prints),
      "execution_errors" => length(state.execution_meta.errors),
      "explicit_failure_values" => length(state.execution_meta.failures)
    }

    _ = conversation
    insert(state, :count, {state.run_id, :summary}, counts)
  end

  defp materialize_run(state) do
    with {:ok, [{_key, counts}]} <-
           {:ok, Indexes.lookup(state.indexes, :counts, {state.run_id, :summary})},
         run <- %{
           "run_id" => state.run_id,
           "trace_id" => state.trace_id,
           "schema_version" => state.schema_version,
           "record_count" => state.record_count,
           "first_timestamp" => state.first_timestamp,
           "last_timestamp" => state.last_timestamp,
           "counts" => counts
         } do
      insert(state, :run, state.run_id, run)
    else
      _other -> {:error, :invalid_record}
    end
  end

  defp materialize_result(state), do: {:ok, state}

  defp materialize_relationships(state, conversation, trace_facts) do
    generated =
      state.generated_meta
      |> Enum.reverse()
      |> Enum.map(fn meta ->
        parent = get_in(trace_facts, ["parent_evaluation_ids", meta.evaluation_id])
        calls = Map.get(state.prelude_calls_by_eval, meta.evaluation_id)

        %{
          "run_id" => state.run_id,
          "sequence" => meta.sequence,
          "evaluation_id" => meta.evaluation_id,
          "parent_evaluation_id" => parent,
          "environment" => meta.environment,
          "mission_name" => meta.mission_name,
          "prelude_calls_available?" => is_list(calls),
          "prelude_calls" => calls || []
        }
      end)

    preludes =
      Enum.map(Enum.reverse(state.prelude_meta), fn meta ->
        %{
          "run_id" => state.run_id,
          "sequence" => meta.sequence,
          "component_id" => meta.component_id,
          "environment" => meta.environment,
          "mission_name" => meta.mission_name
        }
      end)

    errors =
      Enum.map(Enum.reverse(state.execution_meta.errors), fn meta ->
        %{
          "run_id" => state.run_id,
          "evaluation_id" => meta.evaluation_id,
          "sequence" => meta.sequence,
          "details" => %{}
        }
      end)

    turns =
      Enum.map(conversation.turns, fn turn ->
        %{
          "run_id" => state.run_id,
          "stream_id" => turn.stream_id,
          "generated" =>
            Enum.map(turn.generated, fn generated ->
              %{
                "run_id" => state.run_id,
                "sequence" => generated.sequence,
                "evaluation_id" => generated.evaluation_id,
                "association_ambiguous?" => generated.association_ambiguous?
              }
            end)
        }
      end)

    collections = %{
      generated_sources: generated,
      effective_preludes: preludes,
      execution_errors: errors,
      turns: turns,
      turns_by_run_id: %{
        state.run_id => %{items: turns, evidence: conversation.evidence}
      }
    }

    attached = RunAnalysisRelationships.attach(collections, %{state.run_id => trace_facts})

    Enum.reduce_while(
      attached.generated_sources ++ attached.effective_preludes ++ attached.execution_errors,
      {:ok, state},
      fn item, {:ok, acc} ->
        key = {state.run_id, item_collection(item), item["sequence"] || item["component_id"]}

        case insert(acc, :relationship, key, item["relationships"]) do
          {:ok, acc} -> {:cont, {:ok, acc}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp item_collection(%{"evaluation_id" => _, "prelude_calls" => _}), do: :generated_sources
  defp item_collection(%{"component_id" => _, "sequence" => _}), do: :effective_preludes
  defp item_collection(_item), do: :execution_errors

  defp enrich_generated(state, generated) do
    Enum.map(generated, fn entry ->
      parent = Map.get(state.pending_parents, entry.evaluation_id)
      calls = Map.get(state.prelude_calls_by_eval, entry.evaluation_id)

      entry
      |> Map.put(:parent_evaluation_id, parent)
      |> Map.put(:prelude_calls, calls || [])
    end)
  end

  defp order_and_filters(state, collection, locator, filters) do
    ordinal = next_ordinal(state, collection)

    with {:ok, state} <-
           insert(state, :order, {state.run_id, collection, ordinal}, locator),
         {:ok, state} <- insert_filters(state, collection, ordinal, locator, filters) do
      {:ok, put_ordinal(state, collection, ordinal)}
    end
  end

  defp insert_filters(state, collection, ordinal, locator, filters) do
    Enum.reduce_while(filters, {:ok, state}, fn {filter, value}, {:ok, acc} ->
      key = {state.run_id, collection, filter, ValueHash.hash(value), ordinal}

      case insert(acc, :filter_posting, key, locator) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp next_ordinal(state, collection),
    do: get_in(state, [Access.key(:ordinals, %{}), collection]) |> Kernel.||(0) |> Kernel.+(1)

  defp put_ordinal(state, collection, ordinal),
    do: put_in(state, [Access.key(:ordinals, %{}), collection], ordinal)

  defp pair_filters(input, capability_id) do
    [
      {"capability_id", capability_id},
      {"input_sequence", input.sequence},
      {"mission_name", input.mission_name},
      {"name", input.name}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp source_filters(meta) do
    [
      {"evaluation_id", meta.evaluation_id},
      {"parent_evaluation_id", meta.parent_evaluation_id},
      {"mission_name", meta.mission_name}
    ]
    |> Kernel.++(call_filters(meta.prelude_calls))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp prelude_filters(meta) do
    [
      {"component_id", meta.component_id},
      {"environment", meta.environment},
      {"mission_name", meta.mission_name}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp provider_filters(request, capability_id, request_id) do
    [
      {"capability_id", capability_id},
      {"mission_name", request.mission_name},
      {"request_id", request_id}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp turn_filters(turn) do
    generated_filters =
      Enum.flat_map(turn.generated, fn generated ->
        [{"evaluation_id", generated.evaluation_id}]
      end)

    [{"stream_id", turn.stream_id}, {"capability_id", turn.capability_id} | generated_filters]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp call_filters(calls) when is_list(calls) do
    Enum.flat_map(calls, fn call ->
      [{"prelude_call", call["ref"]}, {"prelude_component", call["component_id"]}]
    end)
  end

  defp call_filters(_calls), do: []

  defp insert(state, family, key, value) do
    case Indexes.insert(state.indexes, family, key, value, state.limits) do
      {:ok, indexes} -> {:ok, %{state | indexes: indexes}}
      {:error, _reason} = error -> error
    end
  end
end
