defmodule PtcRunner.Kernel.InspectionQuery do
  @moduledoc """
  ETS-selected queries that verify dependency frames before returning a page.

  Cursors bind the admission snapshot digest and the logical query identity.
  They do not rehash the complete evidence preimage. ETS supplies ordering,
  membership, cursor position, and exact `omitted_count`; only returned items
  and their join or turn dependencies are reread and verified.
  """

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.InspectionArtifact.Conversation
  alias PtcRunner.Kernel.InspectionArtifact.Handle
  alias PtcRunner.Kernel.InspectionArtifact.Indexes
  alias PtcRunner.Kernel.InspectionArtifact.Items
  alias PtcRunner.Kernel.InspectionArtifact.ValueHash
  alias PtcRunner.Kernel.QueryCursor
  alias PtcRunner.Kernel.ResultLimit

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
    :explicit_failure_values,
    :result
  ]

  @type metrics :: %{
          postings_visited: non_neg_integer(),
          candidate_frames_verified: non_neg_integer(),
          hash_operations: non_neg_integer(),
          ranges: non_neg_integer(),
          bytes_read: non_neg_integer(),
          exact_count_work: non_neg_integer()
        }

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
          | :explicit_failure_values
          | :result

  @spec operations() :: [atom()]
  def operations, do: @operations

  @spec empty_metrics() :: metrics()
  def empty_metrics do
    %{
      postings_visited: 0,
      candidate_frames_verified: 0,
      hash_operations: 0,
      ranges: 0,
      bytes_read: 0,
      exact_count_work: 0
    }
  end

  @spec run(map(), atom(), map(), pos_integer(), map()) ::
          {:ok, map(), metrics()} | {:error, atom()}
  def run(snapshot, operation, arguments, max_result_bytes, metadata \\ %{})

  def run(snapshot, operation, arguments, max_result_bytes, metadata)
      when is_map(snapshot) and operation in @operations and is_map(arguments) and
             is_integer(max_result_bytes) and max_result_bytes > 0 and is_map(metadata) do
    maybe_query_hook(snapshot)
    execute(snapshot, operation, arguments, max_result_bytes, metadata, empty_metrics())
  end

  def run(_snapshot, _operation, _arguments, _max_result_bytes, _metadata),
    do: {:error, :invalid_query}

  defp execute(snapshot, :list_runs, arguments, max_bytes, metadata, metrics) do
    with :ok <- validate_keys(arguments, ~w(limit cursor)),
         {:ok, page} <- page_options(arguments, snapshot.snapshot_digest, :list_runs),
         :ok <- verify_handles(snapshot, :catalog, metrics) do
      runs =
        snapshot.indexes
        |> Indexes.tab2list(:runs)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      paginate(runs, :catalog, page, snapshot, max_bytes, metadata, metrics)
    end
  end

  defp execute(
         snapshot,
         :get_run,
         %{"run_id" => run_id} = arguments,
         max_bytes,
         metadata,
         metrics
       ) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         true <- valid_string?(run_id),
         :ok <- verify_handles(snapshot, {:get_run, run_id}, metrics),
         {:ok, run} <- fetch_run(snapshot, run_id),
         result <- Map.merge(run, metadata),
         :ok <- ResultLimit.validate(result, max_bytes) do
      {:ok, result, metrics}
    else
      false -> {:error, :invalid_query}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_snapshot, :get_run, _arguments, _max_bytes, _metadata, _metrics),
    do: {:error, :invalid_query}

  defp execute(snapshot, :result, %{"run_id" => run_id} = arguments, max_bytes, metadata, metrics) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         :ok <- validate_result_run_id(run_id, snapshot),
         :ok <- verify_handles(snapshot, {:result, run_id}, metrics),
         {:ok, item, metrics} <- fetch_result(snapshot, run_id, metrics),
         result <- Map.merge(item, metadata),
         :ok <- ResultLimit.validate(result, max_bytes) do
      {:ok, result, metrics}
    end
  end

  defp execute(_snapshot, :result, _arguments, _max_bytes, _metadata, _metrics),
    do: {:error, :invalid_query}

  defp execute(snapshot, :turns, %{"run_id" => run_id} = arguments, max_bytes, metadata, metrics) do
    allowed =
      ~w(run_id limit cursor stream_id capability_id evaluation_id parent_evaluation_id prelude_call prelude_component)

    with :ok <- validate_keys(arguments, allowed),
         true <- valid_string?(run_id),
         :ok <- validate_filter_values(arguments, allowed -- ~w(run_id limit cursor)),
         :ok <- run_present(snapshot, run_id),
         {:ok, page} <- page_options(arguments, snapshot.snapshot_digest, :turns),
         {:ok, locators, metrics} <- select(snapshot, run_id, :turns, arguments, "asc", metrics),
         {:ok, locators, metrics} <- filter_turns(snapshot, run_id, locators, arguments, metrics) do
      metadata =
        Map.merge(metadata, %{
          "evidence" => turn_evidence(snapshot, run_id),
          "trace_snapshot_hash" => snapshot.trace_snapshot_hash
        })

      paginate(locators, {:turns, run_id}, page, snapshot, max_bytes, metadata, metrics)
      |> compact_turn_page()
    else
      false -> {:error, :invalid_query}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_snapshot, :turns, _arguments, _max_bytes, _metadata, _metrics),
    do: {:error, :invalid_query}

  defp execute(
         snapshot,
         operation,
         %{"run_id" => run_id} = arguments,
         max_bytes,
         metadata,
         metrics
       )
       when operation in [
              :model_exchanges,
              :capability_calls,
              :generated_sources,
              :effective_preludes,
              :provider_exchanges,
              :execution_prints,
              :execution_errors,
              :explicit_failure_values
            ] do
    allowed = ~w(run_id limit cursor order) ++ collection_filters(operation)

    with :ok <- validate_keys(arguments, allowed),
         true <- valid_string?(run_id),
         :ok <- validate_order(arguments),
         :ok <- validate_filter_values(arguments, collection_filters(operation)),
         :ok <- run_present(snapshot, run_id),
         {:ok, page} <- page_options(arguments, snapshot.snapshot_digest, operation),
         {:ok, locators, metrics} <-
           select(
             snapshot,
             run_id,
             operation,
             arguments,
             Map.get(arguments, "order", "asc"),
             metrics
           ) do
      paginate(locators, {operation, run_id}, page, snapshot, max_bytes, metadata, metrics)
    else
      false -> {:error, :invalid_query}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_snapshot, _operation, _arguments, _max_bytes, _metadata, _metrics),
    do: {:error, :invalid_query}

  defp select(snapshot, run_id, collection, arguments, order, metrics) do
    ordered =
      snapshot.indexes
      |> Indexes.match(:collection_order, {{run_id, collection, :_}, :_})
      |> Enum.sort_by(fn {{_run, _collection, ordinal}, _locator} -> ordinal end)

    filters =
      arguments
      |> Map.take(collection_filters(collection) ++ turn_filters())
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    {ordinals, metrics} =
      Enum.reduce(filters, {MapSet.new(Enum.map(ordered, &ordinal/1)), metrics}, fn {filter,
                                                                                     value},
                                                                                    {set, metrics} ->
        postings =
          Indexes.match(
            snapshot.indexes,
            :filter_posting,
            {{run_id, collection, filter, ValueHash.hash(value), :_}, :_}
          )

        posting_ordinals = MapSet.new(Enum.map(postings, &posting_ordinal/1))
        metrics = bump(metrics, :postings_visited, length(postings))
        {MapSet.intersection(set, posting_ordinals), metrics}
      end)

    locators =
      ordered
      |> Enum.filter(fn row -> MapSet.member?(ordinals, ordinal(row)) end)
      |> Enum.map(&elem(&1, 1))
      |> order(order)

    {:ok, locators, metrics}
  end

  defp filter_turns(snapshot, run_id, locators, arguments, metrics) do
    filters =
      Map.take(arguments, ~w(evaluation_id parent_evaluation_id prelude_call prelude_component))

    if Enum.all?(filters, fn {_key, value} -> is_nil(value) end) do
      {:ok, locators, metrics}
    else
      kept =
        Enum.filter(locators, fn {:turn, ordinal} ->
          case Indexes.lookup(snapshot.indexes, :turn_projection, {run_id, ordinal}) do
            [{_key, turn}] -> generated_source_match?(turn, arguments, snapshot, run_id)
            _other -> false
          end
        end)

      {:ok, kept, metrics}
    end
  end

  defp generated_source_match?(turn, arguments, _snapshot, _run_id) do
    Enum.any?(turn.generated, fn generated ->
      equal_filter?(generated.evaluation_id, arguments["evaluation_id"]) and
        equal_filter?(generated.parent_evaluation_id, arguments["parent_evaluation_id"]) and
        call_match?(generated, arguments["prelude_call"], "ref") and
        call_match?(generated, arguments["prelude_component"], "component_id")
    end)
  end

  defp paginate(items, kind, page, snapshot, max_bytes, metadata, metrics) do
    with :ok <- verify_handles(snapshot, kind, metrics) do
      candidates = items |> Enum.drop(page.offset) |> Enum.take(page.limit)
      metrics = bump(metrics, :exact_count_work, max(length(items) - page.offset, 0))

      context = %{
        all_items: items,
        page: page,
        snapshot: snapshot,
        max_bytes: max_bytes,
        metadata: metadata
      }

      assemble_page(candidates, kind, context, [], metrics)
    end
  end

  defp assemble_page([], _kind, context, assembled, metrics) do
    result = page_result(assembled, context)

    if ResultLimit.within?(result, context.max_bytes),
      do: {:ok, result, metrics},
      else: {:error, :result_limit_exceeded}
  end

  defp assemble_page([candidate | rest], kind, context, assembled, metrics) do
    with {:ok, metrics} <- verify_dependency(context.snapshot, kind, candidate, metrics),
         {:ok, item, metrics} <- assemble_one(context.snapshot, kind, candidate, metrics) do
      proposed = assembled ++ [item]
      result = page_result(proposed, context)

      cond do
        ResultLimit.within?(result, context.max_bytes) ->
          assemble_page(rest, kind, context, proposed, metrics)

        assembled == [] ->
          {:error, :result_limit_exceeded}

        true ->
          {:ok, page_result(assembled, context), metrics}
      end
    end
  end

  defp verify_handles(snapshot, :catalog, _metrics) do
    snapshot.handles
    |> Map.values()
    |> Enum.reduce_while(:ok, fn handle, :ok ->
      case Handle.assert_stable(handle) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_handles(snapshot, {_operation, run_id}, _metrics) do
    case Map.fetch(snapshot.handles, run_id) do
      {:ok, handle} -> Handle.assert_stable(handle)
      :error -> {:error, :not_found}
    end
  end

  defp verify_dependency(_snapshot, :catalog, _item, metrics), do: {:ok, metrics}

  defp verify_dependency(snapshot, kind, locator, metrics),
    do: verify_locator(snapshot, kind, locator, metrics)

  defp verify_locator(snapshot, {operation, run_id}, locator, metrics) do
    sequences = locator_sequences(snapshot, operation, run_id, locator)

    Enum.reduce_while(sequences, {:ok, metrics}, fn sequence, {:ok, acc} ->
      case Items.read_record(
             Map.fetch!(snapshot.handles, run_id),
             snapshot.indexes,
             run_id,
             sequence,
             range_ceiling(snapshot)
           ) do
        {:ok, _record, bytes_read} ->
          acc =
            acc
            |> bump(:candidate_frames_verified, 1)
            |> bump(:hash_operations, 1)
            |> bump(:ranges, 1)
            |> bump(:bytes_read, bytes_read)

          {:cont, {:ok, acc}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp assemble_one(_snapshot, :catalog, item, metrics), do: {:ok, item, metrics}

  defp assemble_one(snapshot, {:turns, run_id}, {:turn, ordinal}, metrics) do
    case Indexes.lookup(snapshot.indexes, :turn_projection, {run_id, ordinal}) do
      [{_key, turn}] ->
        handle = Map.fetch!(snapshot.handles, run_id)

        with {:ok, input, metrics} <- read(handle, snapshot, run_id, turn.input_sequence, metrics),
             {:ok, output, metrics} <-
               read(handle, snapshot, run_id, turn.output_sequence, metrics),
             {:ok, generated, metrics} <-
               assemble_generated(snapshot, run_id, turn.generated, metrics) do
          item =
            turn
            |> Conversation.assemble_turn(input, output, generated)
            |> Map.put("run_id", run_id)

          {:ok, item, metrics}
        end

      _other ->
        {:error, :source_changed}
    end
  end

  defp assemble_one(snapshot, {operation, run_id}, locator, metrics)
       when operation in [:model_exchanges, :capability_calls] do
    {:capability, id, _sequence} = locator
    [{_key, join}] = Indexes.lookup(snapshot.indexes, :capability_join, {run_id, id})
    handle = Map.fetch!(snapshot.handles, run_id)

    with {:ok, input, metrics} <- read(handle, snapshot, run_id, join.input_sequence, metrics),
         {:ok, output, metrics} <-
           maybe_read(handle, snapshot, run_id, join.output_sequence, metrics),
         {:ok, exception, metrics} <-
           maybe_read(handle, snapshot, run_id, join.exception_sequence, metrics) do
      {:ok, Items.capability_item(input, output, exception), metrics}
    end
  end

  defp assemble_one(snapshot, {:provider_exchanges, run_id}, locator, metrics) do
    {:provider, capability_id, request_id, _sequence} = locator

    [{_key, join}] =
      Indexes.lookup(snapshot.indexes, :provider_join, {run_id, capability_id, request_id})

    handle = Map.fetch!(snapshot.handles, run_id)

    with {:ok, request, metrics} <- read(handle, snapshot, run_id, join.request_sequence, metrics),
         {:ok, response, metrics} <-
           read(handle, snapshot, run_id, join.response_sequence, metrics),
         {:ok, stderr, metrics} <-
           maybe_read(handle, snapshot, run_id, join.stderr_sequence, metrics) do
      {:ok, Items.provider_item(request, response, stderr), metrics}
    end
  end

  defp assemble_one(snapshot, {:generated_sources, run_id}, {:record, sequence}, metrics) do
    handle = Map.fetch!(snapshot.handles, run_id)

    with {:ok, record, metrics} <- read(handle, snapshot, run_id, sequence, metrics),
         evaluation_id = record["correlation"]["evaluation_id"],
         {:ok, calls, metrics} <- analysis_calls(snapshot, run_id, evaluation_id, metrics) do
      parent =
        get_in(snapshot.indexes.trace_facts, [run_id, "parent_evaluation_ids", evaluation_id])

      relationships = relationships(snapshot, run_id, :generated_sources, sequence)
      {:ok, Items.source_item(record, calls, parent, relationships), metrics}
    end
  end

  defp assemble_one(snapshot, {:effective_preludes, run_id}, {:record, sequence}, metrics) do
    handle = Map.fetch!(snapshot.handles, run_id)

    with {:ok, record, metrics} <- read(handle, snapshot, run_id, sequence, metrics) do
      relationships = relationships(snapshot, run_id, :effective_preludes, sequence)
      {:ok, Items.prelude_item(record, relationships), metrics}
    end
  end

  defp assemble_one(snapshot, {operation, run_id}, {:record, sequence}, metrics)
       when operation in [:execution_prints, :execution_errors, :explicit_failure_values] do
    handle = Map.fetch!(snapshot.handles, run_id)

    with {:ok, record, metrics} <- read(handle, snapshot, run_id, sequence, metrics) do
      relationships =
        if operation == :execution_errors,
          do: relationships(snapshot, run_id, :execution_errors, sequence),
          else: nil

      {:ok, Items.execution_item(record, relationships), metrics}
    end
  end

  defp assemble_generated(snapshot, run_id, generated, metrics) do
    Enum.reduce_while(generated, {:ok, [], metrics}, fn entry, {:ok, items, acc} ->
      locator = {:record, entry.sequence}

      case assemble_one(snapshot, {:generated_sources, run_id}, locator, acc) do
        {:ok, item, acc} ->
          item =
            item
            |> Map.put("association", entry.association)
            |> Map.put("association_ambiguous?", entry.association_ambiguous?)

          {:cont, {:ok, items ++ [item], acc}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, items, metrics} -> {:ok, items, metrics}
      error -> error
    end
  end

  defp page_result(selected, context) do
    next_offset = context.page.offset + length(selected)
    more? = next_offset < length(context.all_items)

    Map.merge(context.metadata, %{
      "items" => selected,
      "next_cursor" =>
        if(more?,
          do:
            QueryCursor.encode(
              next_offset,
              context.snapshot.snapshot_digest,
              context.page.query_id
            ),
          else: nil
        ),
      "truncated" => more?,
      "omitted_count" => max(length(context.all_items) - next_offset, 0)
    })
  end

  defp compact_turn_page({:ok, %{"items" => items} = page, metrics}) do
    {:ok, Map.put(page, "items", ConversationProjection.compact_turns(items)), metrics}
  end

  defp compact_turn_page(result), do: result

  defp read(handle, snapshot, run_id, sequence, metrics) do
    case Items.read_record(
           handle,
           snapshot.indexes,
           run_id,
           sequence,
           range_ceiling(snapshot)
         ) do
      {:ok, record, bytes_read} ->
        metrics =
          metrics
          |> bump(:ranges, 1)
          |> bump(:hash_operations, 1)
          |> bump(:bytes_read, bytes_read)

        {:ok, record, metrics}

      error ->
        error
    end
  end

  defp maybe_read(_handle, _snapshot, _run_id, nil, metrics), do: {:ok, nil, metrics}

  defp maybe_read(handle, snapshot, run_id, sequence, metrics),
    do: read(handle, snapshot, run_id, sequence, metrics)

  defp fetch_run(snapshot, run_id) do
    case Indexes.lookup(snapshot.indexes, :runs, run_id) do
      [{^run_id, run}] -> {:ok, run}
      _other -> :error
    end
  end

  defp fetch_result(snapshot, run_id, metrics) do
    case Indexes.lookup(snapshot.indexes, :results, run_id) do
      [{^run_id, sequence}] ->
        handle = Map.fetch!(snapshot.handles, run_id)

        with {:ok, record, metrics} <- read(handle, snapshot, run_id, sequence, metrics) do
          {:ok, Items.result_item(record), metrics}
        end

      _other ->
        {:error, :result_not_found}
    end
  end

  defp validate_result_run_id(run_id, snapshot) do
    cond do
      not valid_string?(run_id) -> {:error, :invalid_query}
      match?({:ok, _}, fetch_run(snapshot, run_id)) -> :ok
      true -> {:error, :not_found}
    end
  end

  defp run_present(snapshot, run_id) do
    case fetch_run(snapshot, run_id) do
      {:ok, _run} -> :ok
      :error -> {:error, :not_found}
    end
  end

  defp locator_sequences(snapshot, :turns, run_id, {:turn, ordinal}) do
    case Indexes.lookup(snapshot.indexes, :turn_projection, {run_id, ordinal}) do
      [{_key, turn}] ->
        generated = Enum.map(turn.generated, & &1.sequence)

        analysis =
          Enum.flat_map(generated, fn sequence ->
            analysis_sequences(snapshot, run_id, sequence)
          end)

        [turn.input_sequence, turn.output_sequence | generated ++ analysis]

      _other ->
        []
    end
  end

  defp locator_sequences(snapshot, operation, run_id, {:capability, id, _sequence})
       when operation in [:model_exchanges, :capability_calls] do
    case Indexes.lookup(snapshot.indexes, :capability_join, {run_id, id}) do
      [{_key, join}] ->
        [join.input_sequence, join.output_sequence, join.exception_sequence]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp locator_sequences(
         snapshot,
         :provider_exchanges,
         run_id,
         {:provider, capability_id, request_id, _}
       ) do
    case Indexes.lookup(snapshot.indexes, :provider_join, {run_id, capability_id, request_id}) do
      [{_key, join}] ->
        [join.request_sequence, join.response_sequence, join.stderr_sequence]
        |> Enum.reject(&is_nil/1)

      _other ->
        []
    end
  end

  defp locator_sequences(snapshot, :generated_sources, run_id, {:record, sequence}) do
    [sequence | analysis_sequences(snapshot, run_id, sequence)]
  end

  defp locator_sequences(_snapshot, _operation, _run_id, {:record, sequence}), do: [sequence]
  defp locator_sequences(_snapshot, _operation, _run_id, _locator), do: []

  defp analysis_sequences(snapshot, run_id, sequence) do
    case Indexes.match(snapshot.indexes, :evaluation_join, {{run_id, :_, :source}, sequence}) do
      [{{^run_id, evaluation_id, :source}, ^sequence}] ->
        case Indexes.lookup(
               snapshot.indexes,
               :evaluation_join,
               {run_id, evaluation_id, :analysis}
             ) do
          [{_key, analysis_seq}] -> [analysis_seq]
          _other -> []
        end

      _other ->
        []
    end
  end

  defp analysis_calls(snapshot, run_id, evaluation_id, metrics) do
    case Indexes.lookup(snapshot.indexes, :evaluation_join, {run_id, evaluation_id, :analysis}) do
      [{_key, sequence}] ->
        handle = Map.fetch!(snapshot.handles, run_id)

        with {:ok, record, metrics} <- read(handle, snapshot, run_id, sequence, metrics) do
          {:ok, record["payload"]["prelude_calls"], metrics}
        end

      _other ->
        {:ok, nil, metrics}
    end
  end

  defp relationships(snapshot, run_id, collection, key) do
    case Indexes.lookup(snapshot.indexes, :relationships, {run_id, collection, key}) do
      [{_key, relations}] -> relations
      _other -> []
    end
  end

  defp turn_evidence(snapshot, run_id) do
    get_in(snapshot.indexes.turn_evidence, [run_id]) ||
      %{
        "complete?" => false,
        "canonical_complete?" => false,
        "missing_exchange_count" => 0,
        "ambiguity_count" => 0
      }
  end

  defp page_options(arguments, source_id, operation) do
    QueryCursor.page_options(
      arguments,
      source_id,
      {operation, Map.drop(arguments, ["cursor"])},
      @default_limit,
      @max_limit,
      @max_cursor_bytes
    )
  end

  # ex_dna:disable-for-next-line — closed query validation stays beside its production caller
  defp validate_keys(arguments, allowed) do
    if Map.keys(arguments) -- allowed == [], do: :ok, else: {:error, :invalid_query}
  end

  # ex_dna:disable-for-next-line — closed query validation stays beside its production caller
  defp valid_string?(value),
    do: is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value)

  # ex_dna:disable-for-next-line — closed query validation stays beside its production caller
  defp validate_order(%{"order" => order}) when order in ["asc", "desc"], do: :ok
  defp validate_order(arguments) when not is_map_key(arguments, "order"), do: :ok
  defp validate_order(_arguments), do: {:error, :invalid_query}

  defp collection_filters(:model_exchanges), do: ~w(capability_id input_sequence)
  defp collection_filters(:capability_calls), do: ~w(capability_id mission_name name)
  defp collection_filters(:provider_exchanges), do: ~w(capability_id mission_name request_id)

  defp collection_filters(:generated_sources),
    do: ~w(evaluation_id parent_evaluation_id mission_name prelude_call prelude_component)

  defp collection_filters(:effective_preludes), do: ~w(component_id environment mission_name)

  defp collection_filters(operation)
       when operation in [:execution_prints, :execution_errors, :explicit_failure_values, :turns],
       do: ["evaluation_id"]

  defp collection_filters(_operation), do: []

  defp turn_filters, do: ~w(stream_id capability_id)

  # ex_dna:disable-for-next-line — closed query validation stays beside its production caller
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

  defp order(items, "asc"), do: items
  defp order(items, "desc"), do: Enum.reverse(items)

  defp ordinal({{_run, _collection, ordinal}, _locator}), do: ordinal
  defp posting_ordinal({{_run, _collection, _filter, _hash, ordinal}, _locator}), do: ordinal

  defp equal_filter?(_actual, nil), do: true
  defp equal_filter?(actual, expected), do: actual == expected

  defp call_match?(_item, nil, _key), do: true

  defp call_match?(item, expected, key) do
    item
    |> prelude_calls()
    |> Enum.any?(&(&1[key] == expected))
  end

  defp prelude_calls(%{prelude_calls: calls}) when is_list(calls), do: calls
  defp prelude_calls(item) when is_map(item), do: Map.get(item, "prelude_calls", [])
  defp prelude_calls(_item), do: []

  defp bump(metrics, key, amount), do: Map.update!(metrics, key, &(&1 + amount))

  defp range_ceiling(snapshot) do
    case snapshot do
      %{limits: %{max_range_bytes: bytes}} when is_integer(bytes) and bytes > 0 -> bytes
      _other -> 64 * 1024 * 1024
    end
  end

  defp maybe_query_hook(%{query_hook: hook}) when is_function(hook, 1), do: hook.(:before_query)
  defp maybe_query_hook(_snapshot), do: :ok
end
