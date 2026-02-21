defmodule PtcRunner.SubAgent.Loop.ToolCallingMode do
  @moduledoc """
  Execution loop for native tool calling mode.

  Tool calling mode uses provider-native tool calling APIs (OpenAI function_calling,
  Anthropic tool_use) instead of PTC-Lisp. ptc_runner owns the tool execution loop:
  calling tools, recording results, and feeding them back to the LLM.

  ## Flow

  1. Build tool schemas from agent.tools via ToolSchema
  2. Build system prompt from tool-calling-system.md template
  3. Build first user message (mission + context data)
  4. Enter driver loop:
     a. Check termination (max_turns, turn_budget, mission_timeout)
     b. Call LLM with tools
     c. If tool_calls present → execute tools → append messages → continue
     d. If content only → parse JSON → validate signature → return Step
     e. Neither → error feedback, retry

  ## Differences from PTC-Lisp Mode

  | Aspect | PTC-Lisp | Tool Calling |
  |--------|----------|-------------|
  | System prompt | Full spec + tool docs | Minimal (tool-calling-system.md) |
  | Tool invocation | LLM writes Lisp code | Provider-native tool calls |
  | Execution | Lisp.run/2 | Direct function calls |
  | Memory | Accumulated | Always `%{}` |

  This is an internal module called by `SubAgent.run/2` when `output: :tool_calling`.
  """

  alias PtcRunner.Prompts
  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{JsonParser, KeyNormalizer, PromptExpander, Signature, Telemetry}
  alias PtcRunner.SubAgent.Loop.{LLMRetry, Metrics, ToolNormalizer}
  alias PtcRunner.SubAgent.ToolSchema

  @doc """
  Generate a preview of the tool calling mode prompts.

  Returns the system and user messages that would be sent to the LLM,
  plus the tool schemas and JSON schema for the return type.
  """
  @spec preview_prompt(SubAgent.t(), map()) :: %{
          system: String.t(),
          user: String.t(),
          tool_schemas: [map()],
          schema: map() | nil
        }
  def preview_prompt(%SubAgent{} = agent, context) do
    alias PtcRunner.SubAgent.PromptExpander

    {:ok, expanded_prompt} = PromptExpander.expand(agent.prompt, context, on_missing: :keep)

    system_prompt = build_system_prompt(agent)
    user_message = build_user_message(agent, expanded_prompt, context)
    tool_schemas = ToolSchema.to_tool_definitions(agent.tools)

    schema =
      if agent.parsed_signature,
        do: Signature.to_json_schema(agent.parsed_signature),
        else: nil

    %{
      system: system_prompt,
      user: user_message,
      tool_schemas: tool_schemas,
      schema: schema
    }
  end

  @doc """
  Execute a SubAgent in tool calling mode.

  ## Parameters

  - `agent` - A `%SubAgent{}` struct with `output: :tool_calling`
  - `llm` - LLM callback function
  - `state` - Initial loop state from Loop.run/2

  ## Returns

  - `{:ok, Step.t()}` on success
  - `{:error, Step.t()}` on failure
  """
  @spec run(SubAgent.t(), term(), map()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%SubAgent{} = agent, llm, state) do
    effective_tools = SubAgent.effective_tools(agent)

    # Build tool schemas for API
    tool_schemas = ToolSchema.to_tool_definitions(effective_tools)

    # Normalize tools for execution (wraps with telemetry, etc.)
    normalized_tools = ToolNormalizer.normalize(effective_tools, state, agent)

    tc_state =
      state
      |> Map.put(:tool_schemas, tool_schemas)
      |> Map.put(:normalized_tools_map, normalized_tools)
      |> Map.put(:total_tool_calls, 0)
      |> Map.put(:all_tool_calls, [])

    driver_loop(agent, llm, tc_state)
  end

  # ============================================================
  # Termination Checks
  # ============================================================

  defp check_termination(agent, state) do
    cond do
      state.turn > agent.max_turns ->
        {:stop,
         build_termination_error(
           :max_turns_exceeded,
           "Exceeded max_turns limit of #{agent.max_turns}",
           state
         )}

      state.remaining_turns <= 0 ->
        {:stop, build_termination_error(:turn_budget_exhausted, "Turn budget exhausted", state)}

      state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) ->
        {:stop, build_termination_error(:mission_timeout, "Mission timeout exceeded", state)}

      true ->
        :continue
    end
  end

  # ============================================================
  # Driver Loop
  # ============================================================

  defp driver_loop(agent, llm, state) do
    case check_termination(agent, state) do
      {:stop, result} ->
        result

      :continue ->
        state = Map.put(state, :current_turn_type, :normal)

        Telemetry.emit([:turn, :start], %{}, %{
          agent: agent,
          turn: state.turn,
          type: :normal,
          tools_count: map_size(agent.tools)
        })

        turn_start = System.monotonic_time()

        case execute_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            Metrics.emit_turn_stop_immediate(
              turn,
              agent,
              state,
              turn_start,
              next_state.turn_tokens
            )

            driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            Metrics.emit_turn_stop_immediate(turn, agent, state, turn_start, turn_tokens)
            result
        end
    end
  end

  # ============================================================
  # Turn Execution
  # ============================================================

  defp execute_turn(agent, llm, state) do
    system_prompt = build_system_prompt(agent)

    # Build messages for first turn or reuse accumulated
    messages =
      if state.turn == 1 do
        expanded_prompt =
          PromptExpander.expand(agent.prompt, state.context, on_missing: :keep)
          |> elem(1)

        user_msg = build_user_message(agent, expanded_prompt, state.context)
        [%{role: :user, content: user_msg}]
      else
        state.messages
      end

    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :tool_calling,
      tools: state.tool_schemas,
      cache: state.cache
    }

    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{tool_calls: tool_calls} = response} when is_list(tool_calls) and tool_calls != [] ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(response.tokens)
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        handle_tool_calls(tool_calls, response.content, agent, state_with_tokens)

      {:ok, %{content: content, tokens: tokens}} when is_binary(content) ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        handle_final_answer(content, agent, state_with_tokens)

      {:ok, %{content: nil, tool_calls: nil}} ->
        # Neither content nor tool_calls
        state_with_tokens =
          state
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        handle_empty_response(agent, state_with_tokens)

      {:ok, %{content: nil}} ->
        state_with_tokens =
          state
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        handle_empty_response(agent, state_with_tokens)

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - state.start_time
        step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", %{})

        step_with_metrics = %{
          step
          | usage: Metrics.build_final_usage(state, duration_ms, 0),
            turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
            messages: build_collected_messages(state, messages),
            prompt: state.expanded_prompt,
            original_prompt: state.original_prompt,
            tools: state.normalized_tools
        }

        {:stop, {:error, step_with_metrics}, nil, nil}
    end
  end

  # ============================================================
  # Tool Call Execution
  # ============================================================

  defp handle_tool_calls(tool_calls, assistant_content, agent, state) do
    # Ensure each tool call has an id
    tool_calls_with_ids =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {tc, idx} ->
        Map.put_new(tc, :id, "tc_#{state.total_tool_calls + idx + 1}")
      end)

    # Check max_tool_calls limit
    new_total = state.total_tool_calls + length(tool_calls_with_ids)

    {calls_to_execute, limit_exceeded} =
      if agent.max_tool_calls && new_total > agent.max_tool_calls do
        remaining = max(0, agent.max_tool_calls - state.total_tool_calls)
        {Enum.take(tool_calls_with_ids, remaining), true}
      else
        {tool_calls_with_ids, false}
      end

    # Execute tools sequentially and collect results
    {tool_results, current_turn_calls} =
      Enum.map_reduce(calls_to_execute, [], fn tc, acc ->
        tool_name = tc.name
        tool_args = tc.args || %{}
        tool_id = tc.id

        # If the provider flagged malformed JSON arguments, surface the error
        {result_str, step_entry} =
          case Map.get(tc, :args_error) do
            nil ->
              execute_single_tool(tool_name, tool_args, state)

            error_msg ->
              result_str = Jason.encode!(%{"error" => error_msg})

              step_entry = %{
                name: tool_name,
                args: tool_args,
                result: nil,
                error: error_msg,
                timestamp: DateTime.utc_now(),
                duration_ms: 0
              }

              {result_str, step_entry}
          end

        tool_result_msg = %{
          role: :tool,
          tool_call_id: tool_id,
          content: result_str
        }

        {tool_result_msg, [step_entry | acc]}
      end)

    # current_turn_calls: only this turn's calls (for metrics/trace)
    # all_tool_calls: full history across all turns (for final Step)
    all_tool_calls = Enum.reverse(current_turn_calls) ++ state.all_tool_calls

    # Add limit exceeded error if needed
    tool_results =
      if limit_exceeded do
        skipped = Enum.drop(tool_calls_with_ids, length(calls_to_execute))

        limit_msgs =
          Enum.map(skipped, fn tc ->
            %{
              role: :tool,
              tool_call_id: tc.id,
              content:
                Jason.encode!(%{
                  "error" => "Tool call limit reached (max: #{agent.max_tool_calls})"
                })
            }
          end)

        tool_results ++ limit_msgs
      else
        tool_results
      end

    # Build assistant message with tool calls
    assistant_msg = %{
      role: :assistant,
      content: assistant_content,
      tool_calls:
        Enum.map(tool_calls_with_ids, fn tc ->
          %{
            id: tc.id,
            type: "function",
            function: %{
              name: tc.name,
              arguments: if(is_binary(tc.args), do: tc.args, else: Jason.encode!(tc.args || %{}))
            }
          }
        end)
    }

    # Build turn for trace — only include this turn's calls
    turn =
      Metrics.build_turn(state, inspect(tool_calls_with_ids), nil, nil,
        success?: true,
        prints: [],
        tool_calls: Enum.reverse(current_turn_calls),
        memory: %{}
      )

    new_state = %{
      state
      | turn: state.turn + 1,
        messages: state.messages ++ [assistant_msg | tool_results],
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        total_tool_calls:
          state.total_tool_calls + length(calls_to_execute) +
            if(limit_exceeded,
              do: length(tool_calls_with_ids) - length(calls_to_execute),
              else: 0
            ),
        all_tool_calls: all_tool_calls,
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  defp execute_single_tool(tool_name, tool_args, state) do
    start = System.monotonic_time(:millisecond)

    {result_str, result, error} =
      case Map.fetch(state.normalized_tools_map, tool_name) do
        {:ok, tool_fn} when is_function(tool_fn, 1) ->
          try do
            result = tool_fn.(tool_args)
            {encode_tool_result(result), result, nil}
          rescue
            e ->
              error_msg = Exception.message(e)
              {Jason.encode!(%{"error" => error_msg}), nil, error_msg}
          end

        {:ok, {tool_fn, _opts}} when is_function(tool_fn, 1) ->
          try do
            result = tool_fn.(tool_args)
            {encode_tool_result(result), result, nil}
          rescue
            e ->
              error_msg = Exception.message(e)
              {Jason.encode!(%{"error" => error_msg}), nil, error_msg}
          end

        _ ->
          error_msg = "Tool '#{tool_name}' not found"
          {Jason.encode!(%{"error" => error_msg}), nil, error_msg}
      end

    duration_ms = System.monotonic_time(:millisecond) - start

    step_entry = %{
      name: tool_name,
      args: tool_args,
      result: result,
      error: error,
      timestamp: DateTime.utc_now(),
      duration_ms: duration_ms
    }

    {result_str, step_entry}
  end

  defp encode_tool_result(result) do
    case Jason.encode(result) do
      {:ok, json} -> json
      {:error, _} -> inspect(result, limit: 500)
    end
  end

  # ============================================================
  # Final Answer Handling
  # ============================================================

  defp handle_final_answer(content, agent, state) do
    case JsonParser.parse(content) do
      {:ok, parsed} when is_map(parsed) ->
        # Check if this is a wrapped array response (e.g. {"items": [...]})
        if signature_expects_list?(agent.parsed_signature) do
          case Map.get(parsed, "items") || Map.get(parsed, :items) do
            items when is_list(items) ->
              validate_and_complete_list(items, content, agent, state)

            _ ->
              handle_parse_error(
                "Expected {\"items\": [...]} wrapper for array response",
                content,
                agent,
                state
              )
          end
        else
          validate_and_complete(parsed, content, agent, state)
        end

      {:ok, parsed} when is_list(parsed) ->
        if signature_expects_list?(agent.parsed_signature) do
          validate_and_complete_list(parsed, content, agent, state)
        else
          handle_parse_error(
            "Response must be a JSON object, not an array",
            content,
            agent,
            state
          )
        end

      {:ok, _primitive} ->
        handle_parse_error(
          "Response must be a JSON object",
          content,
          agent,
          state
        )

      {:error, :no_json_found} ->
        handle_parse_error("No valid JSON found in response", content, agent, state)

      {:error, :invalid_json} ->
        handle_parse_error("JSON parse error", content, agent, state)
    end
  end

  defp signature_expects_list?(nil), do: false
  defp signature_expects_list?({:signature, _params, {:list, _}}), do: true
  defp signature_expects_list?(_), do: false

  defp validate_and_complete(parsed, response, agent, state) do
    atomized = atomize_keys(parsed, agent.parsed_signature)

    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state)
    end
  end

  defp validate_and_complete_list(parsed, response, agent, state) do
    atomized = atomize_list(parsed, agent.parsed_signature)

    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state)
    end
  end

  defp handle_empty_response(agent, state) do
    error = "LLM returned neither content nor tool calls"

    turn =
      Metrics.build_turn(state, "", nil, %{error: error},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    if state.turn >= agent.max_turns do
      {_, step} = build_error_step(:empty_response, error, "", state, agent)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      new_state = %{
        state
        | turn: state.turn + 1,
          messages:
            state.messages ++
              [
                %{
                  role: :user,
                  content: "Error: #{error}. Please use tools or return a final answer."
                }
              ],
          turns: [turn | state.turns],
          remaining_turns: state.remaining_turns - 1,
          turn_tokens: state.turn_tokens
      }

      {:continue, new_state, turn}
    end
  end

  # ============================================================
  # Validation and Error Handling
  # ============================================================

  defp validate_return(%{parsed_signature: nil}, _value), do: :ok
  defp validate_return(%{parsed_signature: {:signature, _, :any}}, _value), do: :ok

  defp validate_return(%{parsed_signature: parsed_sig}, value) do
    Signature.validate(parsed_sig, value)
  end

  defp handle_parse_error(error, response, agent, state) do
    if state.turn >= agent.max_turns do
      {turn, step} = build_error_step(:json_parse_error, error, response, state, agent)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      retry_with_feedback(error, response, agent, state)
    end
  end

  defp handle_validation_error(errors, response, agent, state) do
    error_msg = format_validation_errors(errors)

    if state.turn >= agent.max_turns do
      {turn, step} = build_error_step(:validation_error, error_msg, response, state, agent)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      retry_with_feedback(error_msg, response, agent, state)
    end
  end

  defp retry_with_feedback(error, response, _agent, state) do
    turn =
      Metrics.build_turn(state, response, nil, %{error: error},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    feedback =
      "Error: #{error}. Please return a valid JSON object matching the expected output format."

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
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
      path_str = if path == [], do: "root", else: Enum.join(path, ".")
      "#{path_str}: #{message}"
    end)
  end

  # ============================================================
  # Step Building
  # ============================================================

  defp build_success_step(return_value, response, state, agent) do
    normalized_return = KeyNormalizer.normalize_keys(return_value)

    turn =
      Metrics.build_turn(state, response, nil, normalized_return,
        success?: true,
        prints: [],
        tool_calls: Enum.reverse(state.all_tool_calls),
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    final_step = %Step{
      return: normalized_return,
      fail: nil,
      memory: %{},
      usage: Metrics.build_final_usage(state, duration_ms, 0),
      turns:
        Metrics.apply_trace_filter(
          Enum.reverse([turn | state.turns]),
          state.trace_mode,
          false
        ),
      field_descriptions: agent.field_descriptions,
      messages: build_collected_messages(state, final_messages),
      prompt: state.expanded_prompt,
      original_prompt: state.original_prompt,
      tools: state.normalized_tools,
      prints: [],
      tool_calls: Enum.reverse(state.all_tool_calls)
    }

    {turn, final_step}
  end

  defp build_error_step(reason, message, response, state, _agent) do
    turn =
      Metrics.build_turn(state, response, nil, %{error: message},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    error_step = Step.error(reason, message, %{})
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    final_step = %{
      error_step
      | usage: Metrics.build_final_usage(state, duration_ms, 0),
        turns:
          Metrics.apply_trace_filter(
            Enum.reverse([turn | state.turns]),
            state.trace_mode,
            true
          ),
        messages: build_collected_messages(state, final_messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt
    }

    {turn, final_step}
  end

  defp build_termination_error(reason, message, state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.error(reason, message, %{})

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

  # ============================================================
  # Prompt Building
  # ============================================================

  defp build_system_prompt(%{system_prompt: nil}), do: Prompts.tool_calling_system()
  defp build_system_prompt(%{system_prompt: override}) when is_binary(override), do: override

  defp build_system_prompt(%{system_prompt: transformer}) when is_function(transformer, 1) do
    transformer.(Prompts.tool_calling_system())
  end

  defp build_system_prompt(%{system_prompt: opts}) when is_map(opts) do
    base = Prompts.tool_calling_system()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp build_system_prompt(_), do: Prompts.tool_calling_system()

  defp build_user_message(agent, expanded_prompt, context) do
    parts = []

    # Add context data descriptions if present
    parts =
      if map_size(context) > 0 do
        data_section =
          Enum.map_join(context, "\n", fn {k, v} ->
            desc =
              if agent.context_descriptions,
                do: Map.get(agent.context_descriptions, k, ""),
                else: ""

            value_preview = inspect(v, limit: 100, printable_limit: 200)

            if desc != "",
              do: "- #{k}: #{desc} = #{value_preview}",
              else: "- #{k} = #{value_preview}"
          end)

        parts ++ ["<context_data>\n#{data_section}\n</context_data>"]
      else
        parts
      end

    # Add output format instruction
    output_instruction = build_output_instruction(agent)
    parts = parts ++ ["<output_format>\n#{output_instruction}\n</output_format>"]

    # Add mission
    parts = parts ++ ["<mission>\n#{expanded_prompt}\n</mission>"]

    Enum.join(parts, "\n\n")
  end

  defp build_output_instruction(agent) do
    case agent.parsed_signature do
      {:signature, _params, {:list, _} = return_type} ->
        schema = Signature.type_to_json_schema(return_type)

        "When you have the final answer, return a JSON array matching this schema:\n#{Jason.encode!(schema, pretty: true)}"

      {:signature, _params, return_type} ->
        schema = Signature.type_to_json_schema(return_type)

        "When you have the final answer, return a JSON object matching this schema:\n#{Jason.encode!(schema, pretty: true)}"

      nil ->
        "When you have the final answer, return a valid JSON object."
    end
  end

  # ============================================================
  # LLM Calling
  # ============================================================

  defp call_llm_with_telemetry(llm, input, state, agent) do
    start_meta = %{agent: agent, turn: state.turn, messages: input.messages}

    Telemetry.span([:llm], start_meta, fn ->
      result = LLMRetry.call_with_retry(llm, input, state.llm_registry, state.llm_retry)

      {extra_measurements, stop_meta} =
        case result do
          {:ok, %{tool_calls: [_ | _], tokens: tokens}} ->
            measurements = Metrics.build_token_measurements(tokens)
            meta = %{agent: agent, turn: state.turn, response: "tool_calls"}
            {measurements, meta}

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

  # ============================================================
  # Message Collection
  # ============================================================

  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = Map.get(state, :current_system_prompt, Prompts.tool_calling_system())
    [%{role: :system, content: system_prompt} | messages]
  end

  # ============================================================
  # Key Atomization (shared with JsonMode)
  # ============================================================

  defp atomize_keys(map, nil) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_atom(k), else: k
      {key, atomize_value(v, nil)}
    end)
  end

  defp atomize_keys(map, {:signature, _params, return_type}) when is_map(map) do
    atomize_value(map, return_type)
  end

  defp atomize_list(list, {:signature, _params, {:list, inner_type}}) when is_list(list) do
    Enum.map(list, &atomize_value(&1, inner_type))
  end

  defp atomize_list(list, _) when is_list(list), do: list

  defp atomize_value(map, {:map, fields}) when is_map(map) do
    field_types = Map.new(fields)

    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_atom(k), else: k
      field_type = Map.get(field_types, to_string(key)) || Map.get(field_types, k)
      {key, atomize_value(v, field_type)}
    end)
  end

  defp atomize_value(list, {:list, inner_type}) when is_list(list) do
    Enum.map(list, &atomize_value(&1, inner_type))
  end

  defp atomize_value(value, {:optional, inner_type}) do
    atomize_value(value, inner_type)
  end

  defp atomize_value(map, _type) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_atom(k), else: k
      {key, atomize_value(v, nil)}
    end)
  end

  defp atomize_value(list, _type) when is_list(list) do
    Enum.map(list, &atomize_value(&1, nil))
  end

  defp atomize_value(value, _type), do: value

  defp safe_to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp mission_timeout_exceeded?(deadline) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end
end
