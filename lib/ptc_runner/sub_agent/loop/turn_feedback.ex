defmodule PtcRunner.SubAgent.Loop.TurnFeedback do
  @moduledoc """
  Turn feedback formatting for SubAgent execution.

  Formats execution results and turn state information for LLM feedback.
  Supports the unified budget model with work turns and retry turns.

  Uses Mustache templates from `PtcRunner.Prompts`:
  - `must_return_warning/0` - Warning for final work turn
  - `retry_feedback/0` - Turn info during retry phase
  """

  alias PtcRunner.Mustache
  alias PtcRunner.Prompts
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.ProgressRenderer

  @doc """
  Append turn progress info to a feedback message.

  For multi-turn agents with retry_turns, shows unified budget info.
  For multi-turn agents without retry_turns, shows legacy turn count.
  """
  @spec append_turn_info(String.t(), SubAgent.t(), map()) :: String.t()
  def append_turn_info(message, agent, state) do
    # Use unified budget model if retry_turns is configured
    if agent.retry_turns > 0 do
      append_unified_budget_info(message, state, agent)
    else
      append_legacy_turn_info(message, agent, state)
    end
  end

  # Unified budget info with work/retry counters
  defp append_unified_budget_info(message, state, agent) do
    work_left = state.work_turns_remaining
    retry_left = state.retry_turns_remaining
    next_turn = state.turn + 1
    in_retry_phase = work_left <= 0

    turn_info =
      cond do
        # In retry phase - use retry_feedback template
        in_retry_phase ->
          attempt_num = agent.retry_turns - retry_left + 1
          is_final_retry = retry_left == 1

          context = %{
            is_final_retry: is_final_retry,
            current_retry: attempt_num,
            total_retries: agent.retry_turns,
            retries_remaining: retry_left,
            next_turn: next_turn
          }

          {:ok, rendered} = Mustache.render(Prompts.retry_feedback(), context)
          emoji_prefix = if is_final_retry, do: "⚠️ ", else: ""
          "\n\n" <> emoji_prefix <> rendered

        # Last work turn - use must_return_warning template
        work_left == 1 ->
          context = %{
            has_retries: retry_left > 0,
            retry_count: retry_left
          }

          {:ok, rendered} = Mustache.render(Prompts.must_return_warning(), context)
          "\n\n⚠️ " <> rendered

        # Normal work turns - simple string (no template needed)
        true ->
          "\n\nTurn #{next_turn} (#{work_left} work turns + #{retry_left} retry turns remaining)"
      end

    message <> turn_info
  end

  # Legacy turn info (no retry_turns)
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

    # Append progress checklist if agent has a plan
    feedback = append_progress(feedback, agent, state, lisp_step)

    {feedback, truncated?}
  end

  @doc """
  Render initial progress checklist (all pending) for the first user message.

  Returns empty string if agent has no plan.
  """
  @spec render_initial_progress(SubAgent.t()) :: String.t()
  def render_initial_progress(%SubAgent{plan: []} = _agent), do: ""

  def render_initial_progress(%SubAgent{plan: plan}) do
    ProgressRenderer.render(plan, %{})
  end

  # Append progress checklist if agent has a plan
  defp append_progress(feedback, %SubAgent{plan: []}, _state, _lisp_step), do: feedback

  defp append_progress(feedback, agent, state, lisp_step) do
    # Merge current turn's summaries so they appear in the next turn's prompt.
    # The loop calls format() before merging into state, so we merge here.
    merged_summaries = Map.merge(state.summaries, lisp_step.summaries || %{})

    checklist =
      ProgressRenderer.render(agent.plan, merged_summaries)

    if checklist == "" do
      feedback
    else
      feedback <> "\n\n" <> checklist
    end
  end

  # Private helpers

  defp truncate_prints(str, max_chars) when byte_size(str) > max_chars do
    {String.slice(str, 0, max_chars), true}
  end

  defp truncate_prints(str, _max_chars), do: {str, false}
end
