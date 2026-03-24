defmodule PtcRunner.SubAgent.Loop.TurnFeedback do
  @moduledoc """
  Turn feedback formatting for SubAgent execution.

  Formats execution results and turn state information for LLM feedback.
  Supports the unified budget model with work turns and retry turns.

  Uses Mustache templates from `PtcRunner.Prompts`:
  - `must_return_warning/0` - Warning for final work turn
  - `retry_feedback/0` - Turn info during retry phase
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.Mustache
  alias PtcRunner.Prompts
  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.ProgressRenderer

  @doc """
  Append turn progress info to a feedback message.

  For multi-turn agents with retry_turns, shows unified budget info.
  For multi-turn agents without retry_turns, shows legacy turn count.
  """
  @spec append_turn_info(String.t(), Definition.t(), map()) :: String.t()
  def append_turn_info(message, agent, state) do
    minimal? = Keyword.get(agent.format_options, :minimal_turn_info, false)

    cond do
      agent.max_turns <= 1 ->
        message

      minimal? ->
        # Only show warnings when running low on turns
        append_minimal_turn_info(message, state, agent)

      true ->
        append_budget_info(message, state, agent)
    end
  end

  # Minimal turn info — only show warning when running low on turns
  # During retry phase, work_turns_remaining is 0 so we use retry_turns_remaining
  defp append_minimal_turn_info(message, state, _agent) do
    if state.retry_turns_remaining > 0 and state.work_turns_remaining <= 0 do
      # In retry phase — always warn since retries are limited
      message <>
        "\n\n;; #{state.retry_turns_remaining} retry turns remaining — call (return value) now"
    else
      turns_after_this = max(state.work_turns_remaining - 1, 0)

      if turns_after_this <= 2 do
        message <> "\n\n;; #{turns_after_this} turns remaining — call (return value) soon"
      else
        message
      end
    end
  end

  # work_turns_remaining is decremented AFTER feedback is built,
  # so we subtract 1 to show turns remaining after this turn.
  defp append_budget_info(message, state, agent) do
    work_left = state.work_turns_remaining
    turns_after_this = work_left - 1
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

        # Next turn is the last work turn - warn LLM
        turns_after_this == 1 ->
          context = %{
            has_retries: retry_left > 0,
            retry_count: retry_left
          }

          {:ok, rendered} = Mustache.render(Prompts.must_return_warning(), context)
          "\n\n⚠️ " <> rendered

        # Normal work turns with retries
        retry_left > 0 ->
          "\n\nTurn #{next_turn} (#{turns_after_this} work turns + #{retry_left} retry turns remaining)"

        # Two turns left (no retries) - give advance warning to start wrapping up
        turns_after_this == 2 ->
          "\n\nTurn #{next_turn} of #{agent.max_turns} (#{turns_after_this} remaining) — next turn is your LAST, start preparing your (return ...) now."

        true ->
          "\n\nTurn #{next_turn} of #{agent.max_turns} (#{turns_after_this} remaining)"
      end

    message <> turn_info
  end

  @doc """
  Build error feedback with appropriate turn info based on unified budget model.

  This is used by the loop to format error messages with context about
  work/retry budgets.
  """
  @spec build_error_feedback(String.t(), Definition.t(), map()) :: String.t()
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
  @spec format(Definition.t(), map(), map()) :: {String.t(), boolean()}
  def format(agent, state, lisp_step) do
    max_chars = Keyword.get(agent.format_options, :feedback_max_chars, 512)
    preview_max = Keyword.get(agent.format_options, :preview_max_chars, 250)

    {prints_output, truncated?} = format_prints(lisp_step.prints, max_chars)
    result_preview = format_result_preview(prints_output, agent, lisp_step, preview_max)
    stored_hint = format_stored_hint(agent, state, lisp_step, preview_max)

    # Add truncation hint if needed
    prints_with_hint =
      if truncated? do
        prints_output <> "\n... (truncated, print specific fields instead)"
      else
        prints_output
      end

    # Combine parts
    feedback =
      [result_preview, prints_with_hint, stored_hint]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    # Add turn info for multi-turn agents
    feedback = append_turn_info(feedback, agent, state)

    # Append progress via progress_fn (default: checklist from plan + summaries)
    {feedback, new_progress_state} = append_progress(feedback, agent, state, lisp_step)

    {feedback, truncated?, new_progress_state}
  end

  @doc """
  Render initial progress for the first user message.

  Returns `{text, progress_state}`. Uses `progress_fn` if set, otherwise
  renders the default checklist from `plan`. Returns `{"", nil}` if no plan
  and no custom `progress_fn`.
  """
  @spec render_initial_progress(Definition.t(), term()) :: {String.t(), term()}
  def render_initial_progress(agent, progress_state \\ nil) do
    input = %{
      plan: agent.plan,
      summaries: %{},
      tool_calls: [],
      turn: 0,
      phase: :initial
    }

    call_progress_fn(agent, input, progress_state)
  end

  defp append_progress(feedback, agent, state, lisp_step) do
    merged_summaries = Map.merge(state.summaries, lisp_step.summaries || %{})

    input = %{
      plan: agent.plan,
      summaries: merged_summaries,
      tool_calls: lisp_step.tool_calls || [],
      turn: state.turn,
      phase: :continuation
    }

    {progress_text, new_progress_state} = call_progress_fn(agent, input, state.progress_state)

    new_feedback =
      if progress_text == "" do
        feedback
      else
        feedback <> "\n\n" <> progress_text
      end

    {new_feedback, new_progress_state}
  end

  # Default: no custom progress_fn, empty plan → no-op
  defp call_progress_fn(%Definition{progress_fn: nil}, %{plan: []}, progress_state) do
    {"", progress_state}
  end

  # Default: no custom progress_fn → use ProgressRenderer
  defp call_progress_fn(
         %Definition{progress_fn: nil, plan: plan},
         %{summaries: summaries},
         progress_state
       ) do
    {ProgressRenderer.render(plan, summaries), progress_state}
  end

  # Custom: delegate to user function, validate return shape
  defp call_progress_fn(%Definition{progress_fn: fun}, input, progress_state) do
    case fun.(input, progress_state) do
      {text, new_state} when is_binary(text) ->
        {text, new_state}

      other ->
        raise ArgumentError,
              "progress_fn must return {String.t(), term()}, got: #{inspect(other)}"
    end
  end

  # Private helpers

  defp format_prints([_ | _] = prints, max_chars) do
    joined = Enum.join(prints, "\n")
    truncate_prints(joined, max_chars)
  end

  defp format_prints(_, _max_chars), do: {nil, false}

  # Show truncated result preview when no println output and result is not a Var
  defp format_result_preview(nil = _prints, agent, lisp_step, preview_max)
       when agent.max_turns > 1 do
    if lisp_step.return != nil and not var?(lisp_step.return) do
      {text, was_truncated?} = truncate_value(lisp_step.return, preview_max)

      hint =
        if was_truncated?,
          do: "\n... (truncated, use println on specific fields)",
          else: ""

      "user=> #{text}#{hint}"
    end
  end

  defp format_result_preview(_prints, _agent, _lisp_step, _preview_max), do: nil

  # Show previews of new/changed def bindings
  defp format_stored_hint(agent, state, lisp_step, preview_max)
       when agent.max_turns > 1 do
    if map_size(lisp_step.memory) > 0 do
      prev_memory = state.memory || %{}
      changed = changed_vars(prev_memory, lisp_step.memory)

      cond do
        map_size(changed) > 0 ->
          {previews, any_truncated?} =
            changed
            |> Enum.sort_by(fn {k, _} -> to_string(k) end)
            |> Enum.map_reduce(false, fn {k, v}, trunc_acc ->
              {text, was_truncated?} = truncate_value(v, preview_max)
              {";; #{k} = #{text}", trunc_acc or was_truncated?}
            end)

          hint =
            if any_truncated?,
              do: "\n;; (truncated, use println on specific fields)",
              else: ""

          Enum.join(previews, "\n") <> hint

        map_size(lisp_step.memory) > 0 ->
          stored_symbols =
            lisp_step.memory
            |> Map.keys()
            |> Enum.map(&to_string/1)
            |> Enum.sort()
            |> Enum.join(", ")

          "Stored: #{stored_symbols}"

        true ->
          nil
      end
    end
  end

  defp format_stored_hint(_agent, _state, _lisp_step, _preview_max), do: nil

  defp truncate_prints(str, max_chars) when byte_size(str) > max_chars do
    {String.slice(str, 0, max_chars), true}
  end

  defp truncate_prints(str, _max_chars), do: {str, false}

  # Return only vars that are new or changed compared to previous turn
  defp changed_vars(prev_memory, current_memory) do
    current_memory
    |> Enum.filter(fn {k, v} -> Map.get(prev_memory, k) != v end)
    |> Map.new()
  end

  # Format a value as Clojure EDN and truncate for preview.
  # Returns {text, was_truncated?}.
  defp truncate_value(value, max_len) do
    {str, format_truncated?} = Format.to_clojure(value, limit: 50)

    if String.length(str) > max_len do
      {String.slice(str, 0, max_len) <> " ...", true}
    else
      {str, format_truncated?}
    end
  end

  defp var?(%{__struct__: mod}) when is_atom(mod),
    do: mod |> to_string() |> String.ends_with?("Var")

  defp var?(_), do: false
end
