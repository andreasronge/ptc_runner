defmodule PtcRunner.Kernel.InspectionQuery do
  @moduledoc """
  Pure, source-bound queries over validated private inspection records.

  The compiler performs the joins once, before a snapshot publishes any
  capability. Capability inputs and outputs are paired by `capability_id`;
  MCP request and response bodies are paired by `{capability_id, request_id}`.
  Callers therefore never join private records by timestamp or depend on file
  order beyond the artifact's validated sequence.

  Every collection uses the same bounded page shape as canonical trace
  queries. Cursors are opaque, bind the immutable source identity, operation,
  filters, ordering, and offset, and cannot be reused against another query or
  capture. Run-scoped private collections accept `"order": "asc" | "desc"`;
  ascending sequence order is the default.

  Inspection artifacts retain their versioned bare-hex source hashes. Query
  results expose those hashes with the `sha256:` algorithm prefix required by
  trusted component-override descriptors, so an effective-prelude result can
  be copied into `base_source_hash` without reinterpretation.
  """

  @default_limit 100
  @max_limit 1_000
  @max_cursor_bytes 2_048
  @operations [
    :list_runs,
    :model_exchanges,
    :capability_calls,
    :generated_sources,
    :effective_preludes,
    :provider_exchanges
  ]

  @type operation ::
          :list_runs
          | :model_exchanges
          | :capability_calls
          | :generated_sources
          | :effective_preludes
          | :provider_exchanges

  @spec compile([[map()]], binary()) ::
          {:ok, %{source_id: binary(), collections: map()}} | {:error, atom()}
  @doc false
  def compile(artifacts, trace_source_id)
      when is_list(artifacts) and is_binary(trace_source_id) do
    with {:ok, compiled} <- compile_artifacts(artifacts),
         source_id <- digest({trace_source_id, artifacts}) do
      {:ok, %{source_id: source_id, collections: merge_artifacts(compiled)}}
    else
      {:error, _reason} = error -> error
    end
  end

  def compile(_artifacts, _trace_source_id), do: {:error, :invalid_inspection_snapshot}

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

      generated_sources =
        records
        |> records_of_type("evaluation-source")
        |> Enum.map(&source_item/1)

      effective_preludes =
        records
        |> records_of_type("prelude-source")
        |> Enum.map(&prelude_item/1)

      counts = %{
        "model_exchanges" => length(model_exchanges),
        "capability_calls" => length(capability_calls),
        "generated_sources" => length(generated_sources),
        "effective_preludes" => length(effective_preludes),
        "provider_exchanges" => length(provider_pairs)
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
         provider_exchanges: provider_pairs
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

    if Map.keys(inputs) |> MapSet.new() == Map.keys(outputs) |> MapSet.new() do
      pairs =
        inputs
        |> Enum.map(fn {capability_id, input} ->
          capability_pair(capability_id, input, Map.fetch!(outputs, capability_id))
        end)
        |> Enum.sort_by(& &1["input_sequence"])

      {:ok, pairs}
    else
      {:error, :incomplete_inspection_correlation}
    end
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

  defp capability_pair(capability_id, input, output) do
    input_payload = input["payload"]
    output_payload = output["payload"]

    %{
      "run_id" => input["run_id"],
      "trace_id" => input["trace_id"],
      "capability_id" => capability_id,
      "evaluation_id" => input_payload["evaluation_id"],
      "environment" => input_payload["environment"],
      "name" => input_payload["name"],
      "input_sequence" => input["sequence"],
      "output_sequence" => output["sequence"],
      "input_timestamp" => input["timestamp"],
      "output_timestamp" => output["timestamp"],
      "arguments" => input_payload["arguments"],
      "result" => output_payload["result"]
    }
  end

  defp provider_pair(capability_id, request_id, request, response) do
    request_payload = request["payload"]
    response_payload = response["payload"]

    %{
      "run_id" => request["run_id"],
      "trace_id" => request["trace_id"],
      "capability_id" => capability_id,
      "request_id" => request_id,
      "transport" => request_payload["transport"],
      "request_sequence" => request["sequence"],
      "response_sequence" => response["sequence"],
      "request_timestamp" => request["timestamp"],
      "response_timestamp" => response["timestamp"],
      "request" => request_payload["body"],
      "response" => response_payload["body"]
    }
  end

  defp source_item(record) do
    payload = record["payload"]

    %{
      "run_id" => record["run_id"],
      "trace_id" => record["trace_id"],
      "evaluation_id" => record["correlation"]["evaluation_id"],
      "sequence" => record["sequence"],
      "timestamp" => record["timestamp"],
      "environment" => payload["environment"],
      "program_kind" => payload["program_kind"],
      "source" => payload["source"],
      "source_hash" => descriptor_hash(payload["source_hash"]),
      "source_bytes" => payload["source_bytes"]
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
      "source" => payload["source"],
      "source_hash" => descriptor_hash(payload["source_hash"]),
      "source_bytes" => payload["source_bytes"]
    }
  end

  defp descriptor_hash(hash), do: "sha256:" <> hash

  defp model_exchange?(%{"environment" => "workflow", "name" => "llm-request"}), do: true
  defp model_exchange?(_pair), do: false

  defp records_of_type(records, type),
    do: Enum.filter(records, &(&1["record_type"] == type))

  defp merge_artifacts(compiled) do
    %{
      list_runs: compiled |> Enum.map(& &1.run) |> Enum.sort_by(& &1["run_id"]),
      model_exchanges: merge_collection(compiled, :model_exchanges),
      capability_calls: merge_collection(compiled, :capability_calls),
      generated_sources: merge_collection(compiled, :generated_sources),
      effective_preludes: merge_collection(compiled, :effective_preludes),
      provider_exchanges: merge_collection(compiled, :provider_exchanges)
    }
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

  defp execute(collections, source_id, operation, %{"run_id" => run_id} = arguments, max_bytes)
       when operation in [
              :model_exchanges,
              :capability_calls,
              :generated_sources,
              :effective_preludes,
              :provider_exchanges
            ] do
    with :ok <- validate_keys(arguments, ~w(run_id limit cursor order)),
         true <- valid_string?(run_id),
         :ok <- validate_order(arguments),
         true <- Enum.any?(collections.list_runs, &(&1["run_id"] == run_id)),
         {:ok, page} <- page_options(arguments, source_id, operation) do
      collections
      |> Map.fetch!(operation)
      |> Enum.filter(&(&1["run_id"] == run_id))
      |> order(Map.get(arguments, "order", "asc"))
      |> paginate(page, source_id, max_bytes)
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_collections, _source_id, _operation, _arguments, _max_result_bytes),
    do: {:error, :invalid_query}

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

  defp paginate(items, page, source_id, max_result_bytes) do
    selected = items |> Enum.drop(page.offset) |> Enum.take(page.limit)
    fit_page(selected, items, page.offset, source_id, page.query_id, max_result_bytes)
  end

  defp fit_page(selected, all_items, offset, source_id, query_id, max_result_bytes) do
    result = page_result(selected, all_items, offset, source_id, query_id)

    cond do
      byte_size(Jason.encode!(result)) <= max_result_bytes ->
        {:ok, result}

      selected == [] ->
        {:error, :result_limit_exceeded}

      true ->
        context = {all_items, offset, source_id, query_id, max_result_bytes}

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
         {all_items, offset, source_id, query_id, max_result_bytes} = context,
         lower,
         upper,
         best
       ) do
    count = div(lower + upper, 2)
    result = page_result(Enum.take(selected, count), all_items, offset, source_id, query_id)

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

  defp page_result(selected, all_items, offset, source_id, query_id) do
    next_offset = offset + length(selected)
    more? = next_offset < length(all_items)

    %{
      "items" => selected,
      "next_cursor" => if(more?, do: encode_cursor(next_offset, source_id, query_id), else: nil),
      "truncated" => more?,
      "omitted_count" => max(length(all_items) - next_offset, 0)
    }
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
