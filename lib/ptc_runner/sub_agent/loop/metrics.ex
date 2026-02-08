defmodule PtcRunner.SubAgent.Loop.Metrics do
  @moduledoc """
  Telemetry, tracing, and usage metrics for SubAgent execution.

  This module handles:
  - Token accumulation across LLM calls
  - Final usage statistics (duration, memory, turns, tokens)
  - Trace entry construction with optional debug info
  - Turn struct construction for execution history
  - Trace filtering based on execution result
  """

  alias PtcRunner.{Step, SubAgent}
  alias PtcRunner.SubAgent.{LLMResolver, Telemetry}
  alias PtcRunner.Turn

  @doc """
  Estimate token count for a text string.

  Uses a simple approximation of ~4 characters per token, which is
  reasonably accurate for most LLM tokenizers (within ~10-20%).

  ## Examples

      iex> PtcRunner.SubAgent.Loop.Metrics.estimate_tokens("Hello world")
      2

      iex> PtcRunner.SubAgent.Loop.Metrics.estimate_tokens("")
      0

      iex> PtcRunner.SubAgent.Loop.Metrics.estimate_tokens(nil)
      0
  """
  @spec estimate_tokens(String.t() | nil) :: non_neg_integer()
  def estimate_tokens(nil), do: 0
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) when is_binary(text) do
    max(1, div(String.length(text), 4))
  end

  @doc """
  Accumulate tokens from an LLM call into state.

  ## Parameters

  - `state` - Current loop state
  - `tokens` - Token counts map with `:input`, `:output`, `:cache_creation`, `:cache_read` keys, or nil

  ## Returns

  Updated state with accumulated token counts.
  """
  @spec accumulate_tokens(map(), map() | nil) :: map()
  def accumulate_tokens(state, nil),
    do: %{state | turn_tokens: nil, llm_requests: state.llm_requests + 1}

  def accumulate_tokens(state, tokens) when is_map(tokens) do
    input = Map.get(tokens, :input, 0)
    output = Map.get(tokens, :output, 0)
    cache_creation = Map.get(tokens, :cache_creation, 0)
    cache_read = Map.get(tokens, :cache_read, 0)

    %{
      state
      | total_input_tokens: state.total_input_tokens + input,
        total_output_tokens: state.total_output_tokens + output,
        total_cache_creation_tokens:
          Map.get(state, :total_cache_creation_tokens, 0) + cache_creation,
        total_cache_read_tokens: Map.get(state, :total_cache_read_tokens, 0) + cache_read,
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

  Map with usage statistics including cache token metrics and compression stats when available.
  """
  @spec build_final_usage(map(), non_neg_integer(), non_neg_integer(), integer()) :: map()
  def build_final_usage(state, duration_ms, memory_bytes, turn_offset \\ 0) do
    base = %{
      duration_ms: duration_ms,
      memory_bytes: memory_bytes,
      turns: state.turn + turn_offset
    }

    # Add compression stats if captured from compression strategy
    compression_stats = Map.get(state, :compression_stats)
    base = if compression_stats, do: Map.put(base, :compression, compression_stats), else: base

    # Add token counts if any LLM calls were made with token reporting
    if state.total_input_tokens > 0 or state.total_output_tokens > 0 do
      cache_creation = Map.get(state, :total_cache_creation_tokens, 0)
      cache_read = Map.get(state, :total_cache_read_tokens, 0)

      token_stats = %{
        input_tokens: state.total_input_tokens,
        output_tokens: state.total_output_tokens,
        total_tokens: state.total_input_tokens + state.total_output_tokens,
        llm_requests: state.llm_requests,
        system_prompt_tokens: Map.get(state, :system_prompt_tokens, 0)
      }

      # Add cache token stats if any caching occurred
      cache_stats =
        if cache_creation > 0 or cache_read > 0 do
          %{
            cache_creation_tokens: cache_creation,
            cache_read_tokens: cache_read
          }
        else
          %{}
        end

      Map.merge(base, Map.merge(token_stats, cache_stats))
    else
      # Still include llm_requests even without token counts
      if state.llm_requests > 0 do
        Map.put(base, :llm_requests, state.llm_requests)
      else
        base
      end
    end
  end

  @max_result_preview_length 200

  @doc """
  Emit turn stop event immediately after a turn completes.

  This is used by the iterative driver_loop to emit telemetry right after each turn,
  rather than batching events when the stack unwinds. Handles nil turn defensively
  for cases where LLM errors occur before a Turn struct is created.

  ## Parameters

  - `turn` - The Turn struct for this turn, or nil if LLM error occurred before turn creation
  - `agent` - The SubAgent struct
  - `state` - Current loop state
  - `turn_start` - Monotonic timestamp when turn started
  - `turn_tokens` - Optional token counts from LLM call (overrides state.turn_tokens if provided)
  """
  @spec emit_turn_stop_immediate(
          Turn.t() | nil,
          SubAgent.t() | map(),
          map(),
          integer(),
          map() | nil
        ) ::
          :ok
  def emit_turn_stop_immediate(turn, agent, state, turn_start, turn_tokens \\ nil) do
    turn_duration = System.monotonic_time() - turn_start
    # Use explicit turn_tokens if provided, otherwise fall back to state.turn_tokens
    tokens = turn_tokens || state.turn_tokens
    measurements = build_turn_measurements(turn_duration, tokens)
    turn_type = Map.get(state, :current_turn_type, :normal)

    # Extract program, result preview, and prints from turn (nil-safe)
    {program, result_preview, prints} =
      case turn do
        nil -> {nil, "nil", []}
        %Turn{} -> {turn.program, build_result_preview(turn.result), turn.prints || []}
      end

    Telemetry.emit([:turn, :stop], measurements, %{
      agent: agent,
      turn: state.turn,
      program: program,
      result_preview: result_preview,
      prints: prints,
      type: turn_type
    })

    :ok
  end

  @doc """
  Build a truncated preview of the result for telemetry metadata.

  Truncates to #{@max_result_preview_length} characters.
  """
  @spec build_result_preview(term()) :: String.t()
  def build_result_preview(nil), do: "nil"

  def build_result_preview(result) do
    preview = inspect(result, limit: 10, printable_limit: @max_result_preview_length)

    if String.length(preview) > @max_result_preview_length do
      String.slice(preview, 0, @max_result_preview_length - 3) <> "..."
    else
      preview
    end
  end

  @doc """
  Build measurements for turn stop event with optional tokens.
  """
  @spec build_turn_measurements(integer(), map() | nil) :: map()
  def build_turn_measurements(duration, nil), do: %{duration: duration}

  def build_turn_measurements(duration, tokens) when is_map(tokens) do
    %{duration: duration} |> Map.merge(token_breakdown(tokens))
  end

  @doc """
  Build token measurements map for telemetry.
  """
  @spec build_token_measurements(map() | nil) :: map()
  def build_token_measurements(nil), do: %{}

  def build_token_measurements(tokens) when is_map(tokens) do
    token_breakdown(tokens)
  end

  defp token_breakdown(tokens) do
    base = %{tokens: LLMResolver.total_tokens(tokens)}

    tokens
    |> Enum.reduce(base, fn
      {:input, v}, acc when is_integer(v) and v > 0 ->
        Map.put(acc, :input_tokens, v)

      {:output, v}, acc when is_integer(v) and v > 0 ->
        Map.put(acc, :output_tokens, v)

      {:cache_creation, v}, acc when is_integer(v) and v > 0 ->
        Map.put(acc, :cache_creation_tokens, v)

      {:cache_read, v}, acc when is_integer(v) and v > 0 ->
        Map.put(acc, :cache_read_tokens, v)

      _, acc ->
        acc
    end)
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
  Build a Turn struct for the current execution cycle.

  Creates either a success or failure Turn based on the `success?` option.

  ## Parameters

  - `state` - Current loop state (used for turn number and messages)
  - `raw_response` - Full LLM response text
  - `program` - PTC-Lisp program that was executed (or nil if parsing failed)
  - `result` - Execution result or error
  - `opts` - Keyword options:
    - `success?` - Whether this turn succeeded (default: true)
    - `prints` - Captured println output (default: [])
    - `tool_calls` - Tool invocations made during this turn (default: [])
    - `memory` - Memory state after this turn (default: state.memory)
    - `type` - Turn type: `:normal`, `:must_return`, or `:retry` (default: `:normal`)

  ## Returns

  A `%Turn{}` struct.
  """
  @spec build_turn(map(), String.t(), String.t() | nil, term(), keyword()) :: Turn.t()
  def build_turn(state, raw_response, program, result, opts \\ []) do
    success? = Keyword.get(opts, :success?, true)
    prints = Keyword.get(opts, :prints, [])
    tool_calls = Keyword.get(opts, :tool_calls, [])
    memory = Keyword.get(opts, :memory, state.memory)
    turn_type = Keyword.get(opts, :type, :normal)
    # Get messages from state (set by loop before LLM call)
    messages = Map.get(state, :current_messages)

    # Convert tool_calls to Turn's simplified format
    simplified_tool_calls =
      Enum.map(tool_calls, fn tc ->
        %{
          name: tc.name,
          args: tc.args,
          result: tc.result
        }
      end)

    system_prompt = Map.get(state, :current_system_prompt)

    params = %{
      prints: prints,
      tool_calls: simplified_tool_calls,
      memory: memory,
      messages: messages,
      system_prompt: system_prompt,
      type: turn_type
    }

    if success? do
      Turn.success(state.turn, raw_response, program, result, params)
    else
      Turn.failure(state.turn, raw_response, program, result, params)
    end
  end

  @doc """
  Extract program from the last turn in a result.

  The result is `{:ok, step}` or `{:error, step}` for final results.
  For continuation results (loop), this returns `nil`.

  Note: `step.turns` is in chronological order (first turn first, last turn last).

  ## Examples

      iex> step = %PtcRunner.Step{turns: [%{program: "code"}]}
      iex> PtcRunner.SubAgent.Loop.Metrics.extract_program_from_result({:ok, step})
      "code"

      iex> PtcRunner.SubAgent.Loop.Metrics.extract_program_from_result({:ok, %PtcRunner.Step{turns: []}})
      nil

      iex> PtcRunner.SubAgent.Loop.Metrics.extract_program_from_result({:error, :invalid})
      nil
  """
  @spec extract_program_from_result(tuple()) :: String.t() | nil
  def extract_program_from_result({_status, step}) when is_struct(step, Step) do
    case step.turns do
      turns when is_list(turns) and turns != [] -> List.last(turns).program
      _ -> nil
    end
  end

  def extract_program_from_result(_), do: nil
end
