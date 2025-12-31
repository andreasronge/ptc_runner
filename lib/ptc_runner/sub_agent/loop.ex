defmodule PtcRunner.SubAgent.Loop do
  @moduledoc """
  Core agentic loop that manages LLM↔tool cycles.

  The loop repeatedly calls the LLM, parses PTC-Lisp from the response,
  executes it, and continues until `return`/`fail` is called or `max_turns` is exceeded.

  See [specification.md#looprun2](https://github.com/andreasronge/ptc_runner/blob/main/docs/ptc_agents/specification.md#looprun2)
  for architecture details.

  ## Flow

  1. Build LLM input with system prompt, messages, and tool names
  2. Call LLM to get response (resolving atoms via `llm_registry` if needed)
  3. Parse PTC-Lisp code from response (code blocks or raw s-expressions)
  4. Execute code via `Lisp.run/2`
  5. Check for return/fail or continue to next turn
  6. Build trace entry and update message history
  7. Merge execution results into context for next turn

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
  alias PtcRunner.SubAgent.{Prompt, SubAgentTool}

  @doc """
  Execute a SubAgent in loop mode (multi-turn with tools).

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `llm` - Required. LLM callback function
    - `context` - Initial context map (default: %{})
    - `debug` - Enable verbose execution tracing (default: false)
    - `trace` - Trace filtering: true (always), false (never), :on_error (only on failure) (default: true)

  ## Returns

  - `{:ok, Step.t()}` on success (when `return` is called)
  - `{:error, Step.t()}` on failure (when `fail` is called or max_turns exceeded)

  ## Examples

      iex> agent = PtcRunner.SubAgent.new(prompt: "Add {{x}} and {{y}}", tools: %{}, max_turns: 2)
      iex> llm = fn %{messages: _} -> {:ok, "```clojure\\n(call \\"return\\" {:result (+ ctx/x ctx/y)})\\n```"} end
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
          trace_mode: trace_mode
        }

        do_run(agent, run_opts)
      end
    end
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
      trace_mode: run_opts.trace_mode
    }

    loop(agent, run_opts.llm, initial_state)
  end

  # Loop when max_turns exceeded
  defp loop(agent, _llm, state) when state.turn > agent.max_turns do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    step =
      Step.error(
        :max_turns_exceeded,
        "Exceeded max_turns limit of #{agent.max_turns}",
        state.memory
      )

    step_with_metrics = %{
      step
      | usage: %{
          duration_ms: duration_ms,
          memory_bytes: 0,
          turns: state.turn - 1
        },
        trace: apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
    }

    {:error, step_with_metrics}
  end

  # Check turn budget before each turn (guard clause)
  defp loop(_agent, _llm, state) when state.remaining_turns <= 0 do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.error(:turn_budget_exhausted, "Turn budget exhausted", state.memory)

    step_with_metrics = %{
      step
      | usage: %{
          duration_ms: duration_ms,
          memory_bytes: 0,
          turns: state.turn - 1
        },
        trace: apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
    }

    {:error, step_with_metrics}
  end

  # Main loop iteration
  defp loop(agent, llm, state) do
    # Check mission timeout before each turn
    if state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) do
      duration_ms = System.monotonic_time(:millisecond) - state.start_time
      step = Step.error(:mission_timeout, "Mission timeout exceeded", state.memory)

      step_with_metrics = %{
        step
        | usage: %{
            duration_ms: duration_ms,
            memory_bytes: 0,
            turns: state.turn - 1
          },
          trace: apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
      }

      {:error, step_with_metrics}
    else
      # Build LLM input
      llm_input = %{
        system: build_system_prompt(agent, state.context),
        messages: state.messages,
        turn: state.turn,
        tool_names: Map.keys(agent.tools)
      }

      # Call LLM
      alias PtcRunner.SubAgent.LLMResolver

      case LLMResolver.resolve(llm, llm_input, state.llm_registry) do
        {:ok, response} ->
          handle_llm_response(response, agent, llm, state)

        {:error, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - state.start_time

          step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", state.memory)

          step_with_metrics = %{
            step
            | usage: %{
                duration_ms: duration_ms,
                memory_bytes: 0,
                turns: state.turn
              },
              trace: apply_trace_filter(Enum.reverse(state.trace), state.trace_mode, true)
          }

          {:error, step_with_metrics}
      end
    end
  end

  # Handle LLM response - parse and execute code
  defp handle_llm_response(response, agent, llm, state) do
    case parse_response(response) do
      {:ok, code} ->
        execute_code(code, response, agent, llm, state)

      {:error, :no_code_in_response} ->
        # Feed error back to LLM
        error_message =
          "Error: No valid PTC-Lisp code found in response. Please provide code in a ```clojure or ```lisp code block, or as a raw s-expression starting with '('."

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
    case find_catalog_tool_call(code, agent.tools, agent.tool_catalog) do
      {:error, catalog_tool_name} ->
        # Feed error back to LLM
        available_tools = Map.keys(agent.tools) |> Enum.sort() |> Enum.join(", ")

        error_message =
          "Error: Tool '#{catalog_tool_name}' is for planning only and cannot be called. Available tools: #{available_tools}"

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

        # Normalize SubAgentTool instances to functions
        normalized_tools = normalize_tools(agent.tools, state)

        # Merge system tools (return/fail) with user tools
        # System tools must come second to take precedence
        system_tools = %{
          "return" => fn args -> args end,
          "fail" => fn args -> args end
        }

        all_tools = Map.merge(normalized_tools, system_tools)
        execute_code_with_tools(code, response, agent, llm, state, exec_context, all_tools)
    end
  end

  # Continue execution after tool_catalog check
  defp execute_code_with_tools(code, response, agent, llm, state, exec_context, all_tools) do
    case Lisp.run(code, context: exec_context, memory: state.memory, tools: all_tools) do
      {:ok, lisp_step} ->
        handle_successful_execution(code, response, lisp_step, state, agent, llm)

      {:error, lisp_step} ->
        # Build trace entry for failed execution
        trace_entry = %{
          turn: state.turn,
          program: code,
          result: nil,
          tool_calls: []
        }

        # Add debug fields if debug mode enabled
        trace_entry =
          if state.debug do
            Map.merge(trace_entry, %{
              context_snapshot: state.context,
              memory_snapshot: state.memory,
              full_prompt: List.last(state.messages)
            })
          else
            trace_entry
          end

        # Feed error back to LLM for next turn
        error_message = format_error_for_llm(lisp_step.fail)

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
    # Build trace entry
    trace_entry = %{
      turn: state.turn,
      program: code,
      result: lisp_step.return,
      # TODO: Tool calls tracking in Stage 4
      tool_calls: []
    }

    # Add debug fields if debug mode enabled
    trace_entry =
      if state.debug do
        Map.merge(trace_entry, %{
          context_snapshot: state.context,
          memory_snapshot: state.memory,
          full_prompt: List.last(state.messages)
        })
      else
        trace_entry
      end

    # Log turn execution if debug mode is enabled
    maybe_log_turn(state, response, lisp_step.return, state.debug)

    # Check if code contains explicit return/fail call (Stage 4 preview)
    # For now, detect these as special tool names
    cond do
      contains_call?(code, "return") ->
        # Explicit return - complete successfully
        duration_ms = System.monotonic_time(:millisecond) - state.start_time

        final_step = %{
          lisp_step
          | usage: %{
              duration_ms: duration_ms,
              memory_bytes: lisp_step.usage.memory_bytes,
              turns: state.turn
            },
            trace:
              apply_trace_filter(
                Enum.reverse([trace_entry | state.trace]),
                state.trace_mode,
                false
              )
        }

        {:ok, final_step}

      contains_call?(code, "fail") ->
        # Explicit fail - complete with error
        duration_ms = System.monotonic_time(:millisecond) - state.start_time

        error_step = Step.error(:failed, inspect(lisp_step.return), lisp_step.memory)

        final_step = %{
          error_step
          | usage: %{
              duration_ms: duration_ms,
              memory_bytes: lisp_step.usage.memory_bytes,
              turns: state.turn
            },
            trace:
              apply_trace_filter(
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
            # Merge result into context and memory for next turn
            execution_result = format_execution_result(lisp_step.return)

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
                context: Map.merge(state.context, lisp_step.memory_delta),
                last_fail: nil,
                remaining_turns: state.remaining_turns - 1
            }

            loop(agent, llm, new_state)

          {:error, :memory_limit_exceeded, actual_size} ->
            # Memory limit exceeded - return error
            duration_ms = System.monotonic_time(:millisecond) - state.start_time

            error_msg =
              "Memory limit exceeded: #{actual_size} bytes > #{agent.memory_limit} bytes"

            error_step = Step.error(:memory_limit_exceeded, error_msg, lisp_step.memory)

            final_step = %{
              error_step
              | usage: %{
                  duration_ms: duration_ms,
                  memory_bytes: actual_size,
                  turns: state.turn
                },
                trace:
                  apply_trace_filter(
                    Enum.reverse([trace_entry | state.trace]),
                    state.trace_mode,
                    true
                  )
            }

            {:error, final_step}
        end
    end
  end

  # Parse PTC-Lisp from LLM response
  defp parse_response(response) do
    # Try extracting from code blocks (clojure or lisp)
    case Regex.scan(~r/```(?:clojure|lisp)\n(.*?)```/s, response) do
      [] ->
        # Try raw s-expression
        trimmed = String.trim(response)

        if String.starts_with?(trimmed, "(") do
          {:ok, trimmed}
        else
          {:error, :no_code_in_response}
        end

      [[_, code]] ->
        {:ok, String.trim(code)}

      blocks ->
        # Multiple blocks - wrap in do
        code = Enum.map_join(blocks, "\n", &List.last/1)
        {:ok, "(do #{code})"}
    end
  end

  # Expand template placeholders with context values
  defp expand_template(prompt, context) when is_map(context) do
    alias PtcRunner.SubAgent.Template
    {:ok, result} = Template.expand(prompt, context, on_missing: :keep)
    result
  end

  # System prompt generation
  defp build_system_prompt(agent, context) do
    Prompt.generate(agent, context: context)
  end

  # Check if code calls a catalog-only tool (not in executable tools)
  defp find_catalog_tool_call(code, executable_tools, tool_catalog) do
    # Only check if tool_catalog exists and is not empty
    if tool_catalog && map_size(tool_catalog) > 0 do
      # Find catalog-only tools (in catalog but not in executable tools)
      catalog_only = Map.keys(tool_catalog) -- Map.keys(executable_tools)

      # Check if code contains a call to any catalog-only tool
      Enum.find_value(catalog_only, :ok, fn tool_name ->
        if contains_call?(code, tool_name) do
          {:error, tool_name}
        else
          nil
        end
      end)
    else
      :ok
    end
  end

  # Format error for LLM feedback
  defp format_error_for_llm(fail) do
    "Error: #{fail.message}"
  end

  # Format execution result for LLM feedback
  defp format_execution_result(result) do
    "Result: #{inspect(result, limit: :infinity, printable_limit: :infinity)}"
  end

  # Check if code contains a call to a specific tool
  defp contains_call?(code, tool_name) do
    # Simple regex to detect (call "tool-name" ...)
    Regex.match?(~r/\(call\s+"#{tool_name}"/, code)
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

  # Normalize tools map to convert SubAgentTool instances into executable functions
  defp normalize_tools(tools, state) when is_map(tools) do
    Map.new(tools, fn
      {name, %SubAgentTool{} = tool} ->
        {name, wrap_sub_agent_tool(tool, state)}

      {name, func} when is_function(func, 1) ->
        {name, wrap_tool_return(func)}

      {name, other} ->
        {name, other}
    end)
  end

  # Wrap a regular tool function to handle {:ok, value}, {:error, reason}, and raw values
  defp wrap_tool_return(func) do
    fn args ->
      case func.(args) do
        {:ok, value} -> value
        {:error, reason} -> raise "Tool error: #{inspect(reason)}"
        value -> value
      end
    end
  end

  # Wrap a SubAgentTool in a function closure that executes the child agent
  defp wrap_sub_agent_tool(%SubAgentTool{} = tool, state) do
    fn args ->
      # Resolve LLM in priority order: agent.llm > bound_llm > parent's llm
      resolved_llm = tool.agent.llm || tool.bound_llm || state.llm

      unless resolved_llm do
        raise ArgumentError, "No LLM available for SubAgentTool execution"
      end

      # Execute the wrapped agent with inherited context
      case SubAgent.run(tool.agent,
             llm: resolved_llm,
             llm_registry: state.llm_registry,
             context: args,
             _nesting_depth: state.nesting_depth + 1,
             _remaining_turns: state.remaining_turns,
             _mission_deadline: state.mission_deadline
           ) do
        {:ok, step} ->
          step.return

        {:error, step} ->
          # Propagate child agent failure
          raise RuntimeError,
                "SubAgent tool failed: #{step.fail.message}"
      end
    end
  end

  # Apply trace filtering based on trace_mode and execution result
  defp apply_trace_filter(_trace, false = _trace_mode, _is_error), do: nil
  defp apply_trace_filter(trace, true = _trace_mode, _is_error), do: trace
  defp apply_trace_filter(trace, :on_error = _trace_mode, true = _is_error), do: trace
  defp apply_trace_filter(_trace, :on_error = _trace_mode, false = _is_error), do: nil

  # Log turn execution if debug mode is enabled
  defp maybe_log_turn(_state, _response, _result, false = _debug), do: :ok

  defp maybe_log_turn(state, response, result, true = _debug) do
    IO.puts("[Turn #{state.turn}] LLM response:")
    IO.puts(response)
    IO.puts("\n[Turn #{state.turn}] Execution result:")
    # credo:disable-for-next-line Credo.Check.Warning.IoInspect
    IO.inspect(result, pretty: true, limit: :infinity)
    IO.puts("\n")
  end
end
