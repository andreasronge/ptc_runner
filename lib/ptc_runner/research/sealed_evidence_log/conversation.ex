defmodule PtcRunner.Research.SealedEvidenceLog.Conversation do
  @moduledoc """
  Digest-based turn reconstruction that never retains evidence payloads.

  Prefix matching hashes the comparable form of the current request's messages
  against stored complete-message digests from earlier completed exchanges.
  In-flight request messages are staged only until the matching output arrives.
  """

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Lisp.Runtime.String, as: RuntimeString

  @type node_row :: %{
          complete_hash: binary(),
          complete_count: non_neg_integer(),
          stream_id: binary(),
          turn: pos_integer()
        }

  @spec new() :: map()
  def new do
    %{
      nodes: [],
      pending: %{},
      turns: [],
      ambiguous: [],
      stream_order: [],
      next_stream: 1,
      program_hashes: [],
      source_hashes: []
    }
  end

  @spec observe_input(map(), map()) :: map()
  def observe_input(state, record) when is_map(state) and is_map(record) do
    if model_input?(record) do
      place_input(state, record)
    else
      state
    end
  end

  @spec observe_output(map(), map()) :: map()
  def observe_output(state, record) when is_map(state) and is_map(record) do
    if model_output?(record) do
      complete_turn(state, record)
    else
      state
    end
  end

  @spec observe_source(map(), map()) :: map()
  def observe_source(state, record) when is_map(state) and is_map(record) do
    source = get_in(record, ["payload", "source"])

    if is_binary(source) do
      hash = hash_value(source)
      evaluation_id = get_in(record, ["correlation", "evaluation_id"])

      update_in(state, [:source_hashes], fn rows ->
        [
          %{
            hash: hash,
            sequence: record["sequence"],
            evaluation_id: evaluation_id,
            parent_evaluation_id: nil
          }
          | rows
        ]
      end)
    else
      state
    end
  end

  @spec finish(map(), map()) :: map()
  def finish(state, trace_facts) when is_map(state) and is_map(trace_facts) do
    source_counts = Enum.frequencies_by(state.source_hashes, & &1.hash)

    by_stream = Enum.group_by(state.turns, & &1.stream_id)

    turns =
      state.stream_order
      |> Enum.flat_map(fn stream_id ->
        by_stream
        |> Map.get(stream_id, [])
        |> Enum.sort_by(& &1.turn)
      end)
      |> Enum.map(&attach_generated(&1, state.source_hashes, source_counts))

    expected = MapSet.new(Map.get(trace_facts, "expected_model_exchange_ids", []))

    captured =
      turns
      |> Enum.map(& &1.capability_id)
      |> MapSet.new()

    missing_exchange_count = expected |> MapSet.difference(captured) |> MapSet.size()

    canonical_complete? =
      Map.get(trace_facts, "terminal?", false) and
        not Map.get(trace_facts, "events_dropped?", false)

    source_ambiguity_count =
      Enum.count(turns, fn turn ->
        Enum.any?(turn.generated, & &1.association_ambiguous?)
      end)

    ambiguity_count = length(state.ambiguous) + source_ambiguity_count

    %{
      turns: turns,
      ambiguous: Enum.reverse(state.ambiguous),
      evidence: %{
        "complete?" =>
          canonical_complete? and missing_exchange_count == 0 and ambiguity_count == 0,
        "canonical_complete?" => canonical_complete?,
        "missing_exchange_count" => missing_exchange_count,
        "ambiguity_count" => ambiguity_count
      }
    }
  end

  @spec assemble_turn(map(), map(), map(), [map()]) :: map()
  def assemble_turn(turn_meta, input, output, generated) do
    exchange = capability_pair(input, output)
    messages = get_in(exchange, ["arguments", "messages"]) || []
    assistant = assistant_message(exchange["result"])
    predecessor_count = max(length(messages) - added_count(turn_meta), 0)
    added = Enum.drop(messages, predecessor_count)

    %{
      "turn" => turn_meta.turn,
      "stream_id" => turn_meta.stream_id,
      "capability_id" => exchange["capability_id"],
      "request_sequence" => exchange["input_sequence"],
      "response_sequence" => exchange["output_sequence"],
      "system" => get_in(exchange, ["arguments", "system"]),
      "messages_added" => added,
      "feedback" => Enum.filter(added, &(&1["role"] == "tool")),
      "response" => exchange["result"],
      "assistant" => assistant,
      "tokens" => get_in(exchange, ["result", "value", "tokens"]),
      "outcome" => exchange["result"]["status"],
      "run_id" => input["run_id"],
      "trace_id" => input["trace_id"],
      "generated" => generated
    }
  end

  defp place_input(state, record) do
    capability_id = record["correlation"]["capability_id"]
    messages = get_in(record, ["payload", "arguments", "messages"])

    if is_list(messages) do
      comparable = Enum.map(messages, &comparable_message/1)
      {stream_id, turn, added_count, state} = choose_predecessor(state, comparable)

      pending = %{
        capability_id: capability_id,
        sequence: record["sequence"],
        comparable: comparable,
        stream_id: stream_id,
        turn: turn,
        added_count: added_count
      }

      %{state | pending: Map.put(state.pending, capability_id, pending)}
    else
      add_ambiguous(state, capability_id, record["sequence"], "messages_unavailable")
    end
  end

  defp choose_predecessor(state, comparable) do
    candidates =
      Enum.filter(state.nodes, fn node ->
        node.complete_count < length(comparable) and prefix_match?(comparable, node)
      end)

    if candidates == [] do
      stream_id = "stream-#{state.next_stream}"

      state = %{
        state
        | next_stream: state.next_stream + 1,
          stream_order: state.stream_order ++ [stream_id]
      }

      {stream_id, 1, length(comparable), state}
    else
      max_size = candidates |> Enum.map(& &1.complete_count) |> Enum.max()
      longest = Enum.filter(candidates, &(&1.complete_count == max_size))

      case longest do
        [predecessor] ->
          added = length(comparable) - predecessor.complete_count
          {predecessor.stream_id, predecessor.turn + 1, added, state}

        _multiple ->
          {:ambiguous, :ambiguous, 0, state}
      end
    end
  end

  defp complete_turn(state, record) do
    capability_id = record["correlation"]["capability_id"]

    case Map.pop(state.pending, capability_id) do
      {nil, _pending} ->
        state

      {pending, pending_map} ->
        if pending.stream_id == :ambiguous do
          state
          |> Map.put(:pending, pending_map)
          |> add_ambiguous(
            capability_id,
            pending.sequence,
            "multiple_maximal_predecessors"
          )
        else
          assistant = assistant_message(record["payload"]["result"])
          complete = pending.comparable ++ [comparable_message(assistant)]
          {:ok, encoded} = DeterministicJSON.encode(complete)
          program_hashes = program_hashes(record["payload"]["result"])

          node = %{
            complete_hash: :crypto.hash(:sha256, encoded),
            complete_count: length(complete),
            stream_id: pending.stream_id,
            turn: pending.turn
          }

          turn = %{
            ordinal: length(state.turns) + 1,
            stream_id: pending.stream_id,
            turn: pending.turn,
            capability_id: capability_id,
            input_sequence: pending.sequence,
            output_sequence: record["sequence"],
            messages_added_roles: List.duplicate(:added, pending.added_count),
            program_hashes: program_hashes,
            generated: []
          }

          %{
            state
            | pending: pending_map,
              nodes: state.nodes ++ [node],
              turns: [turn | state.turns]
          }
        end
    end
  end

  defp attach_generated(turn, source_hashes, source_counts) do
    generated =
      Enum.flat_map(turn.program_hashes, fn hash ->
        matches = Enum.filter(source_hashes, &(&1.hash == hash))

        Enum.map(matches, fn source ->
          %{
            sequence: source.sequence,
            evaluation_id: source.evaluation_id,
            association: "source_match",
            association_ambiguous?: Map.get(source_counts, hash, 0) > 1
          }
        end)
      end)

    Map.put(turn, :generated, generated)
  end

  defp prefix_match?(comparable, node) do
    prefix = Enum.take(comparable, node.complete_count)

    case DeterministicJSON.encode(prefix) do
      {:ok, encoded} -> :crypto.hash(:sha256, encoded) == node.complete_hash
      _error -> false
    end
  end

  defp add_ambiguous(state, capability_id, sequence, reason) do
    entry = %{
      "capability_id" => capability_id,
      "request_sequence" => sequence,
      "reason" => reason
    }

    %{state | ambiguous: [entry | state.ambiguous]}
  end

  defp model_input?(%{"record_type" => "capability-input", "payload" => payload}),
    do: payload["environment"] == "workflow" and payload["name"] == "llm-request"

  defp model_input?(_record), do: false

  defp model_output?(%{"record_type" => "capability-output", "payload" => payload}),
    do: payload["environment"] == "workflow" and payload["name"] == "llm-request"

  defp model_output?(_record), do: false

  defp program_hashes(%{"value" => %{"tool_calls" => calls}}) when is_list(calls) do
    Enum.flat_map(calls, fn call ->
      case get_in(call, ["args", "program"]) do
        source when is_binary(source) -> [hash_value(source)]
        _other -> []
      end
    end)
  end

  defp program_hashes(_result), do: []

  defp hash_value(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  # ex_dna:disable-for-next-line — research prototype mirrors ConversationProjection for the differential oracle
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

  # ex_dna:disable-for-next-line — research prototype mirrors ConversationProjection for the differential oracle
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

  defp added_count(%{messages_added_count: count}) when is_integer(count) and count >= 0,
    do: count

  defp added_count(%{messages_added_roles: roles}) when is_list(roles), do: length(roles)
  defp added_count(_turn_meta), do: 0

  defp capability_pair(input, output) do
    %{
      "run_id" => input["run_id"],
      "trace_id" => input["trace_id"],
      "capability_id" => input["correlation"]["capability_id"],
      "environment" => input["payload"]["environment"],
      "mission_name" => input["payload"]["mission_name"],
      "name" => input["payload"]["name"],
      "input_sequence" => input["sequence"],
      "output_sequence" => output["sequence"],
      "arguments" => input["payload"]["arguments"],
      "result" => output["payload"]["result"],
      "complete?" => true
    }
  end

  defdelegate compact_turns(items), to: ConversationProjection
end
