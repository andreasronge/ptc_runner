defmodule PtcRunner.SubAgent.Loop.TextMode do
  @moduledoc """
  Unified execution loop for text output mode.

  Text mode auto-detects the appropriate behavior from two signals:

  | Tools? | Return type | Behavior |
  |--------|-------------|----------|
  | No  | `:string` or none | Raw text response (single LLM call) |
  | No  | complex type | JSON response (validated against signature) |
  | Yes | `:string` or none | Tool loop → text answer |
  | Yes | complex type | Tool loop → JSON answer |

  This module replaces the former `JsonMode` and `ToolCallingMode`.
  """

  alias PtcRunner.Prompts
  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop.{JsonHandler, LLMRetry, Metrics, ToolNormalizer}
  alias PtcRunner.SubAgent.{PromptExpander, Signature, Telemetry}
  alias PtcRunner.SubAgent.ToolSchema

  # ============================================================
  # Preview Prompt
  # ============================================================

  @doc """
  Generate a preview of the text mode prompts.

  Returns the system and user messages that would be sent to the LLM,
  plus tool schemas and JSON schema when applicable.
  """
  @spec preview_prompt(SubAgent.t(), map()) :: %{
          system: String.t(),
          user: String.t(),
          tool_schemas: [map()],
          schema: map() | nil
        }
  def preview_prompt(%SubAgent{} = agent, context) do
    {:ok, expanded_prompt} = PromptExpander.expand(agent.prompt, context, on_missing: :keep)

    if has_tools?(agent) do
      # Tool variant
      system_prompt = build_tool_system_prompt(agent)
      user_message = build_tool_user_message(agent, expanded_prompt, context)
      tool_schemas = ToolSchema.to_tool_definitions(agent.tools)

      schema =
        if not SubAgent.text_return?(agent) and agent.parsed_signature,
          do: Signature.to_json_schema(agent.parsed_signature),
          else: nil

      %{
        system: system_prompt,
        user: user_message,
        tool_schemas: tool_schemas,
        schema: schema
      }
    else
      if SubAgent.text_return?(agent) do
        # Text-only variant
        %{
          system: build_text_system_prompt(agent),
          user: expanded_prompt,
          tool_schemas: [],
          schema: nil
        }
      else
        # JSON-only variant
        state = %{context: context, expanded_prompt: expanded_prompt}
        user_message = build_json_user_message(agent, state)

        %{
          system: build_json_system_prompt(agent),
          user: user_message,
          tool_schemas: [],
          schema: build_schema(agent)
        }
      end
    end
  end

  # ============================================================
  # Run Entry Point
  # ============================================================

  @doc """
  Execute a SubAgent in text mode.

  Auto-detects the variant based on tools and return type, then dispatches
  to the appropriate execution path.
  """
  @spec run(SubAgent.t(), term(), map()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%SubAgent{} = agent, llm, state) do
    cond do
      has_tools?(agent) ->
        run_tool_variant(agent, llm, state)

      SubAgent.text_return?(agent) ->
        run_text_only(agent, llm, state)

      true ->
        run_json_only(agent, llm, state)
    end
  end

  # ============================================================
  # Text-Only Variant (no tools, string/no return type)
  # ============================================================

  defp run_text_only(agent, llm, state) do
    system_prompt = build_text_system_prompt(agent)

    {:ok, expanded_prompt} =
      PromptExpander.expand(agent.prompt, state.context, on_missing: :keep)

    messages = [%{role: :user, content: expanded_prompt}]

    state =
      state
      |> Map.put(:current_turn_type, :normal)
      |> Map.put(:expanded_prompt, expanded_prompt)

    Telemetry.emit([:turn, :start], %{}, %{
      agent: agent,
      turn: state.turn,
      type: :normal,
      tools_count: 0
    })

    turn_start = System.monotonic_time()

    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :text,
      cache: state.cache
    }

    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{content: content, tokens: tokens}} ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        turn =
          Metrics.build_turn(state_with_tokens, content, nil, content,
            success?: true,
            prints: [],
            tool_calls: [],
            memory: %{}
          )

        duration_ms = System.monotonic_time(:millisecond) - state.start_time
        final_messages = messages ++ [%{role: :assistant, content: content}]

        step = %Step{
          return: content,
          fail: nil,
          memory: %{},
          usage: Metrics.build_final_usage(state_with_tokens, duration_ms, 0),
          turns:
            Metrics.apply_trace_filter(
              Enum.reverse([turn | state.turns]),
              state.trace_mode,
              false
            ),
          field_descriptions: agent.field_descriptions,
          messages: build_collected_messages(state_with_tokens, final_messages),
          prompt: state.expanded_prompt,
          original_prompt: state.original_prompt,
          prints: [],
          tool_calls: []
        }

        Metrics.emit_turn_stop_immediate(
          turn,
          agent,
          state,
          turn_start,
          state_with_tokens.turn_tokens
        )

        {:ok, step}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - state.start_time
        step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", %{})

        step_with_metrics = %{
          step
          | usage: Metrics.build_final_usage(state, duration_ms, 0),
            turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
            messages: build_collected_messages(state, messages),
            prompt: state.expanded_prompt,
            original_prompt: state.original_prompt
        }

        Metrics.emit_turn_stop_immediate(nil, agent, state, turn_start, nil)
        {:error, step_with_metrics}
    end
  end

  # ============================================================
  # JSON-Only Variant (no tools, complex return type)
  # ============================================================

  defp run_json_only(agent, llm, state) do
    json_state =
      state
      |> Map.put(:schema, build_schema(agent))
      |> Map.put(:json_mode, true)

    json_driver_loop(agent, llm, json_state)
  end

  defp json_driver_loop(agent, llm, state) do
    case check_termination(agent, state) do
      {:stop, result} ->
        result

      :continue ->
        state = Map.put(state, :current_turn_type, :normal)

        Telemetry.emit([:turn, :start], %{}, %{
          agent: agent,
          turn: state.turn,
          type: :normal,
          tools_count: 0
        })

        turn_start = System.monotonic_time()

        case execute_json_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            Metrics.emit_turn_stop_immediate(
              turn,
              agent,
              state,
              turn_start,
              next_state.turn_tokens
            )

            json_driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            Metrics.emit_turn_stop_immediate(turn, agent, state, turn_start, turn_tokens)
            result
        end
    end
  end

  defp execute_json_turn(agent, llm, state) do
    system_prompt = build_json_system_prompt(agent)

    messages =
      if state.turn == 1 do
        user_message = build_json_user_message(agent, state)
        [%{role: :user, content: user_message}]
      else
        state.messages
      end

    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :text,
      schema: state.schema,
      cache: state.cache
    }

    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{content: content, tokens: tokens}} ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        json_handler_opts = [
          build_error_feedback: fn error, response ->
            build_json_error_feedback(error, response, agent)
          end
        ]

        JsonHandler.handle_json_answer(content, agent, state_with_tokens, json_handler_opts)

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - state.start_time
        step = Step.error(:llm_error, "LLM call failed: #{inspect(reason)}", %{})

        usage =
          state
          |> Metrics.build_final_usage(duration_ms, 0)
          |> add_schema_metrics(state.schema)

        step_with_metrics = %{
          step
          | usage: usage,
            turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
            messages: build_collected_messages(state, messages),
            prompt: state.expanded_prompt,
            original_prompt: state.original_prompt
        }

        {:stop, {:error, step_with_metrics}, nil, nil}
    end
  end

  # ============================================================
  # Tool Variant (with tools)
  # ============================================================

  defp run_tool_variant(agent, llm, state) do
    effective_tools = SubAgent.effective_tools(agent)
    tool_schemas = ToolSchema.to_tool_definitions(effective_tools)
    normalized_tools = ToolNormalizer.normalize(effective_tools, state, agent)

    tc_state =
      state
      |> Map.put(:tool_schemas, tool_schemas)
      |> Map.put(:normalized_tools_map, normalized_tools)
      |> Map.put(:total_tool_calls, 0)
      |> Map.put(:all_tool_calls, [])

    tool_driver_loop(agent, llm, tc_state)
  end

  defp tool_driver_loop(agent, llm, state) do
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

        case execute_tool_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            Metrics.emit_turn_stop_immediate(
              turn,
              agent,
              state,
              turn_start,
              next_state.turn_tokens
            )

            tool_driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            Metrics.emit_turn_stop_immediate(turn, agent, state, turn_start, turn_tokens)
            result
        end
    end
  end

  defp execute_tool_turn(agent, llm, state) do
    system_prompt = build_tool_system_prompt(agent)

    messages =
      if state.turn == 1 do
        expanded_prompt =
          PromptExpander.expand(agent.prompt, state.context, on_missing: :keep)
          |> elem(1)

        user_msg = build_tool_user_message(agent, expanded_prompt, state.context)
        [%{role: :user, content: user_msg}]
      else
        state.messages
      end

    # Tool variants never send schema in llm_input (tool loop owns JSON validation)
    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :text,
      tools: state.tool_schemas,
      cache: state.cache
    }

    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{tool_calls: tool_calls} = response}
      when is_list(tool_calls) and tool_calls != [] ->
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
    tool_calls_with_ids =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {tc, idx} ->
        Map.put_new(tc, :id, "tc_#{state.total_tool_calls + idx + 1}")
      end)

    new_total = state.total_tool_calls + length(tool_calls_with_ids)

    {calls_to_execute, limit_exceeded} =
      if agent.max_tool_calls && new_total > agent.max_tool_calls do
        remaining = max(0, agent.max_tool_calls - state.total_tool_calls)
        {Enum.take(tool_calls_with_ids, remaining), true}
      else
        {tool_calls_with_ids, false}
      end

    {tool_results, current_turn_calls} =
      Enum.map_reduce(calls_to_execute, [], fn tc, acc ->
        tool_name = tc.name
        tool_args = tc.args || %{}
        tool_id = tc.id

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

    all_tool_calls = Enum.reverse(current_turn_calls) ++ state.all_tool_calls

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

    assistant_msg = %{
      role: :assistant,
      content: assistant_content || "",
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
  # Final Answer Handling (tool variant)
  # ============================================================

  defp handle_final_answer(content, agent, state) do
    if SubAgent.text_return?(agent) do
      # Text return: raw string as step.return
      {turn, step} = build_tool_text_success_step(content, state, agent)
      {:stop, {:ok, step}, turn, state.turn_tokens}
    else
      # JSON return: parse and validate
      json_handler_opts = [all_tool_calls: Enum.reverse(state.all_tool_calls)]
      JsonHandler.handle_json_answer(content, agent, state, json_handler_opts)
    end
  end

  defp build_tool_text_success_step(text_content, state, agent) do
    turn =
      Metrics.build_turn(state, text_content, nil, text_content,
        success?: true,
        prints: [],
        tool_calls: Enum.reverse(state.all_tool_calls),
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    final_messages = state.messages ++ [%{role: :assistant, content: text_content}]

    step = %Step{
      return: text_content,
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

    {turn, step}
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
      {_, step} = build_tool_error_step(:empty_response, error, "", state, agent)
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
  # Shared Helpers
  # ============================================================

  defp has_tools?(%SubAgent{} = agent) do
    map_size(SubAgent.effective_tools(agent)) > 0
  end

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

  defp mission_timeout_exceeded?(deadline) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
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
  # Prompt Building
  # ============================================================

  # Text-only system prompt
  defp build_text_system_prompt(%{system_prompt: nil}), do: "You are a helpful assistant."
  defp build_text_system_prompt(%{system_prompt: override}) when is_binary(override), do: override

  defp build_text_system_prompt(%{system_prompt: transformer}) when is_function(transformer, 1) do
    transformer.("You are a helpful assistant.")
  end

  defp build_text_system_prompt(%{system_prompt: opts}) when is_map(opts) do
    base = "You are a helpful assistant."
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp build_text_system_prompt(_), do: "You are a helpful assistant."

  # JSON-only system prompt
  defp build_json_system_prompt(%{system_prompt: nil}), do: Prompts.json_system()
  defp build_json_system_prompt(%{system_prompt: override}) when is_binary(override), do: override

  defp build_json_system_prompt(%{system_prompt: transformer}) when is_function(transformer, 1) do
    transformer.(Prompts.json_system())
  end

  defp build_json_system_prompt(%{system_prompt: opts}) when is_map(opts) do
    base = Prompts.json_system()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp build_json_system_prompt(_), do: Prompts.json_system()

  # Tool system prompt (with text or JSON output instruction)
  defp build_tool_system_prompt(%{system_prompt: nil}), do: Prompts.tool_calling_system()

  defp build_tool_system_prompt(%{system_prompt: override}) when is_binary(override), do: override

  defp build_tool_system_prompt(%{system_prompt: transformer}) when is_function(transformer, 1) do
    transformer.(Prompts.tool_calling_system())
  end

  defp build_tool_system_prompt(%{system_prompt: opts}) when is_map(opts) do
    base = Prompts.tool_calling_system()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp build_tool_system_prompt(_), do: Prompts.tool_calling_system()

  # Tool user message
  defp build_tool_user_message(agent, expanded_prompt, context) do
    parts = []

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

    output_instruction = build_tool_output_instruction(agent)
    parts = parts ++ ["<output_format>\n#{output_instruction}\n</output_format>"]
    parts = parts ++ ["<mission>\n#{expanded_prompt}\n</mission>"]

    Enum.join(parts, "\n\n")
  end

  defp build_tool_output_instruction(agent) do
    if SubAgent.text_return?(agent) do
      "When you have the final answer, return it as plain text."
    else
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
  end

  # JSON user message (no tools)
  defp build_json_user_message(agent, state) do
    output_instruction = format_output_instruction(agent)
    field_descriptions = format_field_descriptions(agent)
    example_output = format_example_output(agent)

    Prompts.json_user()
    |> String.replace("{{task}}", state.expanded_prompt)
    |> String.replace("{{output_instruction}}", output_instruction)
    |> String.replace("{{field_descriptions}}", field_descriptions)
    |> String.replace("{{example_output}}", example_output)
  end

  defp format_output_instruction(%{parsed_signature: nil}) do
    "Return a JSON object with these fields:"
  end

  defp format_output_instruction(%{parsed_signature: {:signature, _params, {:list, _}}}) do
    "Return a JSON array:"
  end

  defp format_output_instruction(%{parsed_signature: {:signature, _params, _return_type}}) do
    "Return a JSON object with these fields:"
  end

  defp format_field_descriptions(%{parsed_signature: nil}) do
    "(any valid JSON object)"
  end

  defp format_field_descriptions(%{parsed_signature: {:signature, _params, return_type}} = agent) do
    format_type_description(return_type, agent.field_descriptions || %{})
  end

  defp format_type_description({:map, fields}, field_descriptions) do
    Enum.map_join(fields, "\n", fn {name, type} ->
      type_str = format_type_name(type)
      desc = Map.get(field_descriptions, String.to_atom(name), "")
      desc_part = if desc != "", do: " - #{desc}", else: ""
      "- `#{name}` (#{type_str})#{desc_part}"
    end)
  end

  defp format_type_description(:any, _field_descriptions) do
    "(Return your response directly as a JSON object - no wrapper needed)"
  end

  defp format_type_description(type, _field_descriptions) do
    "(#{format_type_name(type)})"
  end

  defp format_type_name(:string), do: "string"
  defp format_type_name(:int), do: "integer"
  defp format_type_name(:float), do: "number"
  defp format_type_name(:bool), do: "boolean"
  defp format_type_name(:keyword), do: "string"
  defp format_type_name(:any), do: "any"
  defp format_type_name(:map), do: "object"
  defp format_type_name({:list, inner}), do: "array of #{format_type_name(inner)}"
  defp format_type_name({:optional, inner}), do: "#{format_type_name(inner)} (optional)"
  defp format_type_name({:map, _fields}), do: "object"

  defp format_example_output(%{parsed_signature: nil}) do
    ~s|{"field": "value"}|
  end

  defp format_example_output(%{parsed_signature: {:signature, _params, return_type}}) do
    example = build_example_value(return_type)
    Jason.encode!(example, pretty: true)
  end

  defp build_example_value(:string), do: "..."
  defp build_example_value(:int), do: 0
  defp build_example_value(:float), do: 0.0
  defp build_example_value(:bool), do: true
  defp build_example_value(:keyword), do: "keyword"
  defp build_example_value(:any), do: %{"key" => "value", "data" => "..."}
  defp build_example_value(:map), do: %{}
  defp build_example_value({:list, inner}), do: [build_example_value(inner)]
  defp build_example_value({:optional, inner}), do: build_example_value(inner)

  defp build_example_value({:map, fields}) do
    fields
    |> Enum.map(fn {name, type} -> {name, build_example_value(type)} end)
    |> Map.new()
  end

  # ============================================================
  # Schema Building
  # ============================================================

  defp build_schema(%{schema: schema}) when is_map(schema), do: schema

  defp build_schema(%{parsed_signature: sig}) when not is_nil(sig),
    do: Signature.to_json_schema(sig)

  defp build_schema(_), do: nil

  # ============================================================
  # Error Feedback
  # ============================================================

  defp build_json_error_feedback(error, invalid_response, agent) do
    expected_format = format_example_output(agent)

    Prompts.json_error()
    |> String.replace("{{error_message}}", to_string(error))
    |> String.replace("{{invalid_response}}", truncate(invalid_response, 500))
    |> String.replace("{{expected_format}}", expected_format)
  end

  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string

  defp truncate(string, max_length) do
    String.slice(string, 0, max_length) <> "..."
  end

  # ============================================================
  # Step Building (tool variant)
  # ============================================================

  defp build_tool_error_step(reason, message, response, state, _agent) do
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

    usage =
      state
      |> Metrics.build_final_usage(duration_ms, 0, -1)
      |> add_schema_metrics(state[:schema])

    step_with_metrics = %{
      step
      | usage: usage,
        turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
        messages: build_collected_messages(state, state.messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt,
        tools: state[:normalized_tools]
    }

    {:error, step_with_metrics}
  end

  # ============================================================
  # Message Collection
  # ============================================================

  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = Map.get(state, :current_system_prompt, "")
    [%{role: :system, content: system_prompt} | messages]
  end

  defp add_schema_metrics(usage, schema) when is_map(schema) do
    schema_json = Jason.encode!(schema)

    usage
    |> Map.put(:schema_used, true)
    |> Map.put(:schema_bytes, byte_size(schema_json))
  end

  defp add_schema_metrics(usage, _), do: Map.put(usage, :schema_used, false)
end
