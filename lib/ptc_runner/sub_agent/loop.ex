defmodule PtcRunner.SubAgent.Loop do
  @moduledoc """
  Core agentic loop that manages LLM↔tool cycles.

  The loop repeatedly calls the LLM, parses PTC-Lisp from the response,
  executes it, and continues until `return`/`fail` is called or `max_turns` is exceeded.

  ## Flow

  1. Build LLM input with system prompt, messages, and tool names
  2. Call LLM to get response (resolving atoms via `llm_registry` if needed)
  3. Parse PTC-Lisp code from response (code blocks or raw s-expressions)
  4. Execute code via `Lisp.run/2`
  5. Check for return/fail or continue to next turn
  6. Build trace entry and update message history
  7. Merge execution results into context for next turn

  ## Termination Conditions

  The loop terminates when any of these occur:

  | Condition | Result | Reason |
  |-----------|--------|--------|
  | `(return value)` called | `{:ok, step}` | Normal completion |
  | `(fail error)` called | `{:error, step}` | Explicit failure |
  | `max_turns` exceeded | `{:error, step}` | `:max_turns_exceeded` |
  | `max_depth` exceeded | `{:error, step}` | `:max_depth_exceeded` |
  | `turn_budget` exhausted | `{:error, step}` | `:turn_budget_exhausted` |
  | `mission_timeout` exceeded | `{:error, step}` | `:mission_timeout` |
  | LLM error after retries | `{:error, step}` | `:llm_error` |

  ## Memory Handling

  Memory persists across turns within a single `run/2` call. After each successful
  Lisp execution:

  1. `Lisp.run/2` applies the memory contract (see `PtcRunner.Lisp` for details)
  2. `step.memory` contains the updated memory state
  3. Loop updates `state.memory` for the next turn
  4. Memory is merged into context via `state.context`

  The memory contract determines how return values affect memory:
  - Non-map returns: no memory update
  - Map without `:return`: merged into memory
  - Map with `:return`: rest merged, `:return` value returned

  See `PtcRunner.Lisp.run/2` for the authoritative memory contract documentation.

  ## LLM Inheritance

  Child SubAgents inherit the `llm_registry` from their parent, enabling atom-based
  LLM references (like `:haiku` or `:sonnet`) to work throughout the agent hierarchy.
  The registry only needs to be provided once at the top-level `SubAgent.run/2` call.

  Resolution order for LLM selection:
  1. `agent.llm` - Set in SubAgent struct
  2. `as_tool(..., llm:)` - Bound at tool creation
  3. Parent's LLM - Inherited from calling agent
  4. Required at top level

  This is an internal module called by `SubAgent.run/2`.
  """

  alias PtcRunner.{Lisp, Step}
  alias PtcRunner.SubAgent

  alias PtcRunner.SubAgent.Loop.{
    JsonMode,
    LLMRetry,
    Metrics,
    ResponseHandler,
    ReturnValidation,
    ToolNormalizer,
    TurnFeedback
  }

  alias PtcRunner.SubAgent.{Compression, KeyNormalizer, SystemPrompt, Telemetry}

  @doc """
  Execute a SubAgent in loop mode (multi-turn with tools).

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `llm` - Required. LLM callback function
    - `context` - Initial context map (default: %{})
    - `cache` - Enable prompt caching (default: false). When true, the LLM callback receives
      `cache: true` in its input map. The callback should pass this to the provider to enable
      caching of system prompts for cost savings on multi-turn agents.
    - `debug` - Deprecated, no longer needed. Turn structs always capture `raw_response`.
      Use `SubAgent.Debug.print_trace(step, raw: true)` to view full LLM output.
    - `trace` - Trace filtering: true (always), false (never), :on_error (only on failure) (default: true)
    - `collect_messages` - Capture full conversation history in Step.messages (default: false).
      When enabled, messages are in OpenAI format: `[%{role: :system | :user | :assistant, content: String.t()}]`
    - `llm_retry` - Optional retry configuration map with:
      - `max_attempts` - Maximum number of retry attempts (default: 1, meaning no retries unless explicitly configured)
      - `backoff` - Backoff strategy: :exponential, :linear, or :constant (default: :exponential)
      - `base_delay` - Base delay in milliseconds (default: 1000)
      - `retryable_errors` - List of error types to retry (default: [:rate_limit, :timeout, :server_error])

  ## Returns

  - `{:ok, Step.t()}` on success (when `return` is called)
  - `{:error, Step.t()}` on failure (when `fail` is called or max_turns exceeded)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Add {{x}} and {{y}}", tools: %{}, max_turns: 2)
      iex> llm = fn %{messages: _} -> {:ok, "```clojure\\n(return {:result (+ data/x data/y)})\\n```"} end
      iex> {:ok, step} = PtcRunner.SubAgent.Loop.run(agent, llm: llm, context: %{x: 5, y: 3})
      iex> step.return
      %{"result" => 8}
  """
  @spec run(SubAgent.t(), keyword()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%SubAgent{} = agent, opts) do
    llm = Keyword.fetch!(opts, :llm)
    context = Keyword.get(opts, :context, %{})
    llm_registry = Keyword.get(opts, :llm_registry, %{})
    cache = Keyword.get(opts, :cache, false)
    debug = Keyword.get(opts, :debug, false)
    trace_mode = Keyword.get(opts, :trace, true)
    llm_retry = Keyword.get(opts, :llm_retry)
    collect_messages = Keyword.get(opts, :collect_messages, false)
    # Field descriptions received from upstream agent in a chain
    received_field_descriptions = Keyword.get(opts, :_received_field_descriptions)

    # Extract runtime context for nesting depth and turn budget
    nesting_depth = Keyword.get(opts, :_nesting_depth, 0)
    remaining_turns = Keyword.get(opts, :_remaining_turns, agent.turn_budget)
    mission_deadline = Keyword.get(opts, :_mission_deadline)

    # Check nesting depth limit before starting
    if nesting_depth >= agent.max_depth do
      step =
        Step.error(
          :max_depth_exceeded,
          "Nesting depth limit exceeded: #{nesting_depth} >= #{agent.max_depth}",
          %{}
        )

      {:error, %{step | usage: %{duration_ms: 0, memory_bytes: 0, turns: 0}}}
    else
      # Check turn budget before starting
      if remaining_turns <= 0 do
        step =
          Step.error(
            :turn_budget_exhausted,
            "Turn budget exhausted: #{agent.turn_budget - remaining_turns} turns used",
            %{}
          )

        {:error, %{step | usage: %{duration_ms: 0, memory_bytes: 0, turns: 0}}}
      else
        run_opts = %{
          llm: llm,
          context: context,
          nesting_depth: nesting_depth,
          remaining_turns: remaining_turns,
          mission_deadline: mission_deadline,
          llm_registry: llm_registry,
          cache: cache,
          debug: debug,
          trace_mode: trace_mode,
          llm_retry: llm_retry,
          collect_messages: collect_messages,
          received_field_descriptions: received_field_descriptions
        }

        run_with_telemetry(agent, run_opts)
      end
    end
  end

  # Wrap execution with telemetry span
  defp run_with_telemetry(agent, run_opts) do
    start_meta = %{agent: agent, context: run_opts.context}

    Telemetry.span([:run], start_meta, fn ->
      result = do_run(agent, run_opts)

      stop_meta =
        case result do
          {:ok, step} -> %{agent: agent, step: step, status: :ok}
          {:error, step} -> %{agent: agent, step: step, status: :error}
        end

      {result, stop_meta}
    end)
  end

  # Helper to continue run after checks
  defp do_run(agent, run_opts) do
    # Calculate mission deadline if mission_timeout is set and not already inherited
    calculated_deadline =
      run_opts.mission_deadline || calculate_mission_deadline(agent.mission_timeout)

    # Expand template in mission
    # JSON mode: embed actual values (no Data section)
    # PTC-Lisp mode: use annotations (data is in Data Inventory section)
    expanded_prompt = expand_template(agent.prompt, run_opts.context, agent.output)

    # Normalize tools for Step.tools (used by Debug.print_trace compressed view)
    normalized_tools = normalize_tools_for_step(agent.tools)

    # Build first user message with dynamic context prepended
    # This includes data inventory, tool schemas, expected output, plus the mission
    first_user_message = build_first_user_message(agent, run_opts, expanded_prompt)

    initial_state = %{
      llm: run_opts.llm,
      llm_registry: run_opts.llm_registry,
      turn: 1,
      messages: [%{role: :user, content: first_user_message}],
      context: run_opts.context,
      turns: [],
      start_time: System.monotonic_time(:millisecond),
      memory: %{},
      last_fail: nil,
      nesting_depth: run_opts.nesting_depth,
      remaining_turns: run_opts.remaining_turns,
      mission_deadline: calculated_deadline,
      cache: run_opts.cache,
      debug: run_opts.debug,
      trace_mode: run_opts.trace_mode,
      llm_retry: run_opts.llm_retry,
      collect_messages: run_opts.collect_messages,
      # Token accumulation across LLM calls
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cache_creation_tokens: 0,
      total_cache_read_tokens: 0,
      llm_requests: 0,
      # Estimated system prompt tokens (set on first turn)
      system_prompt_tokens: 0,
      # Tokens from current turn's LLM call (for telemetry)
      turn_tokens: nil,
      # Turn history for *1/*2/*3 access (last 3 results, most recent last)
      turn_history: [],
      # Field descriptions received from upstream agent in a chain
      received_field_descriptions: run_opts.received_field_descriptions,
      # System prompt for message collection (set on first turn)
      collected_system_prompt: nil,
      # Expanded prompt for Step.prompt (used by Debug.print_trace)
      expanded_prompt: expanded_prompt,
      # Original prompt template for Step.original_prompt (used by Debug for annotated display)
      original_prompt: agent.prompt,
      # Normalized tools for Step.tools (used by Debug.print_trace compressed view)
      normalized_tools: normalized_tools,
      # Unified budget model for return_retries
      work_turns_remaining: agent.max_turns,
      retry_turns_remaining: agent.return_retries,
      # Last error message for retry feedback (collapsed context)
      last_return_error: nil
    }

    # Route to appropriate execution mode based on agent.output
    case agent.output do
      :json -> JsonMode.run(agent, run_opts.llm, initial_state)
      :ptc_lisp -> loop(agent, run_opts.llm, initial_state)
    end
  end

  # Check unified budget (work + retry turns)
  # Budget exhausted when both work and retry turns are consumed
  # Use appropriate error reason based on whether retry budget was configured
  # First attempts fallback to last successful expression before returning error
  defp loop(agent, _llm, state)
       when state.work_turns_remaining <= 0 and state.retry_turns_remaining <= 0 do
    case try_last_expression_fallback(agent, state) do
      {:ok, step} ->
        {:ok, step}

      :no_fallback ->
        if agent.return_retries == 0 do
          # Legacy behavior: no retry budget, so this is max_turns_exceeded
          build_termination_error(
            :max_turns_exceeded,
            "Exceeded max_turns limit of #{agent.max_turns}",
            state
          )
        else
          # Unified budget: both work and retry turns consumed
          build_termination_error(
            :budget_exhausted,
            "Budget exhausted (work and retry turns)",
            state
          )
        end
    end
  end

  # Check global turn budget before each turn (guard clause)
  defp loop(_agent, _llm, state) when state.remaining_turns <= 0 do
    build_termination_error(:turn_budget_exhausted, "Turn budget exhausted", state)
  end

  # Main loop iteration
  defp loop(agent, llm, state) do
    # Check mission timeout before each turn
    if state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) do
      build_termination_error(:mission_timeout, "Mission timeout exceeded", state)
    else
      # Compute turn phase based on unified budget model
      must_return_mode = state.work_turns_remaining <= 1
      in_retry_phase = state.work_turns_remaining <= 0

      # Determine turn type for this iteration
      turn_type =
        cond do
          in_retry_phase -> :retry
          must_return_mode -> :must_return
          true -> :normal
        end

      # Store turn type in state for downstream use
      state = Map.put(state, :current_turn_type, turn_type)

      # Build telemetry metadata
      telemetry_metadata = %{
        agent: agent,
        turn: state.turn,
        type: turn_type,
        tools_count: if(must_return_mode, do: 0, else: map_size(agent.tools))
      }

      # Add retry-specific metadata when in retry phase
      telemetry_metadata =
        if in_retry_phase do
          attempt_num = agent.return_retries - state.retry_turns_remaining + 1

          Map.merge(telemetry_metadata, %{
            attempt: attempt_num,
            remaining: state.retry_turns_remaining
          })
        else
          telemetry_metadata
        end

      # Emit turn start event with turn type
      Telemetry.emit([:turn, :start], %{}, telemetry_metadata)

      turn_start = System.monotonic_time()

      # Build LLM input with resolution context for language_spec callbacks
      resolution_context = %{
        turn: state.turn,
        model: state.llm,
        memory: state.memory,
        messages: state.messages
      }

      # Build system prompt
      system_prompt =
        build_system_prompt(
          agent,
          state.context,
          resolution_context,
          state.received_field_descriptions
        )

      # Build messages - use compression if enabled and turn > 1
      # Returns {messages, compression_stats | nil}
      {messages, compression_stats} = build_llm_messages(agent, state, system_prompt)

      # Store compression stats in state (will be used by build_final_usage)
      state =
        if compression_stats,
          do: Map.put(state, :compression_stats, compression_stats),
          else: state

      # Strip tools in must-return mode (structural enforcement)
      tool_names = if must_return_mode, do: [], else: Map.keys(agent.tools)

      llm_input = %{
        system: system_prompt,
        messages: messages,
        turn: state.turn,
        tool_names: tool_names,
        cache: state.cache
      }

      # Call LLM with telemetry and retry logic
      case call_llm_with_telemetry(llm, llm_input, state, agent) do
        {:ok, %{content: content, tokens: tokens}} ->
          # Accumulate tokens and store system prompt + messages for debugging
          state_with_metadata =
            state
            |> Metrics.accumulate_tokens(tokens)
            |> Map.put(:current_system_prompt, llm_input.system)
            |> Map.put(:current_messages, messages)
            |> maybe_add_system_prompt_tokens(llm_input.system)

          result = handle_llm_response(content, agent, llm, state_with_metadata)

          # Emit turn stop event (only for completed turns, not continuation)
          # Extract program from the last turn in the result
          program = Metrics.extract_program_from_result(result)

          Metrics.emit_turn_stop_if_final(result, agent, state_with_metadata, turn_start,
            program: program
          )

          result

        {:error, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - state.start_time

          step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", state.memory)

          step_with_metrics = %{
            step
            | usage: Metrics.build_final_usage(state, duration_ms, 0),
              turns:
                Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
              messages: build_collected_messages(state, state.messages),
              prompt: state.expanded_prompt,
              original_prompt: state.original_prompt,
              tools: state.normalized_tools
          }

          # Emit turn stop on error (LLM call failed, so no program or result)
          turn_duration = System.monotonic_time() - turn_start
          turn_type = Map.get(state, :current_turn_type, :normal)

          Telemetry.emit([:turn, :stop], %{duration: turn_duration}, %{
            agent: agent,
            turn: state.turn,
            program: nil,
            result_preview: nil,
            type: turn_type
          })

          {:error, step_with_metrics}
      end
    end
  end

  # Estimate system prompt tokens on first turn only, and capture system prompt if collecting messages
  defp maybe_add_system_prompt_tokens(%{turn: 1} = state, system_prompt) do
    state
    |> Map.put(:system_prompt_tokens, Metrics.estimate_tokens(system_prompt))
    |> maybe_capture_system_prompt(system_prompt)
  end

  defp maybe_add_system_prompt_tokens(state, _system_prompt), do: state

  # Capture system prompt for message collection if enabled
  defp maybe_capture_system_prompt(%{collect_messages: true} = state, system_prompt) do
    Map.put(state, :collected_system_prompt, system_prompt)
  end

  defp maybe_capture_system_prompt(state, _system_prompt), do: state

  # Call LLM with telemetry wrapper
  defp call_llm_with_telemetry(llm, input, state, agent) do
    start_meta = %{agent: agent, turn: state.turn, messages: input.messages}

    Telemetry.span([:llm], start_meta, fn ->
      result = LLMRetry.call_with_retry(llm, input, state.llm_registry, state.llm_retry)

      # Build stop measurements and metadata separately
      # telemetry.span expects {result, extra_measurements, stop_metadata}
      {extra_measurements, stop_meta} =
        case result do
          {:ok, %{content: content, tokens: tokens}} ->
            measurements = Metrics.build_token_measurements(tokens)
            meta = %{agent: agent, turn: state.turn, response: content}
            {measurements, meta}

          {:error, _} ->
            meta = %{agent: agent, turn: state.turn, response: nil}
            {%{}, meta}
        end

      {result, extra_measurements, stop_meta}
    end)
  end

  # Handle LLM response - parse and execute code
  defp handle_llm_response(response, agent, llm, state) do
    case ResponseHandler.parse(response) do
      {:ok, code} ->
        execute_code(code, response, agent, llm, state)

      {:error, :no_code_in_response} ->
        # Log the response in debug mode so user can see what LLM returned
        if state.debug and System.get_env("PTC_DEBUG_PARSER") do
          IO.puts(
            "[Turn #{state.turn}] No code found in LLM response (#{byte_size(response)} bytes):"
          )

          IO.puts("---")
          IO.puts(response)
          IO.puts("---")
        end

        # Handle error using unified budget model
        handle_error_with_budget(
          response,
          "Error: No valid PTC-Lisp code found in response. Please provide code in a ```clojure or ```lisp code block, or as a raw s-expression starting with '('.",
          nil,
          state,
          agent,
          llm
        )
    end
  end

  # Handle error with unified budget model
  # Decrements work_turns_remaining if not in retry phase, otherwise retry_turns_remaining
  defp handle_error_with_budget(response, error_message, turn_or_nil, state, agent, llm) do
    in_retry_phase = state.work_turns_remaining <= 0

    # Build Turn struct if not provided
    turn =
      turn_or_nil ||
        Metrics.build_turn(state, response, nil, %{reason: :parse_error, message: error_message},
          success?: false,
          type: state.current_turn_type
        )

    # Determine which budget counter to decrement
    {new_work_turns, new_retry_turns} =
      if in_retry_phase do
        {state.work_turns_remaining, state.retry_turns_remaining - 1}
      else
        {state.work_turns_remaining - 1, state.retry_turns_remaining}
      end

    # Build feedback with appropriate turn info
    feedback = TurnFeedback.build_error_feedback(error_message, agent, state)

    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: feedback}
            ],
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        work_turns_remaining: new_work_turns,
        retry_turns_remaining: new_retry_turns,
        last_return_error: error_message
    }

    loop(agent, llm, new_state)
  end

  # Execute parsed code
  defp execute_code(code, response, agent, llm, state) do
    # Add last_fail to context if present
    exec_context =
      if state.last_fail do
        Map.put(state.context, :fail, state.last_fail)
      else
        state.context
      end

    # Normalize SubAgentTool instances to functions with telemetry
    normalized_tools = ToolNormalizer.normalize(agent.tools, state, agent)

    execute_code_with_tools(code, response, agent, llm, state, exec_context, normalized_tools)
  end

  # Execute code with normalized tools
  defp execute_code_with_tools(code, response, agent, llm, state, exec_context, all_tools) do
    lisp_opts = [
      context: exec_context,
      memory: state.memory,
      tools: all_tools,
      turn_history: state.turn_history,
      float_precision: agent.float_precision,
      max_print_length: Keyword.get(agent.format_options, :max_print_length),
      timeout: agent.timeout
    ]

    case Lisp.run(code, lisp_opts) do
      {:ok, lisp_step} ->
        handle_successful_execution(code, response, lisp_step, state, agent, llm)

      {:error, lisp_step} ->
        # Build error message for LLM
        error_message = ResponseHandler.format_error_for_llm(lisp_step.fail)

        # Build Turn struct (failure turn) with turn type
        turn =
          Metrics.build_turn(state, response, code, lisp_step.fail,
            success?: false,
            prints: lisp_step.prints,
            tool_calls: lisp_step.tool_calls,
            memory: lisp_step.memory,
            type: state.current_turn_type
          )

        # Use unified budget model for error handling
        in_retry_phase = state.work_turns_remaining <= 0

        {new_work_turns, new_retry_turns} =
          if in_retry_phase do
            {state.work_turns_remaining, state.retry_turns_remaining - 1}
          else
            {state.work_turns_remaining - 1, state.retry_turns_remaining}
          end

        # Build feedback with appropriate turn info
        feedback = TurnFeedback.build_error_feedback(error_message, agent, state)

        new_state = %{
          state
          | turn: state.turn + 1,
            messages:
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: feedback}
                ],
            turns: [turn | state.turns],
            memory: lisp_step.memory,
            last_fail: lisp_step.fail,
            remaining_turns: state.remaining_turns - 1,
            work_turns_remaining: new_work_turns,
            retry_turns_remaining: new_retry_turns,
            last_return_error: error_message
        }

        loop(agent, llm, new_state)
    end
  end

  # Handle successful Lisp execution
  defp handle_successful_execution(code, response, lisp_step, state, agent, llm) do
    cond do
      # Explicit return was actually executed - validate against signature before accepting
      match?({:__ptc_return__, _}, lisp_step.return) ->
        {:__ptc_return__, return_value} = lisp_step.return
        # Normalize hyphenated keys to underscored at the boundary (Clojure -> Elixir)
        normalized_value = KeyNormalizer.normalize_keys(return_value)
        # Update lisp_step with normalized value for downstream use
        unwrapped_step = %{lisp_step | return: normalized_value}

        case ReturnValidation.validate(agent, normalized_value) do
          :ok ->
            build_success_step(code, response, unwrapped_step, state, agent)

          {:error, validation_errors} ->
            handle_return_validation_error(
              code,
              response,
              unwrapped_step,
              state,
              agent,
              llm,
              validation_errors
            )
        end

      # Single-shot mode without return_retries - skip validation (no retry possible anyway)
      agent.max_turns == 1 and agent.return_retries == 0 ->
        # Normalize hyphenated keys to underscored at the boundary (Clojure -> Elixir)
        normalized_step = %{lisp_step | return: KeyNormalizer.normalize_keys(lisp_step.return)}
        build_success_step(code, response, normalized_step, state, agent)

      match?({:__ptc_fail__, _}, lisp_step.return) ->
        # Explicit fail was actually executed - complete with error, NO RETRY
        # This bypasses the retry mechanism entirely (intentional failure)
        {:__ptc_fail__, fail_args} = lisp_step.return

        # Build Turn struct (failure turn) with turn type
        turn =
          Metrics.build_turn(state, response, code, fail_args,
            success?: false,
            prints: lisp_step.prints,
            tool_calls: lisp_step.tool_calls,
            memory: lisp_step.memory,
            type: state.current_turn_type
          )

        duration_ms = System.monotonic_time(:millisecond) - state.start_time

        error_step = Step.error(:failed, inspect(fail_args), lisp_step.memory)

        # Include the final assistant response in messages
        final_messages = state.messages ++ [%{role: :assistant, content: response}]

        final_step = %{
          error_step
          | usage: Metrics.build_final_usage(state, duration_ms, lisp_step.usage.memory_bytes),
            turns:
              Metrics.apply_trace_filter(
                Enum.reverse([turn | state.turns]),
                state.trace_mode,
                true
              ),
            messages: build_collected_messages(state, final_messages),
            prompt: state.expanded_prompt,
            original_prompt: state.original_prompt,
            tools: state.normalized_tools
        }

        {:error, final_step}

      true ->
        # Normal execution - continue loop
        # Check memory limit before continuing
        case check_memory_limit(lisp_step.memory, agent.memory_limit) do
          {:ok, _size} ->
            # Calculate feedback
            {execution_result, _feedback_truncated} = TurnFeedback.format(agent, state, lisp_step)

            # Build Turn struct (success turn - loop continues) with turn type
            turn =
              Metrics.build_turn(state, response, code, lisp_step.return,
                success?: true,
                prints: lisp_step.prints,
                tool_calls: lisp_step.tool_calls,
                memory: lisp_step.memory,
                type: state.current_turn_type
              )

            # Update turn history with truncated result (keep last 3)
            truncated_result = ResponseHandler.truncate_for_history(lisp_step.return)
            updated_history = update_turn_history(state.turn_history, truncated_result)

            # Use unified budget model: consume work turn if not in retry phase, else retry turn
            in_retry_phase = state.work_turns_remaining <= 0

            {new_work_turns, new_retry_turns} =
              if in_retry_phase do
                {state.work_turns_remaining, state.retry_turns_remaining - 1}
              else
                {state.work_turns_remaining - 1, state.retry_turns_remaining}
              end

            new_state = %{
              state
              | turn: state.turn + 1,
                messages:
                  state.messages ++
                    [
                      %{role: :assistant, content: response},
                      %{role: :user, content: execution_result}
                    ],
                turns: [turn | state.turns],
                memory: lisp_step.memory,
                # Context stays immutable - memory values become available as symbols
                last_fail: nil,
                remaining_turns: state.remaining_turns - 1,
                work_turns_remaining: new_work_turns,
                retry_turns_remaining: new_retry_turns,
                turn_history: updated_history,
                last_return_error: nil
            }

            loop(agent, llm, new_state)

          {:error, :memory_limit_exceeded, actual_size} ->
            # Memory limit exceeded - return error
            # Build Turn struct (failure turn - memory limit exceeded) with turn type
            turn =
              Metrics.build_turn(state, response, code, lisp_step.return,
                success?: false,
                prints: lisp_step.prints,
                tool_calls: lisp_step.tool_calls,
                memory: lisp_step.memory,
                type: state.current_turn_type
              )

            duration_ms = System.monotonic_time(:millisecond) - state.start_time

            error_msg =
              "Memory limit exceeded: #{actual_size} bytes > #{agent.memory_limit} bytes"

            error_step = Step.error(:memory_limit_exceeded, error_msg, lisp_step.memory)

            # Include the final assistant response in messages
            final_messages = state.messages ++ [%{role: :assistant, content: response}]

            final_step = %{
              error_step
              | usage: Metrics.build_final_usage(state, duration_ms, actual_size),
                turns:
                  Metrics.apply_trace_filter(
                    Enum.reverse([turn | state.turns]),
                    state.trace_mode,
                    true
                  ),
                messages: build_collected_messages(state, final_messages),
                prompt: state.expanded_prompt,
                original_prompt: state.original_prompt,
                tools: state.normalized_tools
            }

            {:error, final_step}
        end
    end
  end

  # Expand template placeholders
  # - JSON mode: embed actual values (no Data section, values are in the task)
  # - PTC-Lisp mode: use annotated references (data is in Data Inventory section)
  defp expand_template(prompt, context, output_mode \\ :ptc_lisp) when is_map(context) do
    alias PtcRunner.SubAgent.PromptExpander

    case output_mode do
      :json ->
        # JSON mode: embed actual data values in the task
        {:ok, result} = PromptExpander.expand(prompt, context, on_missing: :keep)
        result

      :ptc_lisp ->
        # PTC-Lisp mode: use ~{data/var} references (values in Data Inventory)
        case PromptExpander.expand_annotated(prompt, context) do
          {:ok, result} ->
            result

          # Fall back to keeping placeholders if context is missing keys
          {:error, _} ->
            {:ok, result} = PromptExpander.expand(prompt, context, on_missing: :keep)
            result
        end
    end
  end

  # System prompt generation - static sections only (cacheable)
  # Dynamic sections (data inventory, tools, expected output) are in the first user message
  defp build_system_prompt(agent, _context, resolution_context, _received_field_descriptions) do
    SystemPrompt.generate_system(agent, resolution_context: resolution_context)
  end

  # Build the first user message with dynamic context prepended to mission
  defp build_first_user_message(agent, run_opts, expanded_mission) do
    context_prompt =
      SystemPrompt.generate_context(agent,
        context: run_opts.context,
        received_field_descriptions: run_opts.received_field_descriptions
      )

    # Combine context sections with mission
    [context_prompt, "# Mission\n\n#{expanded_mission}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Build messages for LLM input
  # Uses compression strategy if enabled and turn > 1; otherwise uses accumulated messages
  # Returns {messages, compression_stats | nil}
  defp build_llm_messages(agent, state, system_prompt) do
    # Normalize compression option
    {strategy, opts} = Compression.normalize(agent.compression)

    # Use compressed messages if:
    # 1. Compression strategy is enabled (not nil)
    # 2. We're past turn 1 (have history to compress)
    # 3. Not in single-shot mode without retries (SS-001: max_turns == 1 skips compression)
    #    BUT: single-shot with return_retries > 0 DOES use compression for context collapsing
    if strategy && state.turn > 1 && (agent.max_turns > 1 or agent.return_retries > 0) do
      build_compressed_messages(agent, state, system_prompt, strategy, opts)
    else
      # Uncompressed mode - use accumulated messages as-is, no compression stats
      {state.messages, nil}
    end
  end

  # Build compressed messages using the strategy
  # Returns {messages, compression_stats}
  defp build_compressed_messages(agent, state, system_prompt, strategy, opts) do
    # Gather completed turns from state.turns (stored in reverse order)
    turns = Enum.reverse(state.turns)

    # Normalize tools for compression (use the same normalization as execution)
    normalized_tools =
      Enum.map(agent.tools, fn {name, format} ->
        case PtcRunner.Tool.new(name, format) do
          {:ok, tool} -> {name, tool}
          {:error, _} -> {name, %PtcRunner.Tool{name: to_string(name), signature: nil}}
        end
      end)
      |> Map.new()

    # Calculate turns left for the indicator
    # In retry phase (work_turns_remaining <= 0), we're always on final turn (turns_left = 0)
    # This handles single-shot with return_retries where turn > max_turns
    turns_left = max(0, state.work_turns_remaining - 1)

    # Build compression options with context
    compression_opts =
      opts
      |> Keyword.put(:prompt, expand_template(agent.prompt, state.context))
      |> Keyword.put(:system_prompt, system_prompt)
      |> Keyword.put(:tools, normalized_tools)
      |> Keyword.put(:data, state.context)
      |> Keyword.put(:turns_left, turns_left)
      |> Keyword.put(:signature, agent.signature)
      |> Keyword.put(:field_descriptions, agent.field_descriptions)

    # Call the compression strategy
    # Strategy returns {[%{role: :system, ...}, %{role: :user, ...}], stats}
    {compressed_messages, stats} = strategy.to_messages(turns, state.memory, compression_opts)

    # Extract just the user message(s) since system prompt is passed separately
    # The loop sends system prompt via llm_input.system, not in messages
    messages =
      compressed_messages
      |> Enum.reject(fn msg -> msg.role == :system end)

    {messages, stats}
  end

  # Calculate approximate memory size in bytes
  defp memory_size(memory) when is_map(memory) do
    :erlang.external_size(memory)
  end

  # Check if memory exceeds the limit
  defp check_memory_limit(memory, limit) when is_integer(limit) do
    size = memory_size(memory)

    if size > limit do
      {:error, :memory_limit_exceeded, size}
    else
      {:ok, size}
    end
  end

  defp check_memory_limit(_memory, nil), do: {:ok, 0}

  # Calculate mission deadline from timeout in milliseconds
  defp calculate_mission_deadline(nil), do: nil

  defp calculate_mission_deadline(timeout_ms) when is_integer(timeout_ms) do
    DateTime.utc_now() |> DateTime.add(timeout_ms, :millisecond)
  end

  # Check if mission timeout has been exceeded
  defp mission_timeout_exceeded?(deadline) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  # Build error step for loop termination conditions (max_turns, turn_budget, mission_timeout)
  # Uses -1 turn offset since we haven't started the turn that would exceed the limit
  defp build_termination_error(reason, message, state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.error(reason, message, state.memory)

    step_with_metrics = %{
      step
      | usage: Metrics.build_final_usage(state, duration_ms, 0, -1),
        turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
        messages: build_collected_messages(state, state.messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt,
        tools: state.normalized_tools
    }

    {:error, step_with_metrics}
  end

  # Build final Step struct with common fields
  # Used by build_success_step and build_success_from_fallback
  defp build_final_step(step, agent, state, opts) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    turns = Keyword.get(opts, :turns, state.turns)
    extra_usage = Keyword.get(opts, :extra_usage, %{})
    messages = Keyword.get(opts, :messages, state.messages)
    memory_bytes = Keyword.get(opts, :memory_bytes, 0)

    %{
      step
      | usage:
          Map.merge(Metrics.build_final_usage(state, duration_ms, memory_bytes), extra_usage),
        turns: Metrics.apply_trace_filter(Enum.reverse(turns), state.trace_mode, false),
        field_descriptions: agent.field_descriptions,
        messages: build_collected_messages(state, messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt,
        tools: state.normalized_tools
    }
  end

  # Update turn history, keeping only the last 3 results
  # New results are appended to the end so *1 = last, *2 = second-to-last, *3 = third-to-last
  defp update_turn_history(history, new_result) do
    (history ++ [new_result]) |> Enum.take(-3)
  end

  # Build success step for return/single-shot termination
  defp build_success_step(code, response, lisp_step, state, agent) do
    # Build Turn struct (success turn - final) with turn type
    turn =
      Metrics.build_turn(state, response, code, lisp_step.return,
        success?: true,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: Map.get(state, :current_turn_type, :normal)
      )

    # Include the final assistant response in messages
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    final_step =
      build_final_step(lisp_step, agent, state,
        turns: [turn | state.turns],
        messages: final_messages,
        memory_bytes: lisp_step.usage.memory_bytes
      )

    {:ok, final_step}
  end

  # Handle return validation error - feed back to LLM for retry
  # Uses unified budget model: consumes work turn if not in retry phase, else retry turn
  defp handle_return_validation_error(code, response, lisp_step, state, agent, llm, errors) do
    error_message = ReturnValidation.format_error_for_llm(agent, lisp_step.return, errors)

    # Build validation error info for the turn (so compression can show the actual error)
    validation_error = %{
      reason: :return_validation_failed,
      message: error_message,
      actual_value: lisp_step.return,
      errors: errors
    }

    # Build Turn struct (failure turn - validation error) with turn type
    turn =
      Metrics.build_turn(state, response, code, validation_error,
        success?: false,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    # Use unified budget model: consume work turn if not in retry phase, else retry turn
    in_retry_phase = state.work_turns_remaining <= 0

    {new_work_turns, new_retry_turns} =
      if in_retry_phase do
        {state.work_turns_remaining, state.retry_turns_remaining - 1}
      else
        {state.work_turns_remaining - 1, state.retry_turns_remaining}
      end

    # Build feedback with appropriate turn info
    feedback = TurnFeedback.build_error_feedback(error_message, agent, state)

    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: feedback}
            ],
        turns: [turn | state.turns],
        memory: lisp_step.memory,
        last_fail: nil,
        remaining_turns: state.remaining_turns - 1,
        work_turns_remaining: new_work_turns,
        retry_turns_remaining: new_retry_turns,
        last_return_error: error_message
    }

    loop(agent, llm, new_state)
  end

  # ============================================================
  # Last Expression Fallback
  # ============================================================

  # Attempt to recover a valid return from the last successful expression result.
  # This handles the case where the LLM computed the correct answer but forgot
  # to wrap it with (return ...).
  defp try_last_expression_fallback(agent, state) do
    case find_last_successful_result(state.turns) do
      {:ok, result, turn} ->
        # Normalize keys (Clojure-style -> Elixir-style)
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

  # Find the most recent successful turn with a non-nil result.
  # state.turns is in reverse chronological order (most recent first),
  # so Enum.find returns the most recent match.
  defp find_last_successful_result(turns) do
    case Enum.find(turns, fn turn -> turn.success? and turn.result != nil end) do
      nil -> :none
      turn -> {:ok, turn.result, turn}
    end
  end

  # Build a success step from a fallback turn.
  # Uses turn.memory (state at that point) rather than state.memory.
  defp build_success_from_fallback(normalized_value, turn, state, agent) do
    # Build a success step with the fallback value
    step = Step.ok(normalized_value, turn.memory)

    final_step =
      build_final_step(step, agent, state, extra_usage: %{fallback_used: true})

    {:ok, final_step}
  end

  # ============================================================
  # Message Collection
  # ============================================================

  # Build collected messages with system prompt prepended, or nil if not collecting
  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    case state.collected_system_prompt do
      nil -> messages
      system_prompt -> [%{role: :system, content: system_prompt} | messages]
    end
  end

  # ============================================================
  # Tool Normalization for Step
  # ============================================================

  # Normalize tools to %{name => %Tool{}} for Step.tools (used by Debug compressed view)
  defp normalize_tools_for_step(tools) do
    Enum.map(tools, fn {name, format} ->
      case PtcRunner.Tool.new(name, format) do
        {:ok, tool} -> {name, tool}
        {:error, _} -> {name, %PtcRunner.Tool{name: to_string(name), signature: nil}}
      end
    end)
    |> Map.new()
  end
end
