defmodule PtcRunner.SubAgent.Loop do
  @moduledoc """
  Core agentic loop that manages LLM↔tool cycles.

  The loop repeatedly calls the LLM, parses PTC-Lisp from the response,
  executes it, and continues until `return`/`fail` is called or `max_turns` is exceeded.

  See [specification.md#looprun2](https://github.com/andreasronge/ptc_runner/blob/main/docs/ptc_agents/specification.md#looprun2)
  for architecture details.

  ## Flow

  1. Build LLM input with system prompt, messages, and tool names
  2. Call LLM to get response
  3. Parse PTC-Lisp code from response (code blocks or raw s-expressions)
  4. Execute code via `Lisp.run/2`
  5. Check for return/fail or continue to next turn
  6. Build trace entry and update message history
  7. Merge execution results into context for next turn

  This is an internal module called by `SubAgent.run/2`.
  """

  alias PtcRunner.{Lisp, Step}
  alias PtcRunner.SubAgent

  @doc """
  Execute a SubAgent in loop mode (multi-turn with tools).

  ## Parameters

  - `agent` - A `%SubAgent{}` struct
  - `opts` - Keyword list with:
    - `llm` - Required. LLM callback function
    - `context` - Initial context map (default: %{})

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
        do_run(agent, llm, context, nesting_depth, remaining_turns, mission_deadline)
      end
    end
  end

  # Helper to continue run after checks
  defp do_run(agent, llm, context, nesting_depth, remaining_turns, mission_deadline) do
    # Calculate mission deadline if mission_timeout is set and not already inherited
    calculated_deadline = mission_deadline || calculate_mission_deadline(agent.mission_timeout)

    # Expand template in prompt
    expanded_prompt = expand_template(agent.prompt, context)

    initial_state = %{
      turn: 1,
      messages: [%{role: :user, content: expanded_prompt}],
      context: context,
      trace: [],
      start_time: System.monotonic_time(:millisecond),
      memory: %{},
      last_fail: nil,
      nesting_depth: nesting_depth,
      remaining_turns: remaining_turns,
      mission_deadline: calculated_deadline
    }

    loop(agent, llm, initial_state)
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
        trace: Enum.reverse(state.trace)
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
        trace: Enum.reverse(state.trace)
    }

    {:error, step_with_metrics}
  end

  # Main loop iteration
  defp loop(agent, llm, state) do
    # Check mission timeout before each turn
    if state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) do
      duration_ms = System.monotonic_time(:millisecond) - state.start_time
      step = Step.error(:timeout, "Mission timeout exceeded", state.memory)

      step_with_metrics = %{
        step
        | usage: %{
            duration_ms: duration_ms,
            memory_bytes: 0,
            turns: state.turn - 1
          },
          trace: Enum.reverse(state.trace)
      }

      {:error, step_with_metrics}
    else
      # Build LLM input
      llm_input = %{
        system: build_system_prompt(),
        messages: state.messages,
        turn: state.turn,
        tool_names: Map.keys(agent.tools)
      }

      # Call LLM
      case call_llm(llm, llm_input) do
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
              trace: Enum.reverse(state.trace)
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
    # Add last_fail to context if present
    exec_context =
      if state.last_fail do
        Map.put(state.context, :fail, state.last_fail)
      else
        state.context
      end

    # Merge system tools (return/fail) with user tools
    system_tools = %{
      "return" => fn args -> args end,
      "fail" => fn args -> args end
    }

    all_tools = Map.merge(system_tools, agent.tools)

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
            trace: Enum.reverse([trace_entry | state.trace])
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
            trace: Enum.reverse([trace_entry | state.trace])
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
                trace: Enum.reverse([trace_entry | state.trace])
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
    Regex.replace(~r/\{\{\s*(\w+)\s*\}\}/, prompt, fn _, key ->
      try do
        # Try as atom first, then as string
        context
        |> Map.get(String.to_existing_atom(key), Map.get(context, key, "{{#{key}}}"))
        |> to_string()
      rescue
        ArgumentError ->
          # String.to_existing_atom failed, try as string key
          context
          |> Map.get(key, "{{#{key}}}")
          |> to_string()
      end
    end)
  end

  # System prompt generation - intentionally minimal for now.
  # See issue #374 for future enhancements (context-aware prompts, tool documentation, etc.)
  defp build_system_prompt do
    """
    You are an AI that solves tasks by writing PTC-Lisp programs.
    Output your program in a ```clojure code block.
    """
  end

  # Call the LLM (function or atom)
  defp call_llm(llm, input) when is_function(llm) do
    llm.(input)
  end

  defp call_llm(llm, _input) when is_atom(llm) do
    # For now, atoms are not supported (registry support comes later)
    {:error, :llm_atom_not_supported}
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
end
