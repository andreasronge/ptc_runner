defmodule PtcRunner.SubAgent.Loop.Metrics do
  @moduledoc """
  Telemetry, tracing, and usage metrics for SubAgent execution.

  This module handles:
  - Token accumulation across LLM calls
  - Final usage statistics (duration, memory, turns, tokens)
  - Trace entry construction with optional debug info
  - Trace filtering based on execution result
  - Debug logging for turn execution
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{LLMResolver, Telemetry}

  @doc """
  Accumulate tokens from an LLM call into state.

  ## Parameters

  - `state` - Current loop state
  - `tokens` - Token counts map with `:input` and `:output` keys, or nil

  ## Returns

  Updated state with accumulated token counts.
  """
  @spec accumulate_tokens(map(), map() | nil) :: map()
  def accumulate_tokens(state, nil),
    do: %{state | turn_tokens: nil, llm_requests: state.llm_requests + 1}

  def accumulate_tokens(state, tokens) when is_map(tokens) do
    input = Map.get(tokens, :input, 0)
    output = Map.get(tokens, :output, 0)

    %{
      state
      | total_input_tokens: state.total_input_tokens + input,
        total_output_tokens: state.total_output_tokens + output,
        llm_requests: state.llm_requests + 1,
        turn_tokens: tokens
    }
  end

  @doc """
  Build final usage map with token counts from accumulated state.

  ## Parameters

  - `state` - Current loop state with accumulated metrics
  - `duration_ms` - Total execution duration in milliseconds
  - `memory_bytes` - Memory used in bytes
  - `turn_offset` - Offset for turn count (0 for completed turns, -1 for pre-turn failures)

  ## Returns

  Map with usage statistics.
  """
  @spec build_final_usage(map(), non_neg_integer(), non_neg_integer(), integer()) :: map()
  def build_final_usage(state, duration_ms, memory_bytes, turn_offset \\ 0) do
    base = %{
      duration_ms: duration_ms,
      memory_bytes: memory_bytes,
      turns: state.turn + turn_offset
    }

    # Add token counts if any LLM calls were made with token reporting
    if state.total_input_tokens > 0 or state.total_output_tokens > 0 do
      Map.merge(base, %{
        input_tokens: state.total_input_tokens,
        output_tokens: state.total_output_tokens,
        total_tokens: state.total_input_tokens + state.total_output_tokens,
        llm_requests: state.llm_requests
      })
    else
      # Still include llm_requests even without token counts
      if state.llm_requests > 0 do
        Map.put(base, :llm_requests, state.llm_requests)
      else
        base
      end
    end
  end

  @doc """
  Emit turn stop event only for final results (not loop continuations).

  Emits `[:sub_agent, :turn, :stop]` telemetry event with duration and optional token counts.
  """
  @spec emit_turn_stop_if_final(term(), SubAgent.t(), map(), integer()) :: :ok
  def emit_turn_stop_if_final({status, _step} = _result, agent, state, turn_start)
      when status in [:ok, :error] do
    turn_duration = System.monotonic_time() - turn_start
    measurements = build_turn_measurements(turn_duration, state.turn_tokens)

    Telemetry.emit([:turn, :stop], measurements, %{
      agent: agent,
      turn: state.turn,
      program: nil
    })

    :ok
  end

  @doc """
  Build measurements for turn stop event with optional tokens.
  """
  @spec build_turn_measurements(integer(), map() | nil) :: map()
  def build_turn_measurements(duration, nil), do: %{duration: duration}

  def build_turn_measurements(duration, tokens) when is_map(tokens) do
    %{duration: duration, tokens: LLMResolver.total_tokens(tokens)}
  end

  @doc """
  Build token measurements map for telemetry.
  """
  @spec build_token_measurements(map() | nil) :: map()
  def build_token_measurements(nil), do: %{}

  def build_token_measurements(tokens) when is_map(tokens) do
    %{tokens: LLMResolver.total_tokens(tokens)}
  end

  @doc """
  Build a trace entry with optional debug information.

  ## Parameters

  - `state` - Current loop state
  - `program` - The PTC-Lisp program that was executed
  - `result` - Execution result
  - `tool_calls` - List of tool calls made during execution

  ## Returns

  Trace entry map with turn number, program, result, and tool_calls.
  In debug mode, also includes context_snapshot, memory_snapshot, and full_prompt.
  """
  @spec build_trace_entry(map(), String.t(), term(), list()) :: map()
  def build_trace_entry(state, program, result, tool_calls) do
    base = %{
      turn: state.turn,
      program: program,
      result: result,
      tool_calls: tool_calls
    }

    if state.debug do
      Map.merge(base, %{
        context_snapshot: state.context,
        memory_snapshot: state.memory,
        full_prompt: List.last(state.messages)
      })
    else
      base
    end
  end

  @doc """
  Apply trace filtering based on trace_mode and execution result.

  ## Filter Modes

  - `true` - Always include trace
  - `false` - Never include trace (returns nil)
  - `:on_error` - Include trace only when is_error is true
  """
  @spec apply_trace_filter(list() | nil, boolean() | :on_error, boolean()) :: list() | nil
  def apply_trace_filter(_trace, false = _trace_mode, _is_error), do: nil
  def apply_trace_filter(trace, true = _trace_mode, _is_error), do: trace
  def apply_trace_filter(trace, :on_error = _trace_mode, true = _is_error), do: trace
  def apply_trace_filter(_trace, :on_error = _trace_mode, false = _is_error), do: nil

  @doc """
  Log turn execution if debug mode is enabled.
  """
  @spec maybe_log_turn(map(), String.t(), term(), boolean()) :: :ok
  def maybe_log_turn(_state, _response, _result, false = _debug), do: :ok

  def maybe_log_turn(state, response, result, true = _debug) do
    IO.puts("[Turn #{state.turn}] LLM response:")
    IO.puts(response)
    IO.puts("\n[Turn #{state.turn}] Execution result:")
    IO.puts(Format.to_string(result, pretty: true, limit: :infinity))
    IO.puts("\n")
    :ok
  end
end
