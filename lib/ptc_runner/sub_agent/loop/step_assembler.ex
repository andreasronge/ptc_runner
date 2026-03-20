defmodule PtcRunner.SubAgent.Loop.StepAssembler do
  @moduledoc """
  Final step assembly for SubAgent execution.

  Centralizes the common pattern of enriching a `%Step{}` with usage metrics,
  trace-filtered turns, collected messages, and prompt metadata. Used by both
  `Loop` and `Loop.TextMode` to construct the step returned from `SubAgent.run/2`.
  """

  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Loop.Metrics

  @doc """
  Finalize a step with metrics, turns, messages, and prompt metadata from state.

  ## Options

  - `:duration_ms` — required, total execution duration
  - `:memory_bytes` — memory used in bytes (default `0`)
  - `:turn_offset` — offset for turn count, e.g. `-1` for pre-turn failures (default `0`)
  - `:is_error` — whether this is an error step, affects trace filtering (default `false`)
  - `:final_turn` — a turn to prepend to `state.turns` before reversing (default `nil`)
  - `:final_messages` — override for messages (default `state.messages`)
  - `:field_descriptions` — set `step.field_descriptions` (default `nil`, not set)
  - `:journal` — override `step.journal` (default `nil`, not set)
  - `:summaries` — override `step.summaries` (default `state.summaries`)
  - `:child_steps` — override `step.child_steps` (default `state.child_steps`)
  - `:extra_usage` — map merged into usage (e.g. `%{fallback_used: true}`)
  """
  @spec finalize(Step.t(), map(), keyword()) :: Step.t()
  def finalize(step, state, opts) do
    duration_ms = Keyword.fetch!(opts, :duration_ms)
    memory_bytes = Keyword.get(opts, :memory_bytes, 0)
    turn_offset = Keyword.get(opts, :turn_offset, 0)
    is_error = Keyword.get(opts, :is_error, false)
    final_turn = Keyword.get(opts, :final_turn)
    final_messages = Keyword.get(opts, :final_messages, state.messages)
    extra_usage = Keyword.get(opts, :extra_usage)

    # Build turns list: optionally prepend final_turn, then reverse
    turns =
      if final_turn do
        [final_turn | state.turns]
      else
        state.turns
      end

    usage = Metrics.build_final_usage(state, duration_ms, memory_bytes, turn_offset)
    usage = if extra_usage, do: Map.merge(usage, extra_usage), else: usage

    base = %{
      step
      | usage: usage,
        turns: Metrics.apply_trace_filter(Enum.reverse(turns), state.trace_mode, is_error),
        messages: build_collected_messages(state, final_messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt,
        tools: state.normalized_tools,
        name: state.agent_name
    }

    base
    |> maybe_set(:summaries, opts, state.summaries)
    |> maybe_set(:child_steps, opts, state.child_steps)
    |> maybe_set(:field_descriptions, opts)
    |> maybe_set(:journal, opts)
  end

  # Set field from opts if provided, otherwise use default
  defp maybe_set(step, field, opts, default) do
    Map.put(step, field, Keyword.get(opts, field, default))
  end

  # Set field from opts only if present (don't set if not in opts)
  defp maybe_set(step, field, opts) do
    if Keyword.has_key?(opts, field) do
      Map.put(step, field, Keyword.fetch!(opts, field))
    else
      step
    end
  end

  # Build collected messages with system prompt prepended, or nil if not collecting
  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    case state.collected_system_prompt do
      nil -> messages
      system_prompt -> [%{role: :system, content: system_prompt} | messages]
    end
  end
end
