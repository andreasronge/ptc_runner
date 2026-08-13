defmodule PtcRunner.Kernel.RunAnalysis do
  @moduledoc """
  Question-shaped reads over one immutable run-evidence capture.

  The read model composes the canonical trace and, when authorized, its
  correlated private inspection snapshot. It does not decode artifacts, read
  paths, or infer causality from timestamps. The snapshot owners remain the
  authorities for validation, correlation, bounds, and source identity.

  Six operations answer the stable user questions: `runs`, `overview`,
  `activity`, `conversation`, `failure`, and `source`. Public captures support
  the first three and the public portion of `failure`; private operations fail
  with `:evidence_unavailable` instead of widening authority.
  """

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.TraceSnapshot

  @operations [:runs, :overview, :activity, :conversation, :failure, :source]
  @private_operations [:conversation, :source]
  @default_limit 100
  @max_limit 1_000
  @trace_page_limit 100
  @max_pages 1_000

  @enforce_keys [:traces, :max_result_bytes]
  defstruct [:traces, :inspection, :max_result_bytes]

  @opaque t :: %__MODULE__{
            traces: TraceSnapshot.t(),
            inspection: InspectionSnapshot.t() | nil,
            max_result_bytes: pos_integer()
          }

  @type operation :: :runs | :overview | :activity | :conversation | :failure | :source

  @doc false
  @spec new(TraceSnapshot.t(), InspectionSnapshot.t() | nil) ::
          {:ok, t()} | {:error, :invalid_run_analysis}
  def new(traces, inspection \\ nil)

  def new(traces, inspection) do
    with true <- TraceSnapshot.valid?(traces),
         true <- is_nil(inspection) or InspectionSnapshot.valid?(inspection),
         {:ok, source} <- TraceSnapshot.source(traces),
         {:ok, trace_info} <- TraceSnapshot.info(traces),
         {:ok, inspection_info} <- inspection_info(inspection),
         true <- valid_pair?(source, trace_info, inspection_info),
         {:ok, trace_limit} <- TraceSnapshot.result_limit(traces),
         {:ok, inspection_limit} <- inspection_limit(inspection) do
      {:ok,
       %__MODULE__{
         traces: traces,
         inspection: inspection,
         max_result_bytes: min(trace_limit, inspection_limit)
       }}
    else
      _ -> {:error, :invalid_run_analysis}
    end
  end

  @spec query(t(), operation(), map()) :: {:ok, map()} | {:error, atom()}
  def query(%__MODULE__{} = analysis, operation, arguments)
      when operation in @operations and is_map(arguments) do
    if operation in @private_operations and is_nil(analysis.inspection) do
      {:error, :evidence_unavailable}
    else
      execute(analysis, operation, arguments)
    end
  end

  def query(_analysis, _operation, _arguments), do: {:error, :invalid_query}

  @doc false
  @spec conversation_streams([map()]) :: map()
  def conversation_streams(exchanges) when is_list(exchanges) do
    exchanges
    |> Enum.sort_by(&Map.get(&1, "input_sequence", 0))
    |> Enum.reduce(initial_stream_state(), &place_exchange/2)
    |> finish_streams()
  end

  def conversation_streams(_exchanges),
    do: %{"streams" => [], "ambiguous" => [], "ambiguous?" => true}

  @doc false
  @spec conversation_result(map(), map(), map()) :: map()
  def conversation_result(trace_page, exchanges_page, programs_page)
      when is_map(trace_page) and is_map(exchanges_page) and is_map(programs_page) do
    streams = conversation_streams(Map.get(exchanges_page, "items", []))
    programs = Map.get(programs_page, "items", [])
    evidence = conversation_evidence(trace_page, exchanges_page)

    streams
    |> attach_programs(programs)
    |> Map.put(
      "complete?",
      evidence.complete? and not streams["ambiguous?"] and page_complete?(programs_page)
    )
    |> Map.put("canonical_complete?", evidence.canonical_complete?)
    |> Map.put("missing_exchange_count", evidence.missing_exchange_count)
    |> Map.put("omitted_count", omitted_count([exchanges_page, programs_page]))
    |> Map.put("snapshot_hash", exchanges_page["snapshot_hash"])
    |> Map.put("trace_snapshot_hash", trace_page["snapshot_hash"])
  end

  defp execute(analysis, :runs, arguments) do
    with :ok <-
           validate_keys(
             arguments,
             ~w(limit cursor status run_id trace_id tags name model provider from to)
           ),
         :ok <- validate_limit(arguments),
         {:ok, page} <- TraceSnapshot.query(analysis.traces, :list_runs, arguments) do
      bounded_result(analysis, complete_page(page))
    end
  end

  defp execute(analysis, :overview, %{"run_id" => run_id} = arguments) do
    with :ok <- validate_keys(arguments, ["run_id"]),
         true <- valid_run_id?(run_id),
         {:ok, run} <- TraceSnapshot.query(analysis.traces, :get_run, arguments),
         {:ok, inspection} <- inspection_run(analysis.inspection, run_id),
         {:ok, result} <- inspection_result(analysis.inspection, run_id) do
      bounded_result(analysis, %{"run" => run, "inspection" => inspection, "result" => result})
    else
      false -> {:error, :invalid_query}
      {:error, _reason} = error -> error
    end
  end

  defp execute(_analysis, :overview, _arguments), do: {:error, :invalid_query}

  defp execute(analysis, :activity, %{"run_id" => _run_id} = arguments) do
    with {:ok, query} <- run_page_query(arguments),
         {:ok, trace} <- collect_trace_pages(analysis, :list_turns, query),
         {:ok, private} <- activity_private(analysis.inspection, query) do
      bounded_result(analysis, %{
        "trace" => complete_page(trace),
        "private" => private,
        "complete?" => page_complete?(trace) and collections_complete?(private)
      })
    end
  end

  defp execute(_analysis, :activity, _arguments), do: {:error, :invalid_query}

  defp execute(%__MODULE__{inspection: inspection} = analysis, :conversation, arguments) do
    with {:ok, query} <- run_page_query(arguments),
         {:ok, _run} <-
           TraceSnapshot.query(analysis.traces, :get_run, %{"run_id" => query["run_id"]}),
         {:ok, trace_page} <- collect_trace_pages(analysis, :list_turns, query),
         {:ok, exchanges_page} <- collect_inspection_pages(inspection, :model_exchanges, query),
         {:ok, programs_page} <- collect_inspection_pages(inspection, :generated_sources, query) do
      bounded_result(
        analysis,
        conversation_result(trace_page, exchanges_page, programs_page)
      )
    else
      {:error, :not_found} -> classify_private_not_found(analysis, arguments)
      {:error, _reason} = error -> error
    end
  end

  defp execute(analysis, :failure, %{"run_id" => run_id} = arguments) do
    with {:ok, query} <- run_page_query(arguments),
         {:ok, run} <- TraceSnapshot.query(analysis.traces, :get_run, %{"run_id" => run_id}),
         {:ok, trace} <- collect_trace_pages(analysis, :list_turns, query),
         {:ok, private} <- failure_private(analysis.inspection, query) do
      diagnostics = private["diagnostics"]
      programs = relate_programs(private["programs"], diagnostics, trace["items"])

      bounded_result(analysis, %{
        "run" => run,
        "diagnostics" => diagnostics,
        "programs" => programs,
        "effective_preludes" => private["effective_preludes"],
        "trace_snapshot_hash" => trace["snapshot_hash"],
        "inspection_snapshot_hash" => private["snapshot_hash"],
        "private_evidence" => private["available?"],
        "complete?" => private["complete?"] and page_complete?(trace)
      })
    end
  end

  defp execute(_analysis, :failure, _arguments), do: {:error, :invalid_query}

  defp execute(%__MODULE__{inspection: inspection} = analysis, :source, arguments) do
    with {:ok, query} <- run_page_query(arguments),
         {:ok, _run} <-
           TraceSnapshot.query(analysis.traces, :get_run, %{"run_id" => query["run_id"]}),
         {:ok, preludes} <- collect_inspection_pages(inspection, :effective_preludes, query),
         {:ok, programs} <- collect_inspection_pages(inspection, :generated_sources, query) do
      bounded_result(analysis, %{
        "effective_preludes" => preludes["items"],
        "generated_programs" => programs["items"],
        "complete?" => page_complete?(preludes) and page_complete?(programs),
        "omitted_count" => omitted_count([preludes, programs]),
        "snapshot_hash" => preludes["snapshot_hash"]
      })
    else
      {:error, :not_found} -> classify_private_not_found(analysis, arguments)
      {:error, _reason} = error -> error
    end
  end

  defp classify_private_not_found(analysis, %{"run_id" => run_id}) do
    case TraceSnapshot.query(analysis.traces, :get_run, %{"run_id" => run_id}) do
      {:ok, _run} -> {:error, :evidence_unavailable}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp classify_private_not_found(_analysis, _arguments), do: {:error, :invalid_query}

  defp valid_pair?(source, _trace_info, nil)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: true

  defp valid_pair?(source, trace_info, inspection_info)
       when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot],
       do: trace_info.capture_id == inspection_info.trace_capture_id

  defp valid_pair?(_source, _trace_info, _inspection_info), do: false

  defp inspection_info(nil), do: {:ok, nil}
  defp inspection_info(inspection), do: InspectionSnapshot.info(inspection)

  defp inspection_limit(nil), do: {:ok, 1_000_000}
  defp inspection_limit(inspection), do: InspectionSnapshot.result_limit(inspection)

  defp inspection_run(nil, _run_id), do: {:ok, %{"available?" => false}}

  defp inspection_run(inspection, run_id) do
    with {:ok, %{"items" => runs}} <-
           collect_inspection_pages(inspection, :list_runs, %{"limit" => @max_limit}) do
      case Enum.find(runs, &(&1["run_id"] == run_id)) do
        nil -> {:ok, %{"available?" => false, "reason" => "evidence_unavailable"}}
        run -> {:ok, run}
      end
    end
  end

  defp inspection_result(nil, _run_id), do: {:ok, %{"available?" => false}}

  defp inspection_result(inspection, run_id) do
    case InspectionSnapshot.query(inspection, :result, %{"run_id" => run_id}) do
      {:ok, result} ->
        {:ok, Map.put(result, "available?", true)}

      {:error, reason} when reason in [:not_found, :result_not_found] ->
        {:ok, %{"available?" => false}}

      {:error, _reason} = error ->
        error
    end
  end

  defp activity_private(nil, _query), do: {:ok, %{"available?" => false}}

  defp activity_private(inspection, query) do
    operations = [
      capability_calls: "capability_calls",
      provider_exchanges: "provider_exchanges",
      execution_prints: "execution_prints",
      execution_errors: "execution_errors"
    ]

    case inspection_pages(inspection, query, operations) do
      {:ok, pages} ->
        result =
          pages
          |> Map.new(fn {name, page} -> {name, page["items"]} end)
          |> Map.put("available?", true)
          |> Map.put("complete?", pages |> Map.values() |> Enum.all?(&page_complete?/1))
          |> Map.put("omitted_count", pages |> Map.values() |> omitted_count())
          |> Map.put("snapshot_hash", page_snapshot_hash(pages))

        {:ok, result}

      {:error, :not_found} ->
        {:ok, %{"available?" => false}}

      {:error, _reason} = error ->
        error
    end
  end

  defp failure_private(nil, _query) do
    {:ok,
     %{
       "available?" => false,
       "complete?" => true,
       "diagnostics" => [],
       "programs" => [],
       "effective_preludes" => []
     }}
  end

  defp failure_private(inspection, query) do
    operations = [
      execution_errors: "diagnostics",
      generated_sources: "programs",
      effective_preludes: "effective_preludes"
    ]

    case inspection_pages(inspection, query, operations) do
      {:ok, pages} ->
        {:ok,
         pages
         |> Map.new(fn {name, page} -> {name, page["items"]} end)
         |> Map.put("available?", true)
         |> Map.put("complete?", pages |> Map.values() |> Enum.all?(&page_complete?/1))
         |> Map.put("snapshot_hash", page_snapshot_hash(pages))}

      {:error, :not_found} ->
        failure_private(nil, query)

      {:error, _reason} = error ->
        error
    end
  end

  defp inspection_pages(inspection, query, operations) do
    Enum.reduce_while(operations, {:ok, %{}}, fn {operation, name}, {:ok, pages} ->
      case collect_inspection_pages(inspection, operation, query) do
        {:ok, page} -> {:cont, {:ok, Map.put(pages, name, page)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp collect_trace_pages(analysis, operation, query) do
    query = Map.update(query, "limit", @trace_page_limit, &min(&1, @trace_page_limit))

    collect_pages(
      &TraceSnapshot.query(analysis.traces, operation, &1),
      query,
      analysis.max_result_bytes
    )
  end

  defp collect_inspection_pages(inspection, operation, query) do
    with {:ok, max_result_bytes} <- InspectionSnapshot.result_limit(inspection) do
      collect_pages(
        &InspectionSnapshot.query(inspection, operation, &1),
        query,
        max_result_bytes
      )
    end
  end

  defp collect_pages(query, arguments, max_result_bytes),
    do: collect_pages(query, arguments, max_result_bytes, nil, [], nil, 0)

  defp collect_pages(_query, _arguments, _max_result_bytes, _cursor, _items, _hash, @max_pages),
    do: {:error, :result_limit_exceeded}

  defp collect_pages(query, arguments, max_result_bytes, cursor, items, hash, pages) do
    page_arguments = if cursor, do: Map.put(arguments, "cursor", cursor), else: arguments

    with {:ok, page} <- query.(page_arguments),
         next_items = items ++ page["items"],
         next_hash = hash || page["snapshot_hash"],
         result = collected_page(next_items, next_hash),
         true <- byte_size(Jason.encode!(result)) <= max_result_bytes do
      case page["next_cursor"] do
        nil ->
          {:ok, result}

        next ->
          collect_pages(
            query,
            arguments,
            max_result_bytes,
            next,
            next_items,
            next_hash,
            pages + 1
          )
      end
    else
      false -> {:error, :result_limit_exceeded}
      {:error, _reason} = error -> error
    end
  end

  defp collected_page(items, snapshot_hash) do
    %{
      "items" => items,
      "next_cursor" => nil,
      "truncated" => false,
      "omitted_count" => 0,
      "snapshot_hash" => snapshot_hash
    }
  end

  defp run_page_query(%{"run_id" => run_id} = arguments) do
    with :ok <- validate_keys(arguments, ~w(run_id limit)),
         true <- valid_run_id?(run_id),
         limit <- Map.get(arguments, "limit", @default_limit),
         true <- is_integer(limit) and limit in 1..@max_limit do
      {:ok, %{"run_id" => run_id, "limit" => limit}}
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp run_page_query(_arguments), do: {:error, :invalid_query}

  defp validate_keys(arguments, allowed) do
    if Map.keys(arguments) -- allowed == [], do: :ok, else: {:error, :invalid_query}
  end

  defp valid_run_id?(run_id),
    do: is_binary(run_id) and byte_size(run_id) in 1..4_096 and String.valid?(run_id)

  defp validate_limit(%{"limit" => limit}) when limit in 1..@max_limit, do: :ok
  defp validate_limit(arguments) when not is_map_key(arguments, "limit"), do: :ok
  defp validate_limit(_arguments), do: {:error, :invalid_query}

  defp complete_page(page), do: Map.put(page, "complete?", page_complete?(page))
  defp page_complete?(page), do: page["next_cursor"] == nil

  defp collections_complete?(%{"available?" => false}), do: true
  defp collections_complete?(private), do: Map.get(private, "complete?", false)

  defp omitted_count(pages),
    do: Enum.sum(Enum.map(pages, &Map.get(&1, "omitted_count", 0)))

  defp page_snapshot_hash(pages) do
    pages
    |> Map.values()
    |> List.first(%{})
    |> Map.get("snapshot_hash")
  end

  defp bounded_result(%__MODULE__{max_result_bytes: max_result_bytes}, result) do
    if byte_size(Jason.encode!(result)) <= max_result_bytes,
      do: {:ok, result},
      else: {:error, :result_limit_exceeded}
  end

  defp conversation_evidence(trace_page, exchanges_page) do
    events = Map.get(trace_page, "items", [])

    expected =
      events
      |> Enum.filter(fn event ->
        event["type"] == "capability-started" and event_data(event, "name") == "llm-request"
      end)
      |> MapSet.new(&event_data(&1, "capability_id"))

    captured =
      exchanges_page
      |> Map.get("items", [])
      |> MapSet.new(& &1["capability_id"])

    missing_exchange_count = expected |> MapSet.difference(captured) |> MapSet.size()
    terminal? = Enum.any?(events, &(&1["type"] == "run-stopped"))
    dropped? = Enum.any?(events, &(&1["type"] == "events-dropped"))
    canonical_complete? = page_complete?(trace_page) and terminal? and not dropped?

    %{
      canonical_complete?: canonical_complete?,
      missing_exchange_count: missing_exchange_count,
      complete?:
        canonical_complete? and missing_exchange_count == 0 and
          page_complete?(exchanges_page)
    }
  end

  defp attach_programs(%{"streams" => streams} = result, programs) do
    streams =
      Enum.map(streams, fn stream ->
        Map.update!(stream, "turns", fn turns ->
          Enum.map(turns, fn turn ->
            sources = generated_sources(turn["assistant"])
            Map.put(turn, "generated", Enum.filter(programs, &(&1["source"] in sources)))
          end)
        end)
      end)

    Map.put(result, "streams", streams)
  end

  defp generated_sources(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.flat_map(calls, fn call ->
      case get_in(call, ["args", "program"]) do
        source when is_binary(source) -> [source]
        _ -> []
      end
    end)
  end

  defp generated_sources(_assistant), do: []

  defp relate_programs(programs, diagnostics, trace) do
    Enum.map(programs, fn program ->
      workflow_evaluation_id = enclosing_workflow_evaluation(program["evaluation_id"], trace)

      relationship =
        cond do
          Enum.any?(diagnostics, &(&1["evaluation_id"] == program["evaluation_id"])) ->
            "direct"

          is_binary(workflow_evaluation_id) and
              Enum.any?(diagnostics, &(&1["evaluation_id"] == workflow_evaluation_id)) ->
            "same_workflow_evaluation"

          Enum.any?(diagnostics, &preceding?(program, &1)) ->
            "preceding"

          true ->
            "unknown"
        end

      program
      |> Map.put("relationship", relationship)
      |> maybe_put("workflow_evaluation_id", workflow_evaluation_id)
    end)
  end

  defp enclosing_workflow_evaluation(evaluation_id, trace) do
    with %{"sequence" => mission_started} <-
           Enum.find(trace, &event?(&1, "evaluation-started", evaluation_id, "mission")),
         workflow when not is_nil(workflow) <-
           trace
           |> Enum.filter(fn event ->
             event?(event, "evaluation-started", nil, "workflow") and
               event["sequence"] < mission_started and
               after_sequence?(trace, event_id(event), "evaluation-stopped", mission_started)
           end)
           |> Enum.max_by(& &1["sequence"], fn -> nil end) do
      event_id(workflow)
    else
      _ -> nil
    end
  end

  defp event?(event, type, evaluation_id, environment) do
    event["type"] == type and event_data(event, "environment") == environment and
      (is_nil(evaluation_id) or event_id(event) == evaluation_id)
  end

  defp after_sequence?(trace, evaluation_id, type, sequence) do
    case Enum.find(trace, &event?(&1, type, evaluation_id, "workflow")) do
      %{"sequence" => stopped} -> stopped > sequence
      nil -> true
    end
  end

  defp event_id(event), do: event_data(event, "evaluation_id")
  defp event_data(event, key), do: get_in(event, ["data", key])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp preceding?(%{"sequence" => left}, %{"sequence" => right}), do: left < right
  defp preceding?(_program, _diagnostic), do: false

  defp initial_stream_state do
    %{nodes: [], streams: %{}, stream_order: [], ambiguous: [], next_stream: 1}
  end

  defp place_exchange(exchange, state) do
    messages = get_in(exchange, ["arguments", "messages"])

    if is_list(messages) do
      candidates = Enum.filter(state.nodes, &prefix?(&1.complete_messages, messages))
      place_with_candidates(exchange, messages, candidates, state)
    else
      add_ambiguous(exchange, "messages_unavailable", state)
    end
  end

  defp place_with_candidates(exchange, messages, [], state),
    do: add_turn(exchange, messages, nil, state)

  defp place_with_candidates(exchange, messages, candidates, state) do
    max_size = candidates |> Enum.map(&length(&1.complete_messages)) |> Enum.max()
    longest = Enum.filter(candidates, &(length(&1.complete_messages) == max_size))

    case longest do
      [predecessor] -> add_turn(exchange, messages, predecessor, state)
      _ -> add_ambiguous(exchange, "multiple_maximal_predecessors", state)
    end
  end

  defp add_turn(exchange, messages, predecessor, state) do
    {stream_id, turn, added, state} = stream_position(messages, predecessor, state)
    assistant = assistant_message(exchange["result"])

    item = %{
      "turn" => turn,
      "capability_id" => exchange["capability_id"],
      "request_sequence" => exchange["input_sequence"],
      "response_sequence" => exchange["output_sequence"],
      "system" => get_in(exchange, ["arguments", "system"]),
      "messages_added" => added,
      "feedback" => Enum.filter(added, &(&1["role"] == "tool")),
      "response" => exchange["result"],
      "assistant" => assistant,
      "tokens" => get_in(exchange, ["result", "value", "tokens"]),
      "outcome" => exchange["result"]["status"]
    }

    node = %{
      complete_messages: messages ++ [assistant],
      stream_id: stream_id,
      turn: turn,
      capability_id: exchange["capability_id"]
    }

    state
    |> Map.update!(:nodes, &(&1 ++ [node]))
    |> update_in([:streams, stream_id], &((&1 || []) ++ [item]))
  end

  defp stream_position(messages, nil, state) do
    stream_id = "stream-#{state.next_stream}"

    state = %{
      state
      | next_stream: state.next_stream + 1,
        stream_order: state.stream_order ++ [stream_id]
    }

    {stream_id, 1, messages, state}
  end

  defp stream_position(messages, predecessor, state) do
    added = Enum.drop(messages, length(predecessor.complete_messages))
    {predecessor.stream_id, predecessor.turn + 1, added, state}
  end

  defp assistant_message(%{"value" => value}) when is_map(value) do
    value
    |> Map.take(["content", "tool_calls"])
    |> Map.put("role", "assistant")
    |> ensure_assistant_content(value)
  end

  defp assistant_message(result), do: %{"role" => "assistant", "content" => result}

  defp ensure_assistant_content(%{"role" => "assistant"} = message, value)
       when map_size(message) == 1,
       do: Map.put(message, "content", value)

  defp ensure_assistant_content(message, _value), do: message

  defp prefix?(prefix, messages) when length(prefix) < length(messages),
    do: Enum.take(messages, length(prefix)) == prefix

  defp prefix?(_prefix, _messages), do: false

  defp add_ambiguous(exchange, reason, state) do
    entry = %{
      "capability_id" => exchange["capability_id"],
      "request_sequence" => exchange["input_sequence"],
      "reason" => reason
    }

    Map.update!(state, :ambiguous, &(&1 ++ [entry]))
  end

  defp finish_streams(state) do
    streams =
      Enum.map(state.stream_order, fn stream_id ->
        %{"stream_id" => stream_id, "turns" => Map.fetch!(state.streams, stream_id)}
      end)

    %{
      "streams" => streams,
      "ambiguous" => state.ambiguous,
      "ambiguous?" => state.ambiguous != []
    }
  end
end
