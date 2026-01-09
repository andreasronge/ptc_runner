defmodule PtcRunner.SubAgent.Loop.TurnFeedback do
  @moduledoc """
  Turn feedback formatting for SubAgent execution.

  Formats execution results and turn state information for LLM feedback.
  """

  alias PtcRunner.SubAgent

  @doc """
  Append turn progress info to a feedback message.

  For multi-turn agents, adds remaining turn count and final turn warnings.
  """
  @spec append_turn_info(String.t(), SubAgent.t(), map()) :: String.t()
  def append_turn_info(message, agent, state) do
    if agent.max_turns > 1 do
      next_turn = state.turn + 1
      turns_remaining = agent.max_turns - state.turn

      turn_info =
        if turns_remaining == 1 do
          "\n\n⚠️ FINAL TURN - you must call (return result) or (fail response) next."
        else
          "\n\nTurn #{next_turn} of #{agent.max_turns} (#{turns_remaining} remaining)"
        end

      message <> turn_info
    else
      message
    end
  end

  @doc """
  Format execution result feedback for the next LLM turn.

  Returns `{feedback_string, truncated?}`.

  Only shows explicit println output - the LLM must be intentional about what it inspects.
  """
  @spec format(SubAgent.t(), map(), map()) :: {String.t(), boolean()}
  def format(agent, state, lisp_step) do
    max_chars = Keyword.get(agent.format_options, :feedback_max_chars, 512)

    # Only show println output (no implicit last-expression result)
    {prints_output, truncated?} =
      case lisp_step.prints do
        [_ | _] = prints ->
          joined = Enum.join(prints, "\n")
          truncate_prints(joined, max_chars)

        _ ->
          {nil, false}
      end

    # Add stored values hint for multi-turn agents (shows def bindings available as symbols)
    stored_hint =
      if agent.max_turns > 1 and map_size(lisp_step.memory) > 0 do
        stored_symbols =
          lisp_step.memory
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.sort()
          |> Enum.join(", ")

        "Stored (access as symbols): #{stored_symbols}"
      else
        nil
      end

    # Add truncation hint if needed
    prints_with_hint =
      if truncated? do
        prints_output <> "\n... (truncated, use println selectively)"
      else
        prints_output
      end

    # Combine parts
    feedback =
      [prints_with_hint, stored_hint]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    # Add turn info for multi-turn agents
    feedback = append_turn_info(feedback, agent, state)

    {feedback, truncated?}
  end

  # Private helpers

  defp truncate_prints(str, max_chars) when byte_size(str) > max_chars do
    {String.slice(str, 0, max_chars), true}
  end

  defp truncate_prints(str, _max_chars), do: {str, false}
end
