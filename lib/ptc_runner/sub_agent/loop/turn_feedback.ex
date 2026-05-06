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

  Returns `{feedback_string, truncated?, new_progress_state}`.

  Only shows explicit println output - the LLM must be intentional about what it inspects.

  This is a thin wrapper around `execution_feedback/3` that additionally appends
  `append_turn_info/3` and `append_progress/4` output. Tool-call transport
  (Phase 4 of the PTC-Lisp tool-call plan) reuses `execution_feedback/3`
  directly so loop-control scaffolding (turn budgets, custom `progress_fn`
  output) does not leak into the `ptc_lisp_execute` tool-result JSON.
  """
  @spec format(Definition.t(), map(), map()) :: {String.t(), boolean(), term()}
  def format(agent, state, lisp_step) do
    execution = execution_feedback(agent, state, lisp_step)

    feedback =
      execution.feedback
      |> append_turn_info(agent, state)

    {feedback, new_progress_state} = append_progress(feedback, agent, state, lisp_step)

    {feedback, execution.truncated, new_progress_state}
  end

  @doc """
  Render the execution-feedback portion of a PTC-Lisp turn into a structured map.

  This is the canonical execution-feedback renderer. `format/3` calls it and
  then layers on `append_turn_info/3` and `append_progress/4` for content-mode
  multi-turn agents. The upcoming `:tool_call` transport (Phase 4 of the
  PTC-Lisp tool-call plan) reuses this function directly to populate the
  `feedback` field of the `ptc_lisp_execute` tool-result JSON, ensuring loop
  control scaffolding (turn budgets, `progress_fn` output) does not leak into
  native tool results.

  ## Fields

  - `:feedback` — the LLM-facing feedback string. Contains only the execution
    portion: result preview (`user=> ...`), printed `println` output, and
    changed/new memory previews (`;; items = [...]`). Does **not** include
    `append_turn_info` or `append_progress` output.
  - `:prints` — the raw `lisp_step.prints` list (untruncated; truncation is
    reflected in `feedback` and the top-level `truncated` flag).
  - `:result` — preview string of `lisp_step.return` (`"user=> ..."`), or
    `nil` when `lisp_step.return` is `nil` or a `Var`. Rendered
    unconditionally for the structured field — the suppression rules that
    `format/3` applies to its human-readable string (single-turn agents,
    or turns with non-empty `prints`) do **not** affect this field. Phase 4
    of the PTC-Lisp tool-call plan relies on this so the `ptc_lisp_execute`
    tool-result JSON always carries the final value.
  - `:memory.changed` — map of `name => preview` for memory bindings that are
    new or whose value changed since the previous turn. String-keyed for
    direct use in tool-result JSON. Populated unconditionally regardless of
    `agent.max_turns`, for the same Phase 4 reason.
  - `:memory.stored_keys` — sorted list of all currently-stored memory binding
    names (string-keyed). Fallback orientation hint when nothing changed or
    previews were truncated.
  - `:memory.truncated` — `true` if any memory preview was truncated.
  - `:truncated` — `true` if any preview (prints, result, or memory) was
    truncated.
  """
  @spec execution_feedback(Definition.t(), map(), map()) :: %{
          feedback: String.t(),
          prints: [String.t()],
          result: String.t() | nil,
          memory: %{
            changed: %{String.t() => String.t()},
            stored_keys: [String.t()],
            truncated: boolean()
          },
          truncated: boolean()
        }
  def execution_feedback(agent, state, lisp_step) do
    max_chars = Keyword.get(agent.format_options, :feedback_max_chars, 512)
    preview_max = Keyword.get(agent.format_options, :preview_max_chars, 250)

    {prints_output, prints_truncated?} = format_prints(lisp_step.prints, max_chars)

    # Unconditional structured fields — always rendered regardless of agent.max_turns
    # or whether prints is non-empty. These populate the structured `:result` and
    # `:memory.changed` fields, which Phase 4's tool-call transport reuses to build
    # the `ptc_lisp_execute` tool-result JSON. The human-readable `feedback` string
    # below still applies the historical suppression rules (single-turn agents and
    # agents with println output omit the result preview / stored hint) so that
    # content-mode parity is preserved byte-for-byte.
    {result_preview_unconditional, result_truncated?} =
      format_result_preview_unconditional(lisp_step, preview_max)

    {memory_hint_unconditional, memory_changed, memory_truncated?} =
      build_memory_section_unconditional(state, lisp_step, preview_max)

    # Suppressed variants for the feedback string (parity with format/3).
    result_preview_for_feedback =
      format_result_preview(prints_output, agent, lisp_step, result_preview_unconditional)

    memory_hint_for_feedback =
      memory_section_for_feedback(agent, lisp_step, memory_hint_unconditional)

    prints_with_hint =
      if prints_truncated? do
        prints_output <> "\n... (truncated, print specific fields instead)"
      else
        prints_output
      end

    feedback =
      [result_preview_for_feedback, prints_with_hint, memory_hint_for_feedback]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    truncated? = prints_truncated? or memory_truncated? or result_truncated?

    %{
      feedback: feedback,
      prints: lisp_step.prints || [],
      result: result_preview_unconditional,
      memory: %{
        changed: memory_changed,
        stored_keys: stored_keys(lisp_step),
        truncated: memory_truncated?
      },
      truncated: truncated?
    }
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

  # Always renders a result preview when `lisp_step.return` is a non-nil,
  # non-Var value. Returns `{preview_string_or_nil, truncated?}`. This is the
  # "unsuppressed" path used to populate the structured `:result` field of
  # `execution_feedback/3` regardless of `agent.max_turns` or whether prints
  # are non-empty. The boolean propagates to the top-level `:truncated` flag
  # so Phase 4's tool-result JSON correctly signals an incomplete preview.
  # The `format_result_preview/4` wrapper applies the human-feedback
  # suppression rules on top of the string portion only.
  defp format_result_preview_unconditional(lisp_step, preview_max) do
    if lisp_step.return != nil and not var?(lisp_step.return) do
      {text, was_truncated?} = truncate_value(lisp_step.return, preview_max)

      hint =
        if was_truncated?,
          do: "\n... (truncated, use println on specific fields)",
          else: ""

      {"user=> #{text}#{hint}", was_truncated?}
    else
      {nil, false}
    end
  end

  # Suppressed variant for the human-readable feedback string. Mirrors the
  # historical rules: only render when there is no println output AND the
  # agent is multi-turn. Defers actual rendering to the unconditional helper.
  defp format_result_preview(nil = _prints, agent, _lisp_step, unconditional_preview)
       when agent.max_turns > 1 do
    unconditional_preview
  end

  defp format_result_preview(_prints, _agent, _lisp_step, _unconditional_preview), do: nil

  # Always renders the memory section (hint text + changed map + truncation
  # flag) whenever `lisp_step.memory` is non-empty. Returns
  # `{hint_text_or_nil, changed_previews_map, any_truncated?}`. This is the
  # "unsuppressed" path used to populate the structured `:memory.changed`
  # field of `execution_feedback/3` regardless of `agent.max_turns`.
  #
  # The hint text and changed map are computed together because they share
  # the same `changed_vars` + `truncate_value` traversal.
  defp build_memory_section_unconditional(state, lisp_step, preview_max) do
    if is_map(lisp_step.memory) and map_size(lisp_step.memory) > 0 do
      prev_memory = state.memory || %{}
      changed = changed_vars(prev_memory, lisp_step.memory)

      if map_size(changed) > 0 do
        {previews_kv, any_truncated?} =
          changed
          |> Enum.sort_by(fn {k, _} -> to_string(k) end)
          |> Enum.map_reduce(false, fn {k, v}, trunc_acc ->
            {text, was_truncated?} = truncate_value(v, preview_max)
            {{to_string(k), text}, trunc_acc or was_truncated?}
          end)

        lines = Enum.map(previews_kv, fn {k, text} -> ";; #{k} = #{text}" end)

        hint =
          if any_truncated?,
            do: "\n;; (truncated, use println on specific fields)",
            else: ""

        stored_hint_text = Enum.join(lines, "\n") <> hint
        {stored_hint_text, Map.new(previews_kv), any_truncated?}
      else
        stored_symbols =
          lisp_step.memory
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.sort()
          |> Enum.join(", ")

        {"Stored: #{stored_symbols}", %{}, false}
      end
    else
      {nil, %{}, false}
    end
  end

  # Suppressed variant of the memory hint text for the human-readable feedback
  # string. Mirrors the historical rule: only render the stored hint for
  # multi-turn agents. The structured `:memory.changed` field is populated
  # from the unconditional helper regardless.
  defp memory_section_for_feedback(agent, lisp_step, unconditional_hint)
       when agent.max_turns > 1 and is_map(lisp_step.memory) do
    unconditional_hint
  end

  defp memory_section_for_feedback(_agent, _lisp_step, _unconditional_hint), do: nil

  defp stored_keys(lisp_step) do
    case lisp_step.memory do
      memory when is_map(memory) ->
        memory
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

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
