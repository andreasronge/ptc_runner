defmodule PtcRunner.Kernel.InspectionQuery do
  @moduledoc """
  Pure, source-bound queries over validated private inspection records.

  The compiler performs the joins once, before a snapshot publishes any
  capability. Capability inputs and outputs are paired by `capability_id`, and
  a validated input without an output is retained as an explicitly incomplete
  interrupted attempt. MCP request and response bodies remain paired by
  `{capability_id, request_id}`. Callers therefore never join private records
  by timestamp or depend on file order beyond the artifact's validated
  sequence.

  Every collection uses the same bounded page shape as canonical trace
  queries. Cursors are opaque, bind the immutable source identity, operation,
  filters, ordering, and offset, and cannot be reused against another query or
  capture. Run-scoped private collections accept `"order": "asc" | "desc"`;
  ascending sequence order is the default.

  Inspection artifacts retain their versioned bare-hex source hashes. Query
  results expose those hashes with the `sha256:` algorithm prefix required by
  trusted component-override descriptors, so an effective-prelude result can
  be copied into `base_source_hash` without reinterpretation.

  Execution-phase diagnostics (`execution-prints`, `execution-error`) are
  exposed as run-scoped collections alongside their counts in each `list_runs`
  row. Their items retain the correlated `evaluation_id`, sequence, timestamp,
  environment, and exact bounded diagnostic payload.
  Projections include `mission_name` on every mission-owned result so
  repeated component and capability names remain unambiguous.
  V6 adds one singular, non-paginated terminal `result` projection per run and
  joins static prelude-call analysis to generated source by `evaluation_id`.
  Generated source and reconstructed turns copy the canonical
  `parent_evaluation_id` edge rather than inferring one from snapshot-local
  sequence numbers.
  """

  alias PtcRunner.Kernel.ConversationProjection

  @default_limit 100
  @max_limit 1_000
  @max_cursor_bytes 2_048
  @operations [
    :list_runs,
    :get_run,
    :turns,
    :model_exchanges,
    :capability_calls,
    :generated_sources,
    :effective_preludes,
    :provider_exchanges,
    :execution_prints,
    :execution_errors,
    :result
  ]

  @type operation ::
          :list_runs
          | :get_run
          | :turns
          | :model_exchanges
          | :capability_calls
          | :generated_sources
          | :effective_preludes
          | :provider_exchanges
          | :execution_prints
          | :execution_errors
          | :result

  @spec compile([[map()]], binary(), map()) ::
          {:ok, %{source_id: binary(), collections: map()}} | {:error, atom()}
  @doc false
  def compile(artifacts, trace_source_id, trace_analysis)
      when is_list(artifacts) and is_binary(trace_source_id) and is_map(trace_analysis) do
    with {:ok, compiled} <- compile_artifacts(artifacts),
         {:ok, collections} <- merge_artifacts(compiled, trace_analysis),
         source_id <- digest({trace_source_id, artifacts}) do
      {:ok, %{source_id: source_id, collections: collections}}
    else
      {:error, _reason} = error -> error
    end
  end

  def compile(_artifacts, _trace_source_id, _trace_analysis),
    do: {:error, :invalid_inspection_snapshot}

  @spec query(map(), binary(), operation(), map(), pos_integer()) ::
          {:ok, map()} | {:error, atom()}
  @doc false
  def query(collections, source_id, operation, arguments, max_result_bytes)
      when is_map(collections) and is_binary(source_id) and operation in @operations and
             is_map(arguments) and is_integer(max_result_bytes) and max_result_bytes > 0 do
    execute(collections, source_id, operation, arguments, max_result_bytes)
  end

  def query(_collections, _source_id, _operation, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

  defp compile_artifacts(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn records, {:ok, compiled} ->
      case compile_artifact(records) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | compiled]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, compiled} -> {:ok, Enum.reverse(compiled)}
      {:error, _reason} = error -> error
    end
  end

  defp compile_artifact([first | _rest] = records) do
    with {:ok, capability_pairs} <- capability_pairs(records),
         {:ok, provider_pairs} <- provider_pairs(records) do
      model_exchanges = Enum.filter(capability_pairs, &model_exchange?/1)
      capability_calls = Enum.reject(capability_pairs, &model_exchange?/1)

      evaluation_analyses =
        records
        |> records_of_type("evaluation-analysis")
        |> Map.new(&{&1["correlation"]["evaluation_id"], &1["payload"]["prelude_calls"]})

      generated_sources =
        records
        |> records_of_type("evaluation-source")
        |> Enum.map(&source_item(&1, evaluation_analyses))

      effective_preludes =
        records
        |> records_of_type("prelude-source")
        |> Enum.map(&prelude_item/1)

      execution_prints =
        records
        |> records_of_type("execution-prints")
        |> Enum.map(&execution_item/1)

      execution_errors =
        records
        |> records_of_type("execution-error")
        |> Enum.map(&execution_item/1)

      result =
        records
        |> Enum.find(&(&1["record_type"] == "run-result"))
        |> result_item()

      counts = %{
        "model_exchanges" => length(model_exchanges),
        "incomplete_model_exchanges" => incomplete_count(model_exchanges),
        "capability_calls" => length(capability_calls),
        "incomplete_capability_calls" => incomplete_count(capability_calls),
        "generated_sources" => length(generated_sources),
        "evaluation_analyses" => map_size(evaluation_analyses),
        "effective_preludes" => length(effective_preludes),
        "provider_exchanges" => length(provider_pairs),
        "execution_prints" => length(execution_prints),
        "execution_errors" => length(execution_errors)
      }

      {:ok,
       %{
         run: %{
           "run_id" => first["run_id"],
           "trace_id" => first["trace_id"],
           "schema_version" => first["schema_version"],
           "record_count" => length(records),
           "first_timestamp" => first["timestamp"],
           "last_timestamp" => List.last(records)["timestamp"],
           "counts" => counts
         },
         model_exchanges: model_exchanges,
         capability_calls: capability_calls,
         generated_sources: generated_sources,
         effective_preludes: effective_preludes,
         provider_exchanges: provider_pairs,
         execution_prints: execution_prints,
         execution_errors: execution_errors,
         result: result
       }}
    end
  end

  defp compile_artifact(_records), do: {:error, :invalid_inspection_snapshot}

  defp capability_pairs(records) do
    inputs =
      records
      |> records_of_type("capability-input")
      |> Map.new(&{&1["correlation"]["capability_id"], &1})

    outputs =
      records
      |> records_of_type("capability-output")
      |> Map.new(&{&1["correlation"]["capability_id"], &1})

    pairs =
      inputs
      |> Enum.map(fn {capability_id, input} ->
        capability_pair(capability_id, input, Map.get(outputs, capability_id))
      end)
      |> Enum.sort_by(& &1["input_sequence"])

    {:ok, pairs}
  end

  defp provider_pairs(records) do
    requests =
      records
      |> records_of_type("mcp-request")
      |> Map.new(fn record ->
        correlation = record["correlation"]
        {{correlation["capability_id"], correlation["request_id"]}, record}
      end)

    responses =
      records
      |> records_of_type("mcp-response")
      |> Map.new(fn record ->
        correlation = record["correlation"]
        {{correlation["capability_id"], correlation["request_id"]}, record}
      end)

    if Map.keys(requests) |> MapSet.new() == Map.keys(responses) |> MapSet.new() do
      pairs =
        requests
        |> Enum.map(fn {{capability_id, request_id}, request} ->
          provider_pair(
            capability_id,
            request_id,
            request,
            Map.fetch!(responses, {capability_id, request_id})
          )
        end)
        |> Enum.sort_by(& &1["request_sequence"])

      {:ok, pairs}
    else
      {:error, :incomplete_inspection_correlation}
    end
  end

  defp capability_pair(capability_id, input, nil) do
    capability_input(capability_id, input)
    |> Map.put("complete?", false)
  end

  defp capability_pair(capability_id, input, output) do
    capability_input(capability_id, input)
    |> Map.merge(%{
      "complete?" => true,
      "output_sequence" => output["sequence"],
      "output_timestamp" => output["timestamp"],
      "result" => output["payload"]["result"]
    })
  end

  defp capability_input(capability_id, input) do
    input_payload = input["payload"]

    %{
      "run_id" => input["run_id"],
      "trace_id" => input["trace_id"],
      "capability_id" => capability_id,
      "environment" => input_payload["environment"],
      "mission_name" => input_payload["mission_name"],
      "name" => input_payload["name"],
      "input_sequence" => input["sequence"],
      "input_timestamp" => input["timestamp"],
      "arguments" => input_payload["arguments"]
    }
  end

  defp incomplete_count(items), do: Enum.count(items, &(&1["complete?"] == false))

  defp provider_pair(capability_id, request_id, request, response) do
    request_payload = request["payload"]
    response_payload = response["payload"]

    %{
      "run_id" => request["run_id"],
      "trace_id" => request["trace_id"],
      "capability_id" => capability_id,
      "request_id" => request_id,
      "transport" => request_payload["transport"],
      "mission_name" => request_payload["mission_name"],
      "request_sequence" => request["sequence"],
      "response_sequence" => response["sequence"],
      "request_timestamp" => request["timestamp"],
      "response_timestamp" => response["timestamp"],
      "request" => request_payload["body"],
      "response" => response_payload["body"]
    }
  end

  defp source_item(record, analyses) do
    payload = record["payload"]
    evaluation_id = record["correlation"]["evaluation_id"]
    prelude_calls = Map.get(analyses, evaluation_id)

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "evaluation_id" => evaluation_id,
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "environment" => payload["environment"],
      "mission_name" => payload["mission_name"],
      "program_kind" => payload["program_kind"],
      "source" => payload["source"],
      "source_hash" => descriptor_hash(payload["source_hash"]),
      "source_bytes" => payload["source_bytes"],
      "prelude_calls_available?" => is_list(prelude_calls),
      "prelude_calls" => prelude_calls || []
    }
  end

  defp prelude_item(record) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "component_id" => record["correlation"]["component_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "environment" => payload["environment"],
      "mission_name" => payload["mission_name"],
      "source" => payload["source"],
      "source_hash" => descriptor_hash(payload["source_hash"]),
      "source_bytes" => payload["source_bytes"]
    }
  end

  defp execution_item(record) do
    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "evaluation_id" => record["correlation"]["evaluation_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"]
    }
    |> Map.merge(record["payload"])
  end

  defp result_item(nil), do: nil

  defp result_item(record) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "result_hash" => payload["result_hash"],
      "value" => payload["value"]
    }
  end

  defp descriptor_hash(hash), do: "sha256:" <> hash

  defp model_exchange?(%{"environment" => "workflow", "name" => "llm-request"}), do: true
  defp model_exchange?(_pair), do: false

  defp records_of_type(records, type),
    do: Enum.filter(records, &(&1["record_type"] == type))

  defp merge_artifacts(compiled, %{"runs" => trace_facts} = trace_analysis)
       when is_map(trace_facts) do
    generated_sources =
      compiled
      |> merge_collection(:generated_sources)
      |> Enum.map(&attach_parent_evaluation_id(&1, trace_facts))

    collections = %{
      list_runs: compiled |> Enum.map(& &1.run) |> Enum.sort_by(& &1["run_id"]),
      model_exchanges: merge_collection(compiled, :model_exchanges),
      capability_calls: merge_collection(compiled, :capability_calls),
      generated_sources: generated_sources,
      effective_preludes: merge_collection(compiled, :effective_preludes),
      provider_exchanges: merge_collection(compiled, :provider_exchanges),
      execution_prints: merge_collection(compiled, :execution_prints),
      execution_errors: merge_collection(compiled, :execution_errors),
      results: compiled |> Enum.map(& &1.result) |> Enum.reject(&is_nil/1)
    }

    turns =
      Map.new(collections.list_runs, fn run ->
        run_id = run["run_id"]

        projection =
          ConversationProjection.compile(
            Enum.filter(
              collections.model_exchanges,
              &(&1["run_id"] == run_id and &1["complete?"])
            ),
            Enum.filter(collections.generated_sources, &(&1["run_id"] == run_id)),
            Map.get(trace_facts, run_id, %{})
          )
          |> Map.update!(:items, fn items ->
            Enum.map(items, &Map.merge(&1, %{"run_id" => run_id, "trace_id" => run["trace_id"]}))
          end)

        {run_id, projection}
      end)

    {:ok,
     collections
     |> Map.put(:runs_by_id, Map.new(collections.list_runs, &{&1["run_id"], &1}))
     |> Map.put(:turns_by_run_id, turns)
     |> Map.put(:turns, turns |> Map.values() |> Enum.flat_map(& &1.items))
     |> Map.put(:trace_snapshot_hash, trace_analysis["trace_snapshot_hash"])}
  end

  defp merge_artifacts(_compiled, _trace_analysis), do: {:error, :invalid_inspection_snapshot}

  defp attach_parent_evaluation_id(source, trace_facts) do
    parent_evaluation_id =
      get_in(trace_facts, [source["run_id"], "parent_evaluation_ids", source["evaluation_id"]])

    if is_binary(parent_evaluation_id),
      do: Map.put(source, "parent_evaluation_id", parent_evaluation_id),
      else: source
  end

  defp merge_collection(compiled, operation) do
    compiled
    |> Enum.flat_map(&Map.fetch!(&1, operation))
    |> Enum.sort_by(&{&1["run_id"], item_sequence(&1)})
  end

  defp item_sequence(%{"input_sequence" => sequence}), do: sequence
  defp item_sequence(%{"request_sequence" => sequence}), do: sequence
  defp item_sequence(%{"sequence" => sequence}), do: sequence

  defp execute(collections, source_id, :list_runs, arguments, max_result_bytes) do
    with :ok <- validate_keys(arguments, ~w(limit cursor)),
         {:ok, page} <- page_options(arguments, source_id, :list_runs) do
      paginate(collections.list_runs, page, source_id, max_result_bytes)
    end
  end

  defp execute(collections, _source_id, :get_run, %{"run_id" => run_id} = arguments, max_bytes) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         true <- valid_string?(run_id),
         {:ok, run} <- Map.fetch(collections.runs_by_id, run_id),
         :ok <- validate_result_size(run, max_bytes) do
      {:ok, run}
    else
      false -> {:error, :invalid_query}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_collections, _source_id, :get_run, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

  defp execute(collections, _source_id, :result, %{"run_id" => run_id} = arguments, max_bytes) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- validate_result_run_id(run_id, collections.list_runs),
         {:ok, result} <- fetch_result(collections.results, run_id),
         :ok <- validate_result_size(result, max_bytes) do
      {:ok, result}
    end
  end

  defp execute(_collections, _source_id, :result, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

  defp execute(collections, source_id, :turns, %{"run_id" => run_id} = arguments, max_bytes) do
    allowed =
      ~w(run_id limit cursor stream_id capability_id evaluation_id parent_evaluation_id prelude_call prelude_component)

    with :ok <- validate_keys(arguments, allowed),
         true <- valid_string?(run_id),
         :ok <- validate_filter_values(arguments, allowed -- ~w(run_id limit cursor)),
         {:ok, projection} <- Map.fetch(collections.turns_by_run_id, run_id),
         {:ok, page} <- page_options(arguments, source_id, :turns) do
      metadata = %{
        "evidence" => projection.evidence,
        "trace_snapshot_hash" => collections.trace_snapshot_hash
      }

      projection.items
      |> Enum.filter(&collection_match?(:turns, &1, arguments))
      |> paginate(page, source_id, max_bytes, metadata)
    else
      false -> {:error, :invalid_query}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_collections, _source_id, :turns, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

  defp execute(collections, source_id, operation, %{"run_id" => run_id} = arguments, max_bytes)
       when operation in [
              :model_exchanges,
              :capability_calls,
              :generated_sources,
              :effective_preludes,
              :provider_exchanges,
              :execution_prints,
              :execution_errors
            ] do
    allowed = ~w(run_id limit cursor order) ++ collection_filters(operation)

    with :ok <- validate_keys(arguments, allowed),
         true <- valid_string?(run_id),
         :ok <- validate_order(arguments),
         :ok <- validate_filter_values(arguments, collection_filters(operation)),
         true <- Enum.any?(collections.list_runs, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, operation) do
      collections
      |> Map.fetch!(operation)
      |> Enum.filter(&(&1["run_id"] == run_id and collection_match?(operation, &1, arguments)))
      |> order(Map.get(arguments, "order", "asc"))
      |> paginate(page, source_id, max_bytes)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_collections, _source_id, _operation, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

  defp validate_result_run_id(run_id, runs) do
    cond do
      not valid_string?(run_id) -> {:error, :invalid_query}
      Enum.any?(runs, &(&1["run_id"] == run_id)) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp fetch_result(results, run_id) do
    case Enum.find(results, &(&1["run_id"] == run_id)) do
      nil -> {:error, :result_not_found}
      result -> {:ok, result}
    end
  end

  defp validate_result_size(result, max_bytes) do
    if byte_size(Jason.encode!(result)) <= max_bytes,
      do: :ok,
      else: {:error, :result_limit_exceeded}
  end

  defp validate_keys(arguments, allowed) do
    if Map.keys(arguments) -- allowed == [],
      do: :ok,
      else: {:error, :invalid_query}
  end

  defp valid_string?(value),
    do: is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value)

  defp validate_order(%{"order" => order}) when order in ["asc", "desc"], do: :ok
  defp validate_order(arguments) when not is_map_key(arguments, "order"), do: :ok
  defp validate_order(_arguments), do: {:error, :invalid_query}

  defp collection_filters(:model_exchanges), do: ~w(capability_id input_sequence)
  defp collection_filters(:capability_calls), do: ~w(capability_id mission_name name)
  defp collection_filters(:provider_exchanges), do: ~w(capability_id mission_name request_id)

  defp collection_filters(:generated_sources),
    do: ~w(evaluation_id parent_evaluation_id mission_name prelude_call prelude_component)

  defp collection_filters(:effective_preludes),
    do: ~w(component_id environment mission_name)

  defp collection_filters(operation) when operation in [:execution_prints, :execution_errors],
    do: ["evaluation_id"]

  defp validate_filter_values(arguments, filters) do
    valid? =
      Enum.all?(filters, fn
        filter when filter in ["input_sequence", "request_id"] ->
          is_nil(arguments[filter]) or (is_integer(arguments[filter]) and arguments[filter] > 0)

        filter ->
          is_nil(arguments[filter]) or valid_string?(arguments[filter])
      end)

    if valid?, do: :ok, else: {:error, :invalid_query}
  end

  defp collection_match?(:turns, item, arguments) do
    equal_filter?(item, arguments, "stream_id") and
      equal_filter?(item, arguments, "capability_id") and
      generated_equal_match?(item, arguments["evaluation_id"], "evaluation_id") and
      generated_equal_match?(
        item,
        arguments["parent_evaluation_id"],
        "parent_evaluation_id"
      ) and
      generated_call_match?(item, arguments["prelude_call"], "ref") and
      generated_call_match?(item, arguments["prelude_component"], "component_id")
  end

  defp collection_match?(:generated_sources, item, arguments) do
    equal_filter?(item, arguments, "evaluation_id") and
      equal_filter?(item, arguments, "parent_evaluation_id") and
      equal_filter?(item, arguments, "mission_name") and
      call_match?(item, arguments["prelude_call"], "ref") and
      call_match?(item, arguments["prelude_component"], "component_id")
  end

  defp collection_match?(_operation, item, arguments) do
    arguments
    |> Map.drop(~w(run_id limit cursor order prelude_call prelude_component))
    |> Enum.all?(fn {key, value} -> is_nil(value) or item[key] == value end)
  end

  defp generated_call_match?(_item, nil, _key), do: true

  defp generated_call_match?(item, expected, key) do
    item
    |> Map.get("generated", [])
    |> Enum.any?(&call_match?(&1, expected, key))
  end

  defp generated_equal_match?(_item, nil, _key), do: true

  defp generated_equal_match?(item, expected, key) do
    item
    |> Map.get("generated", [])
    |> Enum.any?(&(&1[key] == expected))
  end

  defp call_match?(_item, nil, _key), do: true

  defp call_match?(item, expected, key) do
    item
    |> Map.get("prelude_calls", [])
    |> Enum.any?(&(&1[key] == expected))
  end

  defp equal_filter?(item, arguments, key),
    do: is_nil(arguments[key]) or item[key] == arguments[key]

  defp order(items, "asc"), do: items
  defp order(items, "desc"), do: Enum.reverse(items)

  defp page_options(arguments, source_id, operation) do
    limit = Map.get(arguments, "limit", @default_limit)
    query_id = digest({operation, Map.drop(arguments, ["cursor", "limit"])})

    with true <- is_integer(limit) and limit in 1..@max_limit,
         {:ok, offset} <- cursor_offset(Map.get(arguments, "cursor"), source_id, query_id) do
      {:ok, %{limit: limit, offset: offset, query_id: query_id}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(nil, _source_id, _query_id), do: {:ok, 0}

  defp cursor_offset(cursor, source_id, query_id)
       when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{"offset" => offset, "source" => cursor_source, "query" => cursor_query} = payload} <-
           Jason.decode(encoded),
         true <- map_size(payload) == 3,
         true <- is_integer(offset) and offset >= 0,
         true <- is_binary(cursor_source) and is_binary(cursor_query) do
      cond do
        cursor_source != source_id -> {:error, :source_changed}
        cursor_query != query_id -> {:error, :invalid_query}
        true -> {:ok, offset}
      end
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp cursor_offset(_cursor, _source_id, _query_id), do: {:error, :invalid_query}

  defp paginate(items, page, source_id, max_result_bytes, metadata \\ %{}) do
    selected = items |> Enum.drop(page.offset) |> Enum.take(page.limit)
    fit_page(selected, items, page.offset, source_id, page.query_id, max_result_bytes, metadata)
  end

  defp fit_page(selected, all_items, offset, source_id, query_id, max_result_bytes, metadata) do
    result = page_result(selected, all_items, offset, source_id, query_id, metadata)

    cond do
      byte_size(Jason.encode!(result)) <= max_result_bytes ->
        {:ok, result}

      selected == [] ->
        {:error, :result_limit_exceeded}

      true ->
        context = {all_items, offset, source_id, query_id, max_result_bytes, metadata}

        fit_page_prefix(
          selected,
          context,
          1,
          length(selected) - 1,
          nil
        )
    end
  end

  defp fit_page_prefix(_selected, _context, lower, upper, best)
       when lower > upper do
    if best, do: {:ok, best}, else: {:error, :result_limit_exceeded}
  end

  defp fit_page_prefix(
         selected,
         {all_items, offset, source_id, query_id, max_result_bytes, metadata} = context,
         lower,
         upper,
         best
       ) do
    count = div(lower + upper, 2)

    result =
      page_result(Enum.take(selected, count), all_items, offset, source_id, query_id, metadata)

    if byte_size(Jason.encode!(result)) <= max_result_bytes do
      fit_page_prefix(
        selected,
        context,
        count + 1,
        upper,
        result
      )
    else
      fit_page_prefix(
        selected,
        context,
        lower,
        count - 1,
        best
      )
    end
  end

  defp page_result(selected, all_items, offset, source_id, query_id, metadata) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    Map.merge(metadata, %{
      "items" => selected,
      "next_cursor" => if(more?, do: encode_cursor(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    })
  end

  defp encode_cursor(offset, source_id, query_id) do
    %{"offset" => offset, "source" => source_id, "query" => query_id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
