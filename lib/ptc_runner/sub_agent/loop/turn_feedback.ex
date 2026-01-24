defmodule PtcRunner.SubAgent.Loop.TurnFeedback do
  @moduledoc """
  Turn feedback formatting for SubAgent execution.

  Formats execution results and turn state information for LLM feedback.
  Supports the unified budget model with work turns and retry turns.
  """

  alias PtcRunner.SubAgent

  @doc """
  Append turn progress info to a feedback message.

  For multi-turn agents with return_retries, shows unified budget info.
  For multi-turn agents without return_retries, shows legacy turn count.
  """
  @spec append_turn_info(String.t(), SubAgent.t(), map()) :: String.t()
  def append_turn_info(message, agent, state) do
    # Use unified budget model if return_retries is configured
    if agent.return_retries > 0 do
      append_unified_budget_info(message, state)
    else
      append_legacy_turn_info(message, agent, state)
    end
  end

  # Unified budget info with work/retry counters
  defp append_unified_budget_info(message, state) do
    work_left = state.work_turns_remaining
    retry_left = state.retry_turns_remaining
    next_turn = state.turn + 1
    in_retry_phase = work_left <= 0

    turn_info =
      cond do
        # In retry phase
        in_retry_phase and retry_left == 1 ->
          "\n\n⚠️ FINAL RETRY - you must call (return result) or (fail response) next."

        in_retry_phase ->
          "\n\nTurn #{next_turn}: RETRY MODE (#{retry_left} retries remaining)"

        # Last work turn - must return
        work_left == 1 ->
          "\n\n⚠️ FINAL WORK TURN - tools stripped, you must call (return result) or (fail response)."

        # Normal work turns
        true ->
          "\n\nTurn #{next_turn} (#{work_left} work turns + #{retry_left} retry turns remaining)"
      end

    message <> turn_info
  end

  # Legacy turn info (no return_retries)
  defp append_legacy_turn_info(message, agent, state) do
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
  Build error feedback with appropriate turn info based on unified budget model.

  This is used by the loop to format error messages with context about
  work/retry budgets.
  """
  @spec build_error_feedback(String.t(), SubAgent.t(), map()) :: String.t()
  def build_error_feedback(error_message, agent, state) do
    # Start with the error message
    base = "Error: #{error_message}"

    # Add turn info based on budget model
    append_turn_info(base, agent, state)
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
