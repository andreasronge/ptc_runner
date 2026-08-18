defmodule PtcRunner.Kernel.ConversationProjection do
  @moduledoc false

  alias PtcRunner.Lisp.Runtime.String, as: RuntimeString

  @spec compile([map()], [map()], map()) :: map()
  def compile(exchanges, programs, trace_facts)
      when is_list(exchanges) and is_list(programs) and is_map(trace_facts) do
    reconstructed = conversation_streams(exchanges)
    program_counts = Enum.frequencies_by(programs, & &1["source"])

    items =
      Enum.flat_map(reconstructed.streams, fn stream ->
        Enum.map(stream["turns"], fn turn ->
          generated =
            turn["assistant"]
            |> generated_sources()
            |> then(fn sources -> Enum.filter(programs, &(&1["source"] in sources)) end)
            |> Enum.map(fn program ->
              program
              |> Map.put("association", "source_match")
              |> Map.put(
                "association_ambiguous?",
                Map.get(program_counts, program["source"], 0) > 1
              )
            end)

          turn
          |> Map.put("stream_id", stream["stream_id"])
          |> Map.put("generated", generated)
        end)
      end)

    expected = MapSet.new(Map.get(trace_facts, "expected_model_exchange_ids", []))
    captured = MapSet.new(exchanges, & &1["capability_id"])
    missing_exchange_count = expected |> MapSet.difference(captured) |> MapSet.size()

    canonical_complete? =
      Map.get(trace_facts, "terminal?", false) and
        not Map.get(trace_facts, "events_dropped?", false)

    source_ambiguity_count =
      Enum.count(items, fn item ->
        Enum.any?(item["generated"], & &1["association_ambiguous?"])
      end)

    ambiguity_count = length(reconstructed.ambiguous) + source_ambiguity_count

    %{
      items: items,
      ambiguous: reconstructed.ambiguous,
      evidence: %{
        "complete?" =>
          canonical_complete? and missing_exchange_count == 0 and ambiguity_count == 0,
        "canonical_complete?" => canonical_complete?,
        "missing_exchange_count" => missing_exchange_count,
        "ambiguity_count" => ambiguity_count
      }
    }
  end

  def compile(_exchanges, _programs, _trace_facts) do
    %{
      items: [],
      ambiguous: [],
      evidence: %{
        "complete?" => false,
        "canonical_complete?" => false,
        "missing_exchange_count" => 0,
        "ambiguity_count" => 0
      }
    }
  end

  @spec streams([map()]) :: map()
  def streams(exchanges) when is_list(exchanges) do
    exchanges
    |> Enum.sort_by(&Map.get(&1, "input_sequence", 0))
    |> Enum.reduce(initial_stream_state(), &place_exchange/2)
    |> finish_streams()
  end

  def streams(_exchanges), do: %{"streams" => [], "ambiguous" => [], "ambiguous?" => true}

  @doc false
  @spec present_page(map()) :: map()
  def present_page(%{"items" => items} = page) when is_list(items) do
    streams =
      items
      |> Enum.group_by(& &1["stream_id"])
      |> Enum.sort_by(fn {stream_id, turns} ->
        first = List.first(turns, %{})
        {first["request_sequence"] || 0, stream_id}
      end)
      |> Enum.map(fn {stream_id, turns} ->
        turns =
          turns
          |> Enum.sort_by(&{&1["turn"] || 0, &1["request_sequence"] || 0})
          |> Enum.map(&Map.drop(&1, ~w(stream_id run_id trace_id)))
          |> elide_repeated_system()

        %{"stream_id" => stream_id, "turns" => turns}
      end)

    evidence = Map.get(page, "evidence", %{})

    %{
      "streams" => streams,
      "complete?" => Map.get(evidence, "complete?", false),
      "canonical_complete?" => Map.get(evidence, "canonical_complete?", false),
      "missing_exchange_count" => Map.get(evidence, "missing_exchange_count", 0),
      "ambiguous?" => Map.get(evidence, "ambiguity_count", 0) > 0,
      "ambiguity_count" => Map.get(evidence, "ambiguity_count", 0),
      "snapshot_hash" => page["snapshot_hash"],
      "trace_snapshot_hash" => page["trace_snapshot_hash"]
    }
  end

  # The system prompt is the instruction set that shaped a turn, and the
  # evaluated program supplies it per call, so two turns of one stream can
  # carry different prompts: stream linkage keys on `arguments.messages`
  # alone. Every compiled item therefore keeps its own prompt -- `turns` is
  # filtered and paginated downstream, and eliding before that selection would
  # hand a caller a page whose prompt was dropped on a turn it never received.
  #
  # A presented conversation is the whole selection at once, so there the
  # repeat is redundant, and repeating an unchanged prompt on every turn would
  # multiply the largest constant in the result against its byte ceiling. Elide
  # it only here, only against the previous turn of the same presented stream:
  # the first turn of every presented stream always carries its prompt.
  defp elide_repeated_system(turns) do
    turns
    |> Enum.map_reduce(:no_previous_turn, &elide_system/2)
    |> elem(0)
  end

  # An elided turn still means "same prompt as the last one that carried it",
  # so comparison tracks the last present value rather than the previous turn.
  # That makes the compaction idempotent, which is what lets a page be
  # compacted once on the way out and again on the way into a presentation.
  defp elide_system(turn, last) do
    cond do
      not Map.has_key?(turn, "system") -> {turn, last}
      last == {:system, turn["system"]} -> {Map.delete(turn, "system"), last}
      true -> {turn, {:system, turn["system"]}}
    end
  end

  @doc false
  @spec compact_turns([map()]) :: [map()]
  # Applied to one selected page of `turns`, after filtering and pagination.
  # Every page is therefore self-describing -- each stream in it starts with
  # its effective prompt -- while an unchanged prompt is not repeated on every
  # turn, which would otherwise push a prompt-heavy run past the aggregate byte
  # ceiling the whole-conversation collectors enforce over raw items.
  def compact_turns(items) when is_list(items) do
    items
    |> Enum.map_reduce(%{}, fn item, seen ->
      stream_id = item["stream_id"]
      {elided, last} = elide_system(item, Map.get(seen, stream_id, :no_previous_turn))
      {elided, Map.put(seen, stream_id, last)}
    end)
    |> elem(0)
  end

  def compact_turns(items), do: items

  defp conversation_streams(exchanges) do
    result = streams(exchanges)
    %{streams: result["streams"], ambiguous: result["ambiguous"]}
  end

  defp generated_sources(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.flat_map(calls, fn call ->
      case get_in(call, ["args", "program"]) do
        source when is_binary(source) -> [source]
        _other -> []
      end
    end)
  end

  defp generated_sources(_assistant), do: []

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
      _multiple -> add_ambiguous(exchange, "multiple_maximal_predecessors", state)
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
      turn: turn
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

  defp prefix?(prefix, messages) when length(prefix) < length(messages) do
    messages
    |> Enum.take(length(prefix))
    |> Enum.zip(prefix)
    |> Enum.all?(fn {message, expected} ->
      comparable_message(message) == comparable_message(expected)
    end)
  end

  defp prefix?(_prefix, _messages), do: false

  # The agent loop carries blank tool-call narration forward as nil. Compare
  # that known provider/agent representation difference without rewriting the
  # raw request or response retained in the projection.
  defp comparable_message(%{"role" => "assistant", "tool_calls" => [_ | _]} = message) do
    case Map.get(message, "content") do
      nil -> Map.put(message, "content", nil)
      content when is_binary(content) -> normalize_blank_content(message, content)
      _other -> message
    end
  end

  defp comparable_message(message), do: message

  defp normalize_blank_content(message, content) do
    if RuntimeString.blank?(content),
      do: Map.put(message, "content", nil),
      else: message
  end

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
