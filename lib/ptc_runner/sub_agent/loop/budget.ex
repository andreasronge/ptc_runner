defmodule PtcRunner.SubAgent.Loop.Budget do
  @moduledoc """
  Budget checking, callback handling, and fallback recovery for SubAgent execution.

  Handles:
  - Budget callback/token_limit checking
  - Budget exhaustion with fallback attempts
  - Last-expression fallback recovery
  - Budget introspection maps for Lisp and Elixir callbacks
  """

  alias PtcRunner.Step
  alias PtcRunner.SubAgent.{Definition, KeyNormalizer}
  alias PtcRunner.SubAgent.Loop.{ReturnValidation, StepAssembler}

  @doc """
  Check if budget is exceeded via callback or token_limit.
  Returns `:continue` or `:stop`.
  """
  @spec check_callback(map()) :: :continue | :stop
  def check_callback(state) do
    usage = build_usage_callback_map(state)

    cond do
      is_function(state.budget_callback) ->
        state.budget_callback.(usage)

      state.token_limit && usage.total_tokens > state.token_limit ->
        :stop

      true ->
        :continue
    end
  end

  @doc """
  Handle budget exceeded — try fallback or return error.
  """
  @spec handle_exceeded(Definition.t(), map()) :: {:ok | :error, Step.t()}
  def handle_exceeded(agent, state) do
    case state.on_budget_exceeded do
      :return_partial ->
        case try_last_expression_fallback(agent, state) do
          {:ok, step} ->
            {:ok, step}

          :no_fallback ->
            build_termination_error(
              :budget_callback_exceeded,
              "Budget exceeded (token_limit or callback returned :stop)",
              state
            )
        end

      _fail ->
        build_termination_error(
          :budget_callback_exceeded,
          "Budget exceeded (token_limit or callback returned :stop)",
          state
        )
    end
  end

  @doc """
  Handle unified budget exhaustion (work + retry turns consumed) with fallback attempt.
  """
  @spec handle_exhausted_termination(Definition.t(), map()) :: {:ok | :error, Step.t()}
  def handle_exhausted_termination(agent, state) do
    case try_last_expression_fallback(agent, state) do
      {:ok, step} ->
        {:ok, step}

      :no_fallback ->
        if agent.retry_turns == 0 do
          build_termination_error(
            :max_turns_exceeded,
            "Exceeded max_turns limit of #{agent.max_turns}",
            state
          )
        else
          build_termination_error(
            :budget_exhausted,
            "Budget exhausted (work and retry turns)",
            state
          )
        end
    end
  end

  @doc """
  Build budget map for `(budget/remaining)` Lisp introspection.
  Uses hyphenated keys (idiomatic PTC-Lisp/Clojure).
  """
  @spec build_introspection_map(Definition.t(), map()) :: map()
  def build_introspection_map(agent, state) do
    %{
      turns: state.remaining_turns,
      "work-turns": state.work_turns_remaining,
      "retry-turns": state.retry_turns_remaining,
      depth: %{current: state.nesting_depth + 1, max: agent.max_depth},
      tokens: %{
        input: state.total_input_tokens,
        output: state.total_output_tokens,
        total: state.total_input_tokens + state.total_output_tokens,
        "cache-creation": state.total_cache_creation_tokens,
        "cache-read": state.total_cache_read_tokens
      },
      "llm-requests": state.llm_requests
    }
  end

  # ============================================================
  # Private
  # ============================================================

  defp try_last_expression_fallback(agent, state) do
    case find_last_successful_result(state.turns) do
      {:ok, result, turn} ->
        normalized = KeyNormalizer.normalize_keys(result)

        case ReturnValidation.validate(agent, normalized) do
          :ok ->
            build_success_from_fallback(normalized, turn, state, agent)

          {:error, _} ->
            :no_fallback
        end

      :none ->
        :no_fallback
    end
  end

  defp find_last_successful_result(turns) do
    case Enum.find(turns, fn turn -> turn.success? and turn.result != nil end) do
      nil -> :none
      turn -> {:ok, turn.result, turn}
    end
  end

  defp build_success_from_fallback(normalized_value, turn, state, agent) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.ok(normalized_value, turn.memory)

    final_step =
      StepAssembler.finalize(step, state,
        duration_ms: duration_ms,
        field_descriptions: agent.field_descriptions,
        extra_usage: %{fallback_used: true}
      )

    {:ok, final_step}
  end

  @doc false
  @spec build_termination_error(atom(), String.t(), map()) :: {:error, Step.t()}
  def build_termination_error(reason, message, state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.error(reason, message, state.memory)

    final_step =
      StepAssembler.finalize(step, state,
        duration_ms: duration_ms,
        turn_offset: -1,
        is_error: true,
        journal: state.journal
      )

    {:error, final_step}
  end

  defp build_usage_callback_map(state) do
    %{
      total_tokens: state.total_input_tokens + state.total_output_tokens,
      input_tokens: state.total_input_tokens,
      output_tokens: state.total_output_tokens,
      llm_requests: state.llm_requests
    }
  end
end
