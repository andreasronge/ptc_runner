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
  alias PtcRunner.SubAgent.Loop.{LLMRetry, Metrics, ResponseHandler, ToolNormalizer}
  alias PtcRunner.SubAgent.{Prompt, Signature, Telemetry}

  @doc """
  Execute a SubAgent in loop mode (multi-turn with tools).

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `llm` - Required. LLM callback function
    - `context` - Initial context map (default: %{})
    - `debug` - Enable debug mode (default: false). When enabled, trace entries store exact message contents:
      - `llm_response` - The assistant message (LLM output, stored as-is)
      - `llm_feedback` - The user message (execution feedback, after truncation)
      Use `SubAgent.Debug.print_trace(step, messages: true)` to view the conversation.
    - `trace` - Trace filtering: true (always), false (never), :on_error (only on failure) (default: true)
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
      iex> llm = fn %{messages: _} -> {:ok, "```clojure\\n(return {:result (+ ctx/x ctx/y)})\\n```"} end
      iex> {:ok, step} = PtcRunner.SubAgent.Loop.run(agent, llm: llm, context: %{x: 5, y: 3})
      iex> step.return
      %{result: 8}
  """
  @spec run(SubAgent.t(), keyword()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%SubAgent{} = agent, opts) do
    llm = Keyword.fetch!(opts, :llm)
    context = Keyword.get(opts, :context, %{})
    llm_registry = Keyword.get(opts, :llm_registry, %{})
    debug = Keyword.get(opts, :debug, false)
    trace_mode = Keyword.get(opts, :trace, true)
    llm_retry = Keyword.get(opts, :llm_retry)
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
          debug: debug,
          trace_mode: trace_mode,
          llm_retry: llm_retry,
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

    # Expand template in prompt
    expanded_prompt = expand_template(agent.prompt, run_opts.context)

    initial_state = %{
      llm: run_opts.llm,
      llm_registry: run_opts.llm_registry,
      turn: 1,
      messages: [%{role: :user, content: expanded_prompt}],
      context: run_opts.context,
      trace: [],
      start_time: System.monotonic_time(:millisecond),
      memory: %{},
      last_fail: nil,
      nesting_depth: run_opts.nesting_depth,
      remaining_turns: run_opts.remaining_turns,
      mission_deadline: calculated_deadline,
      debug: run_opts.debug,
      trace_mode: run_opts.trace_mode,
      llm_retry: run_opts.llm_retry,
      # Token accumulation across LLM calls
      total_input_tokens: 0,
      total_output_tokens: 0,
      llm_requests: 0,
      # Estimated system prompt tokens (set on first turn)
      system_prompt_tokens: 0,
      # Tokens from current turn's LLM call (for telemetry)
      turn_tokens: nil,
      # Turn history for *1/*2/*3 access (last 3 results, most recent last)
      turn_history: [],
      # Field descriptions received from upstream agent in a chain
      received_field_descriptions: run_opts.received_field_descriptions
    }

    loop(agent, run_opts.llm, initial_state)
  end

  # Loop when max_turns exceeded
  defp loop(agent, _llm, state) when state.turn > agent.max_turns do
    build_termination_error(
      :max_turns_exceeded,
      "Exceeded max_turns limit of #{agent.max_turns}",
      state
    )
  end

  # Check turn budget before each turn (guard clause)
  defp loop(_agent, _llm, state) when state.remaining_turns <= 0 do
    build_termination_error(:turn_budget_exhausted, "Turn budget exhausted", state)
  end

  # Main loop iteration
  defp loop(agent, llm, state) do
    # Check mission timeout before each turn
    if state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) do
      build_termination_error(:mission_timeout, "Mission timeout exceeded", state)
    else
      # Emit turn start event
      Telemetry.emit([:turn, :start], %{}, %{agent: agent, turn: state.turn})
      turn_start = System.monotonic_time()

      # Build LLM input with resolution context for language_spec callbacks
      resolution_context = %{
        turn: state.turn,
        model: state.llm,
        memory: state.memory,
        messages: state.messages
      }

      llm_input = %{
        system:
          build_system_prompt(
            agent,
            state.context,
            resolution_context,
            state.received_field_descriptions
          ),
        messages: state.messages,
        turn: state.turn,
        tool_names: Map.keys(agent.tools)
      }

      # Call LLM with telemetry and retry logic
      case call_llm_with_telemetry(llm, llm_input, state, agent) do
        {:ok, %{content: content, tokens: tokens}} ->
          # Accumulate tokens and store system prompt for debugging
          state_with_metadata =
            state
            |> Metrics.accumulate_tokens(tokens)
            |> Map.put(:current_system_prompt, llm_input.system)
            |> maybe_add_system_prompt_tokens(llm_input.system)

          result = handle_llm_response(content, agent, llm, state_with_metadata)
          # Emit turn stop event (only for completed turns, not continuation)
          Metrics.emit_turn_stop_if_final(result, agent, state_with_metadata, turn_start)
          result

        {:error, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - state.start_time

          step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", state.memory)

          step_with_metrics = %{
            step
            | usage: Metrics.build_final_usage(state, duration_ms, 0),
              trace: Metrics.apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
          }

          # Emit turn stop on error
          turn_duration = System.monotonic_time() - turn_start

          Telemetry.emit([:turn, :stop], %{duration: turn_duration}, %{
            agent: agent,
            turn: state.turn,
            program: nil
          })

          {:error, step_with_metrics}
      end
    end
  end

  # Estimate system prompt tokens on first turn only
  defp maybe_add_system_prompt_tokens(%{turn: 1} = state, system_prompt) do
    Map.put(state, :system_prompt_tokens, Metrics.estimate_tokens(system_prompt))
  end

  defp maybe_add_system_prompt_tokens(state, _system_prompt), do: state

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

        # Feed error back to LLM with turn info
        error_message =
          "Error: No valid PTC-Lisp code found in response. Please provide code in a ```clojure or ```lisp code block, or as a raw s-expression starting with '('."
          |> append_turn_info(agent, state)

        new_state = %{
          state
          | turn: state.turn + 1,
            messages:
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: error_message}
                ],
            remaining_turns: state.remaining_turns - 1
        }

        loop(agent, llm, new_state)
    end
  end

  # Execute parsed code
  defp execute_code(code, response, agent, llm, state) do
    # Check if code calls any catalog-only tools
    case ResponseHandler.find_catalog_tool_call(code, agent.tools, agent.tool_catalog) do
      {:error, catalog_tool_name} ->
        # Feed error back to LLM with turn info
        available_tools = Map.keys(agent.tools) |> Enum.sort() |> Enum.join(", ")

        error_message =
          "Error: Tool '#{catalog_tool_name}' is for planning only and cannot be called. Available tools: #{available_tools}"
          |> append_turn_info(agent, state)

        new_state = %{
          state
          | turn: state.turn + 1,
            messages:
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: error_message}
                ],
            remaining_turns: state.remaining_turns - 1
        }

        loop(agent, llm, new_state)

      :ok ->
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
  end

  # Continue execution after tool_catalog check
  defp execute_code_with_tools(code, response, agent, llm, state, exec_context, all_tools) do
    lisp_opts = [
      context: exec_context,
      memory: state.memory,
      tools: all_tools,
      turn_history: state.turn_history
    ]

    case Lisp.run(code, lisp_opts) do
      {:ok, lisp_step} ->
        handle_successful_execution(code, response, lisp_step, state, agent, llm)

      {:error, lisp_step} ->
        # Feed error back to LLM for next turn with turn info
        error_message =
          ResponseHandler.format_error_for_llm(lisp_step.fail)
          |> append_turn_info(agent, state)

        # Build trace entry for failed execution (show error message, not nil)
        error_result = {:error, lisp_step.fail.message}

        trace_entry =
          Metrics.build_trace_entry(state, code, error_result, [],
            llm_response: response,
            llm_feedback: error_message
          )

        new_state = %{
          state
          | turn: state.turn + 1,
            messages:
              state.messages ++
                [
                  %{role: :assistant, content: response},
                  %{role: :user, content: error_message}
                ],
            trace: [trace_entry | state.trace],
            memory: lisp_step.memory,
            last_fail: lisp_step.fail,
            remaining_turns: state.remaining_turns - 1
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
        # Update lisp_step with unwrapped value for downstream use
        unwrapped_step = %{lisp_step | return: return_value}

        case validate_return_type(agent, return_value) do
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

      # Single-shot mode - skip validation (no retry possible anyway)
      agent.max_turns == 1 ->
        build_success_step(code, response, lisp_step, state, agent)

      match?({:__ptc_fail__, _}, lisp_step.return) ->
        # Explicit fail was actually executed - complete with error, no feedback
        {:__ptc_fail__, fail_args} = lisp_step.return

        trace_entry =
          Metrics.build_trace_entry(state, code, fail_args, [],
            llm_response: response,
            llm_feedback: nil,
            prints: lisp_step.prints
          )

        duration_ms = System.monotonic_time(:millisecond) - state.start_time

        error_step = Step.error(:failed, inspect(fail_args), lisp_step.memory)

        final_step = %{
          error_step
          | usage: Metrics.build_final_usage(state, duration_ms, lisp_step.usage.memory_bytes),
            trace:
              Metrics.apply_trace_filter(
                Enum.reverse([trace_entry | state.trace]),
                state.trace_mode,
                true
              )
        }

        {:error, final_step}

      true ->
        # Normal execution - continue loop
        # Check memory limit before continuing
        case check_memory_limit(lisp_step.memory, agent.memory_limit) do
          {:ok, _size} ->
            # Calculate feedback before building trace entry
            {execution_result, feedback_truncated} = format_turn_feedback(agent, state, lisp_step)

            trace_entry =
              Metrics.build_trace_entry(state, code, lisp_step.return, [],
                llm_response: response,
                llm_feedback: execution_result,
                feedback_truncated: feedback_truncated,
                prints: lisp_step.prints
              )

            # Update turn history with truncated result (keep last 3)
            truncated_result = ResponseHandler.truncate_for_history(lisp_step.return)
            updated_history = update_turn_history(state.turn_history, truncated_result)

            new_state = %{
              state
              | turn: state.turn + 1,
                messages:
                  state.messages ++
                    [
                      %{role: :assistant, content: response},
                      %{role: :user, content: execution_result}
                    ],
                trace: [trace_entry | state.trace],
                memory: lisp_step.memory,
                # Context stays immutable - memory values become available as symbols
                last_fail: nil,
                remaining_turns: state.remaining_turns - 1,
                turn_history: updated_history
            }

            loop(agent, llm, new_state)

          {:error, :memory_limit_exceeded, actual_size} ->
            # Memory limit exceeded - return error
            trace_entry =
              Metrics.build_trace_entry(state, code, lisp_step.return, [],
                llm_response: response,
                llm_feedback: nil,
                prints: lisp_step.prints
              )

            duration_ms = System.monotonic_time(:millisecond) - state.start_time

            error_msg =
              "Memory limit exceeded: #{actual_size} bytes > #{agent.memory_limit} bytes"

            error_step = Step.error(:memory_limit_exceeded, error_msg, lisp_step.memory)

            final_step = %{
              error_step
              | usage: Metrics.build_final_usage(state, duration_ms, actual_size),
                trace:
                  Metrics.apply_trace_filter(
                    Enum.reverse([trace_entry | state.trace]),
                    state.trace_mode,
                    true
                  )
            }

            {:error, final_step}
        end
    end
  end

  # Expand template placeholders with context values
  defp expand_template(prompt, context) when is_map(context) do
    alias PtcRunner.SubAgent.Template
    {:ok, result} = Template.expand(prompt, context, on_missing: :keep)
    result
  end

  # System prompt generation with resolution context for language_spec callbacks
  defp build_system_prompt(agent, context, resolution_context, received_field_descriptions) do
    Prompt.generate(agent,
      context: context,
      resolution_context: resolution_context,
      received_field_descriptions: received_field_descriptions
    )
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
        trace: Metrics.apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
    }

    {:error, step_with_metrics}
  end

  # Update turn history, keeping only the last 3 results
  # New results are appended to the end so *1 = last, *2 = second-to-last, *3 = third-to-last
  defp update_turn_history(history, new_result) do
    (history ++ [new_result]) |> Enum.take(-3)
  end

  # Append turn info to any feedback message (used for both success and error paths)
  defp append_turn_info(message, agent, state) do
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

  # Returns {feedback_string, truncated?}
  # Only shows explicit println output - LLM must be intentional about what it inspects
  defp format_turn_feedback(agent, state, lisp_step) do
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

  defp truncate_prints(str, max_chars) when byte_size(str) > max_chars do
    {String.slice(str, 0, max_chars), true}
  end

  defp truncate_prints(str, _max_chars), do: {str, false}

  # ============================================================
  # Return Type Validation
  # ============================================================

  # Build success step for return/single-shot termination
  defp build_success_step(code, response, lisp_step, state, agent) do
    trace_entry =
      Metrics.build_trace_entry(state, code, lisp_step.return, [],
        llm_response: response,
        llm_feedback: nil,
        prints: lisp_step.prints
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    final_step = %{
      lisp_step
      | usage: Metrics.build_final_usage(state, duration_ms, lisp_step.usage.memory_bytes),
        trace:
          Metrics.apply_trace_filter(
            Enum.reverse([trace_entry | state.trace]),
            state.trace_mode,
            false
          ),
        field_descriptions: agent.field_descriptions
    }

    {:ok, final_step}
  end

  # Validate return value against agent's parsed signature
  # Returns :ok or {:error, [validation_error()]}
  defp validate_return_type(%{parsed_signature: nil}, _value), do: :ok
  defp validate_return_type(%{parsed_signature: {:signature, _, :any}}, _value), do: :ok

  defp validate_return_type(%{parsed_signature: parsed_sig}, value) do
    Signature.validate(parsed_sig, value)
  end

  # Handle return validation error - feed back to LLM for retry
  defp handle_return_validation_error(code, response, lisp_step, state, agent, llm, errors) do
    error_message = format_validation_error_for_llm(agent, lisp_step.return, errors)

    trace_entry =
      Metrics.build_trace_entry(state, code, lisp_step.return, [],
        llm_response: response,
        llm_feedback: error_message,
        prints: lisp_step.prints
      )

    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: error_message}
            ],
        trace: [trace_entry | state.trace],
        memory: lisp_step.memory,
        last_fail: nil,
        remaining_turns: state.remaining_turns - 1
    }

    loop(agent, llm, new_state)
  end

  # Format validation error for LLM feedback (actionable, helps LLM fix)
  defp format_validation_error_for_llm(agent, actual_value, errors) do
    expected_type = format_expected_type(agent)
    error_details = format_error_details(errors)
    actual_str = inspect(actual_value, limit: 10, pretty: false)
    truncated_actual = String.slice(actual_str, 0, 200)

    """
    Return type validation failed.
    Expected: #{expected_type}
    Received: #{truncated_actual}
    Errors:
    #{error_details}
    Please fix and call (return ...) with a correctly typed value.
    """
  end

  defp format_expected_type(%{parsed_signature: nil}), do: ":any"

  defp format_expected_type(%{parsed_signature: {:signature, _, return_type}}) do
    Signature.Renderer.render_type(return_type)
  end

  defp format_error_details(errors) do
    Enum.map_join(errors, "\n", fn %{path: path, message: message} ->
      path_str = if path == [], do: "root", else: "[#{Enum.join(path, ".")}]"
      "- #{path_str}: #{message}"
    end)
  end
end
