defmodule PtcRunner.Kernel.InspectionArtifact.Assembler do
  @moduledoc """
  Builds ETS indexes from one streaming evidence record at a time.

  Collection order, filter postings, turn projections, and relationship rows are
  inserted after the last frame, once joins and conversation facts are closed.
  """

  alias PtcRunner.Kernel.FrozenBundle
  alias PtcRunner.Kernel.InspectionArtifact.Conversation
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.ValueHash
  alias PtcRunner.Kernel.ResultIdentity
  alias PtcRunner.Kernel.RunAnalysisRelationships
  alias PtcRunner.Lisp.RetainedSize

  @spec new(Indexes.t(), map(), nil | %{run_id: binary(), trace_id: binary()}) :: map()
  def new(indexes, limits, identity \\ nil) do
    %{
      indexes: indexes,
      limits: limits,
      run_id: identity && identity.run_id,
      trace_id: identity && identity.trace_id,
      schema_version: 9,
      first_timestamp: nil,
      last_timestamp: nil,
      first_sequence: 0,
      last_sequence: 0,
      record_count: 0,
      conversation: Conversation.new(),
      inputs: %{},
      outputs: %{},
      capture_modes: %{},
      exceptions: %{},
      mcp_requests: %{},
      mcp_responses: %{},
      mcp_stderrs: %{},
      analyses: %{},
      evaluations: MapSet.new(),
      preludes: MapSet.new(),
      execution_ids: %{prints: MapSet.new(), errors: MapSet.new(), failures: MapSet.new()},
      prelude_calls_by_eval: %{},
      generated_meta: [],
      prelude_meta: [],
      execution_meta: %{prints: [], errors: [], failures: []},
      result_sequence: nil,
      result_hash: nil
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

    with :ok <- validate_complete(state),
         :ok <- validate_trace(state, trace_facts),
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

  @doc false
  @spec validate_complete(map()) :: :ok | {:error, atom()}
  def validate_complete(state), do: closed_joins(state)

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
    mode = capture_mode(record["payload"], "result")

    if compatible_capability?(input, record) and not Map.has_key?(state.outputs, id) and
         compatible_capture?(state, id, mode) and
         valid_exception_output?(state, id, record["payload"], mode) do
      {:ok,
       %{
         state
         | outputs: Map.put(state.outputs, id, record["sequence"]),
           capture_modes: Map.put(state.capture_modes, id, mode)
       }}
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
    capability = Map.get(state.inputs, elem(key, 0))
    payload = record["payload"]

    if Map.has_key?(state.mcp_requests, key) or
         not mission_join?(capability, payload["mission_name"]) do
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
    id = elem(key, 0)
    request = Map.get(state.mcp_requests, key)
    payload = record["payload"]
    mode = capture_mode(payload, "body")

    if Map.has_key?(state.mcp_responses, key) or is_nil(request) or
         request.transport != payload["transport"] or
         request.mission_name != payload["mission_name"] or
         not compatible_capture?(state, id, mode) do
      {:error, :invalid_record}
    else
      {:ok,
       %{
         state
         | mcp_responses: Map.put(state.mcp_responses, key, record["sequence"]),
           capture_modes: Map.put(state.capture_modes, id, mode)
       }}
    end
  end

  defp put_join(state, %{"record_type" => "mcp-stderr"} = record) do
    key = mcp_key(record)
    request = Map.get(state.mcp_requests, key)
    payload = record["payload"]

    if Map.has_key?(state.mcp_stderrs, key) or is_nil(request) or
         request.transport != payload["transport"] or
         request.mission_name != payload["mission_name"] do
      {:error, :invalid_record}
    else
      {:ok, %{state | mcp_stderrs: Map.put(state.mcp_stderrs, key, record["sequence"])}}
    end
  end

  defp put_join(state, %{"record_type" => "evaluation-analysis"} = record) do
    id = record["correlation"]["evaluation_id"]

    with true <- MapSet.member?(state.evaluations, id),
         false <- Map.has_key?(state.analyses, id),
         {:ok, state} <-
           insert(state, :join_evaluation, {record["run_id"], id, :analysis}, record["sequence"]) do
      {:ok,
       %{
         state
         | analyses: Map.put(state.analyses, id, record["sequence"]),
           prelude_calls_by_eval:
             Map.put(state.prelude_calls_by_eval, id, %{
               mission_name: record["payload"]["mission_name"],
               calls: record["payload"]["prelude_calls"]
             })
       }}
    else
      _invalid -> {:error, :invalid_record}
    end
  end

  defp put_join(state, %{"record_type" => "evaluation-source"} = record) do
    id = record["correlation"]["evaluation_id"]

    if valid_source_payload?(record["payload"]) and not MapSet.member?(state.evaluations, id) do
      meta = %{
        sequence: record["sequence"],
        evaluation_id: id,
        environment: record["payload"]["environment"],
        mission_name: record["payload"]["mission_name"],
        source_hash: record["payload"]["source_hash"],
        source_bytes: record["payload"]["source_bytes"]
      }

      {:ok,
       %{
         state
         | generated_meta: [meta | state.generated_meta],
           evaluations: MapSet.put(state.evaluations, id)
       }}
    else
      {:error, :invalid_record}
    end
  end

  defp put_join(state, %{"record_type" => "prelude-source"} = record) do
    key =
      {record["payload"]["environment"], record["payload"]["mission_name"],
       record["correlation"]["component_id"]}

    if valid_source_payload?(record["payload"]) and not MapSet.member?(state.preludes, key) do
      meta = %{
        sequence: record["sequence"],
        component_id: record["correlation"]["component_id"],
        environment: record["payload"]["environment"],
        mission_name: record["payload"]["mission_name"],
        source_hash: record["payload"]["source_hash"]
      }

      {:ok,
       %{
         state
         | prelude_meta: [meta | state.prelude_meta],
           preludes: MapSet.put(state.preludes, key)
       }}
    else
      {:error, :invalid_record}
    end
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
    cond do
      not is_nil(state.result_sequence) ->
        {:error, :invalid_record}

      not valid_run_result?(record) ->
        {:error, :invalid_record}

      true ->
        insert(state, :result, record["run_id"], record["sequence"])
        |> case do
          {:ok, state} ->
            {:ok,
             %{
               state
               | result_sequence: record["sequence"],
                 result_hash: record["payload"]["result_hash"]
             }}

          error ->
            error
        end
    end
  end

  defp put_join(_state, _record), do: {:error, :invalid_record}

  defp valid_source_payload?(%{
         "source" => source,
         "source_hash" => hash,
         "source_bytes" => bytes
       })
       when is_binary(source) and is_binary(hash) and is_integer(bytes) do
    bytes == byte_size(source) and
      hash == Base.encode16(:crypto.hash(:sha256, source), case: :lower)
  end

  defp valid_source_payload?(_payload), do: false

  defp valid_run_result?(%{"payload" => %{"result_hash" => hash, "value" => value}}) do
    ResultIdentity.valid_hash?(hash) and ResultIdentity.strict_json_hash(value) == {:ok, hash}
  end

  defp valid_run_result?(_record), do: false

  defp put_execution(state, field, record) do
    meta = %{
      sequence: record["sequence"],
      evaluation_id: record["correlation"]["evaluation_id"],
      details: record["payload"]["details"]
    }

    seen = get_in(state, [:execution_ids, field])

    if MapSet.member?(seen, meta.evaluation_id) do
      {:error, :invalid_record}
    else
      {:ok,
       state
       |> update_in([:execution_meta, field], &[meta | &1])
       |> put_in([:execution_ids, field], MapSet.put(seen, meta.evaluation_id))}
    end
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

  defp mission_join?(%{environment: "mission", mission_name: mission_name}, mission_name)
       when is_binary(mission_name),
       do: true

  defp mission_join?(%{environment: "workflow", mission_name: nil}, nil), do: true
  defp mission_join?(_input, _mission_name), do: false

  defp valid_exception_output?(state, id, payload, :full) do
    not Map.has_key?(state.exceptions, id) or
      match?(
        %{
          "status" => "error",
          "kind" => "provider_error",
          "reason" => "exception",
          "retryable?" => false
        },
        payload["result"]
      )
  end

  defp valid_exception_output?(_state, _id, _payload, :digest_results), do: true

  defp capture_mode(payload, value_key),
    do: if(Map.has_key?(payload, value_key), do: :full, else: :digest_results)

  defp compatible_capture?(state, id, mode),
    do: Map.get(state.capture_modes, id, mode) == mode

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

  defp validate_trace(state, trace_facts) do
    with true <- trace_facts["trace_id"] == state.trace_id,
         {:ok, preludes} <- canonical_preludes(trace_facts),
         :ok <- validate_prelude_identities(state.prelude_meta, preludes),
         :ok <- validate_prelude_calls(state.prelude_calls_by_eval, preludes),
         :ok <- validate_result(state, trace_facts["terminal_result"]),
         :ok <- validate_canonical_records(state, trace_facts, preludes) do
      :ok
    else
      _unproven -> {:error, :inspection_correlation_missing}
    end
  end

  defp canonical_preludes(trace_facts) do
    workflow = put_projection(%{}, {"workflow", nil}, trace_facts["workflow_prelude"])

    Enum.reduce_while(trace_facts["missions"] || %{}, workflow, fn {mission, metadata},
                                                                   {:ok, acc} ->
      case put_projection(acc, {"mission", mission}, metadata["prelude"]) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp put_projection(acc, _key, nil), do: {:ok, acc}

  defp put_projection(acc, key, %{
         "component_ids" => ids,
         "dependency_indices" => indices,
         "hash" => hash
       })
       when is_list(ids) and is_list(indices) do
    {:ok, Map.put(acc, key, %{component_ids: ids, dependency_indices: indices, hash: hash})}
  end

  defp put_projection(_acc, _key, _projection), do: {:error, :inspection_correlation_missing}

  defp validate_prelude_identities(records, preludes) do
    groups =
      Enum.group_by(
        records,
        &{&1.environment, &1.mission_name},
        &{&1.component_id, &1.source_hash}
      )

    committed =
      preludes
      |> Enum.filter(fn {_key, projection} -> not is_nil(projection.hash) end)
      |> MapSet.new(&elem(&1, 0))

    groups
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.union(committed)
    |> Enum.reduce_while(:ok, fn key, :ok ->
      if prelude_identity_proven?(Map.get(groups, key, []), Map.get(preludes, key)),
        do: {:cont, :ok},
        else: {:halt, {:error, :inspection_correlation_missing}}
    end)
  end

  defp prelude_identity_proven?(_sources, nil), do: false

  defp prelude_identity_proven?(sources, projection) do
    hashes = Map.new(sources)
    ids = projection.component_ids

    with true <- map_size(hashes) == length(sources),
         true <- MapSet.new(Map.keys(hashes)) == MapSet.new(ids),
         true <- length(projection.dependency_indices) == length(ids),
         {:ok, identity} <- FrozenBundle.identity(prelude_components(projection, hashes)) do
      identity == projection.hash
    else
      _unproven -> false
    end
  end

  defp prelude_components(projection, hashes) do
    projection.dependency_indices
    |> Enum.with_index()
    |> Enum.map(fn {indices, position} ->
      id = Enum.at(projection.component_ids, position)

      %{
        id: id,
        dependencies: Enum.map(indices, &Enum.at(projection.component_ids, &1)),
        source_hash: Map.fetch!(hashes, id)
      }
    end)
  end

  defp validate_prelude_calls(calls_by_evaluation, preludes) do
    Enum.reduce_while(calls_by_evaluation, :ok, fn {_evaluation_id, analysis}, :ok ->
      mission = analysis.mission_name
      component_ids = prelude_component_ids(preludes, {"mission", mission})

      if is_binary(mission) and
           Enum.all?(analysis.calls, &MapSet.member?(component_ids, &1["component_id"])),
         do: {:cont, :ok},
         else: {:halt, {:error, :inspection_correlation_missing}}
    end)
  end

  defp prelude_component_ids(preludes, key) do
    case Map.fetch(preludes, key) do
      {:ok, projection} -> MapSet.new(projection.component_ids)
      :error -> MapSet.new()
    end
  end

  defp validate_result(%{result_sequence: nil}, _terminal), do: :ok

  defp validate_result(state, %{"outcome" => "ok", "result_hash" => result_hash})
       when result_hash == state.result_hash,
       do: :ok

  defp validate_result(_state, _terminal), do: {:error, :inspection_correlation_missing}

  defp validate_canonical_records(state, trace_facts, preludes) do
    canonical_capabilities = trace_facts["capabilities"] || %{}
    canonical_evaluations = trace_facts["evaluations"] || %{}

    with {:ok, missing_capabilities} <-
           validate_capabilities(state.inputs, canonical_capabilities),
         {:ok, missing_evaluations} <-
           validate_evaluations(state, canonical_evaluations, preludes),
         true <-
           MapSet.size(missing_capabilities) <=
             dropped(trace_facts, "capability-started"),
         true <-
           map_size(missing_evaluations) <= dropped(trace_facts, "evaluation-started") do
      :ok
    else
      _unproven -> {:error, :inspection_correlation_missing}
    end
  end

  defp validate_capabilities(inputs, canonical) do
    Enum.reduce_while(inputs, {:ok, MapSet.new()}, fn {id, input}, {:ok, missing} ->
      expected = %{
        "environment" => input.environment,
        "mission_name" => input.mission_name,
        "name" => input.name
      }

      case Map.fetch(canonical, id) do
        {:ok, ^expected} -> {:cont, {:ok, missing}}
        :error -> {:cont, {:ok, MapSet.put(missing, id)}}
        {:ok, _mismatch} -> {:halt, {:error, :inspection_correlation_missing}}
      end
    end)
  end

  defp validate_evaluations(state, canonical, _preludes) do
    checks =
      Enum.map(state.generated_meta, fn meta ->
        {meta.evaluation_id,
         {meta.environment, meta.mission_name, meta.source_hash, meta.source_bytes}}
      end) ++
        Enum.flat_map(state.execution_ids, fn {_kind, ids} ->
          Enum.map(ids, &{&1, {"workflow", nil, :any, :any}})
        end)

    Enum.reduce_while(checks, {:ok, %{}}, fn {id, expected}, {:ok, missing} ->
      case Map.fetch(canonical, id) do
        {:ok, actual} ->
          if evaluation_matches?(actual, expected),
            do: {:cont, {:ok, missing}},
            else: {:halt, {:error, :inspection_correlation_missing}}

        :error ->
          owner = {elem(expected, 0), elem(expected, 1)}

          case Map.fetch(missing, id) do
            :error -> {:cont, {:ok, Map.put(missing, id, owner)}}
            {:ok, ^owner} -> {:cont, {:ok, missing}}
            {:ok, _other} -> {:halt, {:error, :inspection_correlation_missing}}
          end
      end
    end)
  end

  defp evaluation_matches?(actual, {environment, mission, :any, :any}) do
    actual["environment"] == environment and actual["mission_name"] == mission
  end

  defp evaluation_matches?(actual, {environment, mission, hash, bytes}) do
    actual == %{
      "environment" => environment,
      "mission_name" => mission,
      "source_hash" => hash,
      "source_bytes" => bytes
    }
  end

  defp dropped(trace_facts, type) do
    case get_in(trace_facts, ["dropped_event_counts", type]) do
      count when is_integer(count) and count > 0 -> count
      _other -> 0
    end
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
      analysis = Map.get(acc.prelude_calls_by_eval, meta.evaluation_id)
      prelude_calls = if analysis, do: analysis.calls

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
        analysis = Map.get(state.prelude_calls_by_eval, meta.evaluation_id)
        calls = if analysis, do: analysis.calls

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
          "details" => meta.details || %{}
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
      analysis = Map.get(state.prelude_calls_by_eval, entry.evaluation_id)
      calls = if analysis, do: analysis.calls

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
