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

  require Logger

  alias PtcRunner.{Lisp, PtcToolProtocol}
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Prompts
  alias PtcRunner.Step
  alias PtcRunner.SubAgent.BuiltinTools
  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.Exposure
  alias PtcRunner.SubAgent.KeyNormalizer

  alias PtcRunner.SubAgent.Loop.{
    Budget,
    JsonHandler,
    LLMRetry,
    Metrics,
    NativePreview,
    ResponseHandler,
    ToolNormalizer,
    TurnFeedback
  }

  alias PtcRunner.SubAgent.{PromptExpander, Signature, Telemetry}
  alias PtcRunner.SubAgent.ToolSchema
  alias PtcRunner.Tool

  @ptc_lisp_execute_name "ptc_lisp_execute"

  # ============================================================
  # Preview Prompt
  # ============================================================

  @doc """
  Generate a preview of the text mode prompts.

  Returns the system and user messages that would be sent to the LLM,
  plus tool schemas and JSON schema when applicable.
  """
  @spec preview_prompt(Definition.t(), map()) :: %{
          system: String.t(),
          user: String.t(),
          tool_schemas: [map()],
          schema: map() | nil
        }
  def preview_prompt(%Definition{} = agent, context) do
    {:ok, expanded_prompt} = PromptExpander.expand(agent.prompt, context, on_missing: :keep)

    if has_tools?(agent) do
      # Tool variant
      system_prompt = build_tool_system_prompt(agent)
      user_message = build_tool_user_message(agent, expanded_prompt, context)
      tool_schemas = ToolSchema.to_tool_definitions(agent.tools)

      schema =
        if not Definition.text_return?(agent) and agent.parsed_signature,
          do: Signature.to_json_schema(agent.parsed_signature),
          else: nil

      %{
        system: system_prompt,
        user: user_message,
        tool_schemas: tool_schemas,
        schema: schema
      }
    else
      if Definition.text_return?(agent) do
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
  @spec run(Definition.t(), term(), map()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%Definition{} = agent, llm, state) do
    result =
      cond do
        # Tier 3a: combined mode always goes through the tool variant
        # because `ptc_lisp_execute` is always present in the request
        # `tools` field, even when zero app tools are configured.
        combined_mode?(agent) ->
          run_tool_variant(agent, llm, state)

        has_tools?(agent) ->
          run_tool_variant(agent, llm, state)

        Definition.text_return?(agent) ->
          run_text_only(agent, llm, state)

        true ->
          run_json_only(agent, llm, state)
      end

    stamp_agent_name(result, state)
  end

  defp stamp_agent_name({status, step}, state) do
    {status, %{step | name: state.agent_name}}
  end

  # ============================================================
  # Text-Only Variant (no tools, string/no return type)
  # ============================================================

  defp run_text_only(agent, llm, state) do
    system_prompt = build_text_system_prompt(agent)

    {:ok, expanded_prompt} =
      PromptExpander.expand(agent.prompt, state.context, on_missing: :keep)

    messages = (state.initial_messages || []) ++ [%{role: :user, content: expanded_prompt}]

    state = %{state | current_turn_type: :normal, expanded_prompt: expanded_prompt}

    Telemetry.emit([:turn, :start], %{}, %{
      agent_name: agent.name,
      agent_id: state.agent_id,
      turn: state.turn,
      type: :normal,
      tools_count: 0
    })

    turn_start = System.monotonic_time()

    # Wrap on_chunk with call tracking for graceful degradation
    {was_streamed?, tracked_on_chunk} = track_on_chunk(state.on_chunk)

    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :text,
      cache: state.cache
    }

    # Add stream callback to request when on_chunk is set
    llm_input =
      if tracked_on_chunk, do: Map.put(llm_input, :stream, tracked_on_chunk), else: llm_input

    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{content: content, tokens: tokens}} ->
        # Graceful degradation: if callback didn't stream, fire on_chunk once
        if state.on_chunk && !was_streamed?.() do
          safe_on_chunk(state.on_chunk, content)
        end

        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> then(&%{&1 | current_messages: messages, current_system_prompt: system_prompt})

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

        Metrics.emit_turn_stop_immediate(nil, state, turn_start, nil)
        {:error, step_with_metrics}
    end
  end

  # ============================================================
  # JSON-Only Variant (no tools, complex return type)
  # ============================================================

  defp run_json_only(agent, llm, state) do
    json_state = %{state | schema: build_schema(agent), json_mode: true}

    json_driver_loop(agent, llm, json_state)
  end

  defp json_driver_loop(agent, llm, state) do
    case check_termination(agent, state) do
      {:stop, result} ->
        result

      :continue ->
        state = %{state | current_turn_type: :normal}

        Telemetry.emit([:turn, :start], %{}, %{
          agent_name: agent.name,
          agent_id: state.agent_id,
          turn: state.turn,
          type: :normal,
          tools_count: 0
        })

        turn_start = System.monotonic_time()

        case execute_json_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            Metrics.emit_turn_stop_immediate(
              turn,
              state,
              turn_start,
              next_state.turn_tokens
            )

            json_driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            Metrics.emit_turn_stop_immediate(turn, state, turn_start, turn_tokens)
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
          |> then(&%{&1 | current_messages: messages, current_system_prompt: system_prompt})

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
    effective_tools = BuiltinTools.effective_tools(agent)
    combined? = combined_mode?(agent)

    # Tier 3a: in combined mode, the LLM-visible request `tools` field
    # is filtered to `:native | :both`-exposed app tools, then appended
    # with `ptc_lisp_execute`. Pure text mode keeps the legacy behavior
    # (every effective tool surfaces natively).
    tool_schemas =
      if combined? do
        combined_mode_tool_schemas(effective_tools, agent)
      else
        ToolSchema.to_tool_definitions(effective_tools)
      end

    normalized_tools = ToolNormalizer.normalize(effective_tools, state, agent)

    # Build reverse name map: sanitized API name → original tool name
    # e.g., "grep_n" → "grep-n", so we can find tools when the LLM uses sanitized names
    api_name_map =
      Map.new(normalized_tools, fn {name, _} ->
        {ToolSchema.sanitize_name(name), name}
      end)

    # Tier 2b: Tool struct lookup keyed by *original* (pre-sanitize) name.
    # Carries `expose`/`cache`/`native_result` for the combined-mode native
    # preview/cache decision in `execute_single_tool`.
    tools_meta = build_tools_meta(effective_tools)

    # Tier 2b / Addendum #15: combined-mode entry path initializes
    # `tool_cache` to `%{}` so native preview seeding has somewhere to
    # write. Pure text mode MUST leave it untouched (per the State
    # struct default `nil`; `%{}` if Loop.run already set it from
    # defaults). `state.tool_cache || %{}` is intentional — we never
    # overwrite an already-initialized cache, only fill in nil.

    tool_cache =
      if combined? do
        state.tool_cache || %{}
      else
        state.tool_cache
      end

    tc_state = %{
      state
      | tool_schemas: tool_schemas,
        normalized_tools_map: normalized_tools,
        api_name_map: api_name_map,
        tools_meta: tools_meta,
        tool_cache: tool_cache,
        combined_mode: combined?,
        total_tool_calls: 0,
        all_tool_calls: []
    }

    tool_driver_loop(agent, llm, tc_state)
  end

  # Tier 3a: combined-mode tool schemas. Filter app tools by exposure
  # (`:native` or `:both`) and append the `ptc_lisp_execute` entry whose
  # description comes from the `:in_process_text_mode` capability
  # profile. ToolSchema.to_tool_definitions/1 expects the original
  # `effective_tools` map shape; we filter the *map* by expose-eligible
  # names so the schemas renderer keeps its existing behavior. Tools
  # exposed `:ptc_lisp` are intentionally absent from the native
  # request — they remain reachable via `(tool/...)` inside programs.
  defp combined_mode_tool_schemas(effective_tools, agent) do
    allowed_names = combined_mode_native_tool_names(effective_tools, agent)

    native_tools =
      effective_tools
      |> Enum.filter(fn {name, _} -> MapSet.member?(allowed_names, name) end)
      |> Map.new()

    ToolSchema.to_tool_definitions(native_tools) ++ [combined_mode_tool_schema()]
  end

  defp combined_mode_native_tool_names(effective_tools, agent) do
    tools_meta = build_tools_meta(effective_tools)

    effective_tools
    |> Map.keys()
    |> Enum.filter(fn name ->
      case Map.get(tools_meta, name) do
        %Tool{} = tool ->
          Exposure.effective_expose(tool, agent) in [:native, :both]

        _ ->
          # Unnormalizable / non-Tool entries (rare in practice) keep
          # legacy text-mode behavior — surface natively.
          true
      end
    end)
    |> MapSet.new()
  end

  @doc false
  # Tier 3a: TextMode-local variant of the `ptc_lisp_execute` schema.
  # Same wire shape as `Loop.PtcToolCall.tool_schema/0` but the
  # `description` is sourced from the `:in_process_text_mode`
  # capability profile (Addendum #11 — one canonical string per
  # profile, returned directly with no concatenation). We intentionally
  # do not mutate `Loop.PtcToolCall.tool_schema/0`'s constant because
  # that module owns the `:in_process_with_app_tools` profile.
  @spec combined_mode_tool_schema() :: map()
  def combined_mode_tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => @ptc_lisp_execute_name,
        "description" => PtcToolProtocol.tool_description(:in_process_text_mode),
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "program" => %{
              "type" => "string",
              "description" =>
                "PTC-Lisp source code. Must be non-empty. Call app tools as `(tool/name ...)` from inside the program."
            }
          },
          "required" => ["program"],
          "additionalProperties" => false
        }
      }
    }
  end

  # Combined mode = `output: :text, ptc_transport: :tool_call`.
  # Validator currently rejects this combo (Tier 3e flips the gate); the
  # check exists here so the preview/cache machinery is reachable
  # internally (tests that construct state directly) without a public
  # escape hatch.
  defp combined_mode?(%Definition{output: :text, ptc_transport: :tool_call}), do: true
  defp combined_mode?(%Definition{}), do: false

  # Build a `name => %PtcRunner.Tool{}` map from the agent's effective
  # tools so the runtime can read `expose`/`cache`/`native_result` at
  # dispatch time. Falls back silently for non-normalizable formats — a
  # missing meta entry just means "treat as bare native tool" (no preview,
  # no cache write) which matches the v1 behavior for any tool without
  # `expose: :both, cache: true`.
  defp build_tools_meta(tools) when is_map(tools) do
    Map.new(tools, fn {name, format} ->
      case Tool.new(name, format) do
        {:ok, tool} -> {name, tool}
        {:error, _} -> {name, nil}
      end
    end)
  end

  defp tool_driver_loop(agent, llm, state) do
    case check_termination(agent, state) do
      {:stop, result} ->
        result

      :continue ->
        state = %{state | current_turn_type: :normal}

        Telemetry.emit([:turn, :start], %{}, %{
          agent_name: agent.name,
          agent_id: state.agent_id,
          turn: state.turn,
          type: :normal,
          tools_count: map_size(agent.tools)
        })

        turn_start = System.monotonic_time()

        case execute_tool_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            Metrics.emit_turn_stop_immediate(
              turn,
              state,
              turn_start,
              next_state.turn_tokens
            )

            tool_driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            Metrics.emit_turn_stop_immediate(turn, state, turn_start, turn_tokens)
            result
        end
    end
  end

  defp execute_tool_turn(agent, llm, state) do
    system_prompt = build_tool_system_prompt(agent)

    {messages, state} =
      if state.turn == 1 do
        # `loop.ex` seeds state.messages with a PTC-Lisp formatted user prompt
        # (signatures rendered in kebab-case for `(return {...})` examples).
        # That's wrong for text mode — the LLM should see a snake-case JSON
        # schema. Rebuild the user message here AND persist it into
        # state.messages so subsequent turns (which rely on `state.messages`)
        # don't fall back to the stale PTC-Lisp version.
        expanded_prompt =
          PromptExpander.expand(agent.prompt, state.context, on_missing: :keep)
          |> elem(1)

        user_msg = build_tool_user_message(agent, expanded_prompt, state.context)
        msgs = (state.initial_messages || []) ++ [%{role: :user, content: user_msg}]
        {msgs, %{state | messages: msgs}}
      else
        {state.messages, state}
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
          |> then(&%{&1 | current_messages: messages, current_system_prompt: system_prompt})

        handle_tool_calls(tool_calls, response.content, agent, state_with_tokens)

      {:ok, %{content: content, tokens: tokens}} when is_binary(content) ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> then(&%{&1 | current_messages: messages, current_system_prompt: system_prompt})

        handle_final_answer(content, agent, state_with_tokens)

      {:ok, %{content: nil, tool_calls: nil}} ->
        state_with_tokens = %{
          state
          | current_messages: messages,
            current_system_prompt: system_prompt
        }

        handle_empty_response(agent, state_with_tokens)

      {:ok, %{content: nil}} ->
        state_with_tokens = %{
          state
          | current_messages: messages,
            current_system_prompt: system_prompt
        }

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

    # Tier 3a (Addendum / Tier 3a description): `ptc_lisp_execute`
    # invocations are exempt from `agent.max_tool_calls` and MUST NOT
    # increment `state.total_tool_calls`. We tag each call with a
    # boolean flag, then apply the budget check only to the non-exempt
    # subset. Exempt calls always execute regardless of the budget.
    tagged_calls =
      Enum.map(tool_calls_with_ids, fn tc ->
        {tc, ptc_lisp_execute_call?(tc, state)}
      end)

    non_exempt_count = Enum.count(tagged_calls, fn {_, exempt?} -> not exempt? end)

    {calls_to_execute, skipped_calls} =
      cond do
        is_nil(agent.max_tool_calls) ->
          {tagged_calls, []}

        state.total_tool_calls + non_exempt_count <= agent.max_tool_calls ->
          {tagged_calls, []}

        true ->
          remaining = max(0, agent.max_tool_calls - state.total_tool_calls)
          partition_with_budget(tagged_calls, remaining)
      end

    limit_exceeded = skipped_calls != []

    # Reduce instead of map_reduce so each tool call can update
    # `state.tool_cache` (combined-mode native preview seeding). Pure text
    # mode never enters the cache-write branch, so the threaded state is a
    # noop for v1 callers.
    {tool_results_rev, current_turn_calls, state_after_calls, fatal_step} =
      Enum.reduce_while(calls_to_execute, {[], [], state, nil}, fn {tc, exempt?},
                                                                   {results_acc, calls_acc, st,
                                                                    _fatal} ->
        tool_name = tc.name
        tool_args = tc.args || %{}
        tool_id = tc.id

        cond do
          exempt? ->
            case dispatch_ptc_lisp_execute(tc, agent, st) do
              {:ok, result_str, step_entry, st_next} ->
                tool_result_msg = %{role: :tool, tool_call_id: tool_id, content: result_str}

                {:cont, {[tool_result_msg | results_acc], [step_entry | calls_acc], st_next, nil}}

              {:fatal, error_step} ->
                {:halt, {results_acc, calls_acc, st, error_step}}
            end

          Map.get(tc, :args_error) ->
            error_msg = Map.get(tc, :args_error)
            result_str = Jason.encode!(%{"error" => error_msg})

            step_entry = %{
              name: tool_name,
              args: tool_args,
              result: nil,
              error: error_msg,
              timestamp: DateTime.utc_now(),
              duration_ms: 0
            }

            tool_result_msg = %{role: :tool, tool_call_id: tool_id, content: result_str}
            {:cont, {[tool_result_msg | results_acc], [step_entry | calls_acc], st, nil}}

          true ->
            {result_str, step_entry, st_next} = execute_single_tool(tool_name, tool_args, st)
            tool_result_msg = %{role: :tool, tool_call_id: tool_id, content: result_str}
            {:cont, {[tool_result_msg | results_acc], [step_entry | calls_acc], st_next, nil}}
        end
      end)

    if fatal_step do
      duration_ms = System.monotonic_time(:millisecond) - state.start_time

      step_with_metrics = %{
        fatal_step
        | usage: Metrics.build_final_usage(state, duration_ms, 0),
          turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
          messages: build_collected_messages(state, state.messages),
          prompt: state.expanded_prompt,
          original_prompt: state.original_prompt,
          tools: state.normalized_tools
      }

      {:stop, {:error, step_with_metrics}, nil, state.turn_tokens}
    else
      tool_results = Enum.reverse(tool_results_rev)

      all_tool_calls = Enum.reverse(current_turn_calls) ++ state.all_tool_calls

      tool_results =
        if limit_exceeded do
          limit_msgs =
            Enum.map(skipped_calls, fn {tc, _exempt?} ->
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
                arguments:
                  if(is_binary(tc.args), do: tc.args, else: Jason.encode!(tc.args || %{}))
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

      executed_non_exempt =
        Enum.count(calls_to_execute, fn {_tc, exempt?} -> not exempt? end)

      skipped_non_exempt =
        Enum.count(skipped_calls, fn {_tc, exempt?} -> not exempt? end)

      new_state = %{
        state_after_calls
        | turn: state.turn + 1,
          messages: state.messages ++ [assistant_msg | tool_results],
          turns: [turn | state.turns],
          remaining_turns: state.remaining_turns - 1,
          total_tool_calls: state.total_tool_calls + executed_non_exempt + skipped_non_exempt,
          all_tool_calls: all_tool_calls,
          turn_tokens: state.turn_tokens
      }

      {:continue, new_state, turn}
    end
  end

  # Split tagged calls so non-exempt calls stay within `remaining`
  # budget; exempt (`ptc_lisp_execute`) calls are always kept. Order
  # within `tagged_calls` is preserved.
  defp partition_with_budget(tagged_calls, remaining) do
    {kept, skipped, _left} =
      Enum.reduce(tagged_calls, {[], [], remaining}, fn {_tc, exempt?} = entry,
                                                        {kept_acc, skipped_acc, budget} ->
        cond do
          exempt? ->
            {[entry | kept_acc], skipped_acc, budget}

          budget > 0 ->
            {[entry | kept_acc], skipped_acc, budget - 1}

          true ->
            {kept_acc, [entry | skipped_acc], budget}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(skipped)}
  end

  # Tier 3a: classify a tool call. The `ptc_lisp_execute` exemption
  # only applies in combined mode; in pure text mode the name is
  # never registered, so an LLM that returns it falls through to the
  # generic `tool not found` path.
  defp ptc_lisp_execute_call?(%{name: @ptc_lisp_execute_name}, %{combined_mode: true}), do: true
  defp ptc_lisp_execute_call?(_, _), do: false

  # ============================================================
  # Tier 3a — ptc_lisp_execute dispatch (combined mode only)
  # ============================================================
  #
  # Mirrors `Loop.PtcToolCall.execute_program/5` for the in-process
  # text-mode profile but with combined-mode semantics:
  #
  #   - `(return v)` and `(fail v)` produce *tool results*; they do
  #     NOT terminate the run (Final-Output Semantics). The LLM
  #     gets one more turn to respond if budget remains. Tier 3d
  #     pins the budget edge cases.
  #   - `turn_history` is NOT advanced here. Tier 3b refines this
  #     per the combined-mode `turn_history` semantics; v1
  #     content-mode behavior (only successful non-terminal program
  #     executions advance) is the target.
  #   - Memory-limit `:fatal` strategy aborts the run; `:rollback`
  #     continues.
  #   - `:args_error` paths render through `PtcToolProtocol.render_error/3`.

  # Returns one of:
  #   {:ok, result_json, step_entry, new_state}   — continue
  #   {:fatal, error_step}                          — terminate run with error
  defp dispatch_ptc_lisp_execute(call, agent, state) do
    start = System.monotonic_time(:millisecond)

    case extract_program(call) do
      {:ok, program} ->
        run_ptc_lisp_program(program, call, agent, state, start)

      {:error, reason, message} ->
        result_json = PtcToolProtocol.render_error(reason, message)
        duration_ms = System.monotonic_time(:millisecond) - start
        emit_ptc_lisp_telemetry(state, duration_ms, true)

        step_entry = %{
          name: @ptc_lisp_execute_name,
          args: call.args || %{},
          result: nil,
          error: message,
          timestamp: DateTime.utc_now(),
          duration_ms: duration_ms
        }

        {:ok, result_json, step_entry, state}
    end
  end

  defp run_ptc_lisp_program(program, call, agent, state, start) do
    exec_context =
      if state.last_fail do
        Map.put(state.context, :fail, state.last_fail)
      else
        state.context
      end

    # PTC-Lisp inventory — only `:both` / `:ptc_lisp`-exposed tools.
    # Wrap with an additional telemetry decorator so `(tool/...)`
    # calls inside programs emit `[:tool, :call]` events with
    # `exposure_layer: :ptc_lisp` (Tier 3a telemetry requirement).
    effective_tools = BuiltinTools.effective_tools(agent)
    ptc_lisp_inventory = ptc_lisp_inventory(effective_tools, agent, state)

    lisp_opts =
      build_lisp_opts(agent, state, exec_context, ptc_lisp_inventory)

    result = Lisp.run(program, lisp_opts)
    duration_ms = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, lisp_step} ->
        handle_lisp_success(lisp_step, program, call, agent, state, duration_ms)

      {:error, lisp_step} ->
        handle_lisp_runtime_error(lisp_step, program, call, agent, state, duration_ms)
    end
  end

  defp handle_lisp_success(
         %{return: {:__ptc_return__, value}} = lisp_step,
         program,
         call,
         agent,
         state,
         duration_ms
       ) do
    # Combined mode: `(return v)` produces a successful tool result
    # but does NOT terminate the run. Loop continues so the LLM gets
    # another turn (Final-Output Semantics). turn_history is NOT
    # advanced (Tier 3b will pin formally; v1 content-mode parity).
    unwrapped = %{lisp_step | return: KeyNormalizer.normalize_keys(value)}
    execution = TurnFeedback.execution_feedback(agent, state, unwrapped)
    result_json = PtcToolProtocol.render_success(unwrapped, execution: execution)

    state_next =
      thread_lisp_step_state(state, unwrapped, advance_turn_history: false)

    emit_ptc_lisp_telemetry(state, duration_ms, false)

    step_entry = ptc_lisp_step_entry(call, unwrapped, duration_ms, nil)
    _ = program
    {:ok, result_json, step_entry, state_next}
  end

  defp handle_lisp_success(
         %{return: {:__ptc_fail__, fail_args}} = lisp_step,
         program,
         call,
         agent,
         state,
         duration_ms
       ) do
    {fail_message, fail_value_preview} = fail_message_and_preview(fail_args)

    result_json =
      PtcToolProtocol.render_error(:fail, fail_message,
        result: fail_value_preview,
        feedback: fail_message
      )

    state_next = thread_lisp_step_state(state, lisp_step, advance_turn_history: false)
    emit_ptc_lisp_telemetry(state, duration_ms, true)

    step_entry =
      ptc_lisp_step_entry(call, lisp_step, duration_ms, fail_message)

    _ = {program, agent}
    {:ok, result_json, step_entry, state_next}
  end

  defp handle_lisp_success(lisp_step, program, call, agent, state, duration_ms) do
    case check_memory_limit(lisp_step.memory, agent.memory_limit) do
      {:ok, _size} ->
        # Intermediate value — render success and continue. Tier 3b:
        # advance `turn_history` so the program's final expression
        # value becomes `*1` for the next program (mirrors v1 PTC
        # `:tool_call` `Loop.PtcToolCall.continue_with_intermediate/7`).
        execution = TurnFeedback.execution_feedback(agent, state, lisp_step)
        result_json = PtcToolProtocol.render_success(lisp_step, execution: execution)

        state_next = thread_lisp_step_state(state, lisp_step, advance_turn_history: true)
        emit_ptc_lisp_telemetry(state, duration_ms, false)

        step_entry = ptc_lisp_step_entry(call, lisp_step, duration_ms, nil)
        _ = program
        {:ok, result_json, step_entry, state_next}

      {:error, :memory_limit_exceeded, actual_size} ->
        handle_memory_limit_exceeded(
          lisp_step,
          actual_size,
          program,
          call,
          agent,
          state,
          duration_ms
        )
    end
  end

  defp handle_lisp_runtime_error(lisp_step, program, call, _agent, state, duration_ms) do
    fail = lisp_step.fail
    reason_atom = classify_lisp_error(fail)
    message = fail.message

    result_json = PtcToolProtocol.render_error(reason_atom, message)

    state_next =
      thread_lisp_step_state(state, lisp_step,
        advance_turn_history: false,
        last_fail: fail,
        last_return_error: message
      )

    emit_ptc_lisp_telemetry(state, duration_ms, true)
    step_entry = ptc_lisp_step_entry(call, lisp_step, duration_ms, message)
    _ = program
    {:ok, result_json, step_entry, state_next}
  end

  defp handle_memory_limit_exceeded(
         lisp_step,
         actual_size,
         _program,
         call,
         agent,
         state,
         duration_ms
       ) do
    error_msg =
      "Memory limit exceeded (#{actual_size} bytes > #{agent.memory_limit} bytes)."

    if agent.memory_strategy == :rollback do
      result_json =
        PtcToolProtocol.render_error(:memory_limit, error_msg <> " Last turn rolled back.")

      # Rollback: do NOT propagate lisp_step's memory/turn_history.
      emit_ptc_lisp_telemetry(state, duration_ms, true)
      step_entry = ptc_lisp_step_entry(call, lisp_step, duration_ms, error_msg)
      {:ok, result_json, step_entry, state}
    else
      emit_ptc_lisp_telemetry(state, duration_ms, true)
      error_step = Step.error(:memory_limit_exceeded, error_msg, lisp_step.memory)
      {:fatal, error_step}
    end
  end

  defp thread_lisp_step_state(state, lisp_step, opts) do
    base = %{
      state
      | memory: lisp_step.memory,
        journal: lisp_step.journal,
        tool_cache: lisp_step.tool_cache,
        summaries: Map.merge(state.summaries, lisp_step.summaries),
        child_steps: state.child_steps ++ lisp_step.child_steps
    }

    base =
      case Keyword.fetch(opts, :last_fail) do
        {:ok, value} -> %{base | last_fail: value}
        :error -> base
      end

    base =
      case Keyword.fetch(opts, :last_return_error) do
        {:ok, value} -> %{base | last_return_error: value}
        :error -> base
      end

    # Tier 3b: advance `turn_history` only when the caller explicitly
    # asks. Successful intermediate `ptc_lisp_execute` results pass
    # `true`; `(return v)`, `(fail v)`, runtime errors, memory rollback,
    # native tool calls, and direct text turns all leave it unchanged.
    case Keyword.get(opts, :advance_turn_history, false) do
      false ->
        base

      true ->
        truncated = ResponseHandler.truncate_for_history(lisp_step.return)
        %{base | turn_history: append_turn_history(state.turn_history, truncated)}
    end
  end

  # Mirrors `Loop.PtcToolCall.update_turn_history/2`: append the new
  # result and keep only the most recent three entries (the `*1`/`*2`/
  # `*3` window).
  defp append_turn_history(history, new_result) do
    (history ++ [new_result]) |> Enum.take(-3)
  end

  defp ptc_lisp_step_entry(call, lisp_step, duration_ms, error) do
    %{
      name: @ptc_lisp_execute_name,
      args: call.args || %{},
      result: Map.get(lisp_step, :return),
      error: error,
      timestamp: DateTime.utc_now(),
      duration_ms: duration_ms
    }
  end

  defp emit_ptc_lisp_telemetry(state, duration_ms, error?) do
    Telemetry.emit([:tool, :call], %{duration_ms: duration_ms}, %{
      agent_name: state.agent_name,
      agent_id: state.agent_id,
      tool_name: @ptc_lisp_execute_name,
      exposure_layer: :native,
      cached: false,
      error: error?
    })
  end

  # Build the PTC-Lisp inventory map (name => function). Only
  # `:both` and `:ptc_lisp`-exposed tools surface here; the analyzer
  # rejects `(tool/foo ...)` calls for `:native`-only targets at
  # parse time (Tier 1a). Each function is wrapped in an extra
  # telemetry decorator so app-tool calls made from inside programs
  # emit `[:tool, :call]` events with `exposure_layer: :ptc_lisp`.
  defp ptc_lisp_inventory(effective_tools, agent, state) do
    allowed_names =
      effective_tools
      |> Enum.filter(fn {name, _} ->
        case build_tools_meta(effective_tools) |> Map.get(name) do
          %Tool{} = tool -> Exposure.effective_expose(tool, agent) in [:ptc_lisp, :both]
          _ -> false
        end
      end)
      |> Enum.map(fn {name, _} -> name end)
      |> MapSet.new()

    filtered =
      effective_tools
      |> Enum.filter(fn {name, _} -> MapSet.member?(allowed_names, name) end)
      |> Map.new()

    filtered
    |> ToolNormalizer.normalize(state, agent)
    |> Map.new(fn
      {name, func} when is_function(func, 1) ->
        {name, wrap_ptc_lisp_telemetry(name, func, state)}

      {name, {func, opts}} when is_function(func, 1) ->
        {name, {wrap_ptc_lisp_telemetry(name, func, state), opts}}

      other ->
        other
    end)
  end

  defp wrap_ptc_lisp_telemetry(name, func, state) do
    agent_name = state.agent_name
    agent_id = state.agent_id

    fn args ->
      start = System.monotonic_time(:millisecond)

      try do
        result = func.(args)
        duration_ms = System.monotonic_time(:millisecond) - start

        Telemetry.emit([:tool, :call], %{duration_ms: duration_ms}, %{
          agent_name: agent_name,
          agent_id: agent_id,
          tool_name: name,
          exposure_layer: :ptc_lisp,
          cached: false,
          error: false
        })

        result
      rescue
        e ->
          duration_ms = System.monotonic_time(:millisecond) - start

          Telemetry.emit([:tool, :call], %{duration_ms: duration_ms}, %{
            agent_name: agent_name,
            agent_id: agent_id,
            tool_name: name,
            exposure_layer: :ptc_lisp,
            cached: false,
            error: true
          })

          reraise e, __STACKTRACE__
      end
    end
  end

  defp build_lisp_opts(agent, state, exec_context, ptc_lisp_inventory) do
    [
      context: exec_context,
      memory: state.memory || %{},
      tools: ptc_lisp_inventory,
      turn_history: state.turn_history,
      float_precision: agent.float_precision,
      max_print_length: Keyword.get(agent.format_options, :max_print_length),
      timeout: agent.timeout,
      pmap_timeout: agent.pmap_timeout,
      pmap_max_concurrency: agent.pmap_max_concurrency,
      budget: Budget.build_introspection_map(agent, state),
      trace_context: state.trace_context,
      journal: state.journal,
      tool_cache: state.tool_cache || %{}
    ]
    |> maybe_put(:max_heap, state.max_heap)
    |> maybe_put(:max_tool_calls, agent.max_tool_calls)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp memory_size(memory) when is_map(memory), do: :erlang.external_size(memory)

  defp check_memory_limit(memory, limit) when is_integer(limit) do
    size = memory_size(memory)
    if size > limit, do: {:error, :memory_limit_exceeded, size}, else: {:ok, size}
  end

  defp check_memory_limit(_memory, nil), do: {:ok, 0}

  # Mirrors `Loop.PtcToolCall.classify_lisp_error/1`.
  defp classify_lisp_error(%{reason: reason})
       when reason in [:parse_error, :timeout, :memory_limit] do
    reason
  end

  defp classify_lisp_error(%{reason: reason}) when is_atom(reason) do
    reason_str = Atom.to_string(reason)

    cond do
      String.contains?(reason_str, "parse") -> :parse_error
      String.contains?(reason_str, "timeout") -> :timeout
      String.contains?(reason_str, "memory") -> :memory_limit
      true -> :runtime_error
    end
  end

  defp fail_message_and_preview(fail_args) do
    {preview, _truncated} = Format.to_clojure(fail_args, limit: 50)
    {inspect(fail_args), preview}
  end

  defp extract_program(%{args_error: error_msg}) when is_binary(error_msg) do
    {:error, :args_error, "Invalid tool arguments: #{error_msg}"}
  end

  defp extract_program(%{args: args}) when is_map(args) do
    program = Map.get(args, "program") || Map.get(args, :program)
    validate_program(program)
  end

  defp extract_program(_), do: validate_program(nil)

  defp validate_program(nil),
    do: {:error, :args_error, "ptc_lisp_execute requires a non-empty `program` string argument."}

  defp validate_program(program) when not is_binary(program),
    do:
      {:error, :args_error,
       "ptc_lisp_execute `program` must be a string, got #{inspect(program)}."}

  defp validate_program(program) when is_binary(program) do
    if String.trim(program) == "" do
      {:error, :args_error, "ptc_lisp_execute `program` must be a non-empty string."}
    else
      {:ok, program}
    end
  end

  defp execute_single_tool(tool_name, tool_args, state) do
    start = System.monotonic_time(:millisecond)

    # Resolve sanitized API name back to original tool name
    # e.g., LLM returns "grep_n" but tools map has "grep-n"
    resolved_name = Map.get(state.api_name_map, tool_name, tool_name)
    tool_meta = state.tools_meta && Map.get(state.tools_meta, resolved_name)

    # Tier 2b: Combined-mode preview/cache. Only active when the agent is
    # in combined mode AND the tool opts in via `expose: :both, cache: true`.
    # Pure text mode and `cache: false`/`:native`-only tools fall through
    # to the legacy bare-dispatch path below.
    {result_str, result, error, state_next} =
      if preview_and_cache?(tool_meta) and combined_mode_active?(state) do
        execute_with_cache(tool_meta, tool_name, tool_args, state)
      else
        {rs, r, e} = dispatch_bare(resolved_name, tool_name, tool_args, state)
        {rs, r, e, state}
      end

    duration_ms = System.monotonic_time(:millisecond) - start

    # Tier 2b telemetry: every native tool-call event carries
    # `exposure_layer: :native`. PTC-Lisp `(tool/...)` calls are tagged
    # `:ptc_lisp` from a different emitter (Tier 3a). Pure-text mode also
    # gets `:native` since native is the only layer present there — that
    # keeps the field universal across modes.
    Telemetry.emit([:tool, :call], %{duration_ms: duration_ms}, %{
      agent_name: state.agent_name,
      agent_id: state.agent_id,
      tool_name: tool_name,
      exposure_layer: :native,
      cached: cached_for_telemetry(state, state_next, tool_meta),
      error: error != nil
    })

    step_entry = %{
      name: tool_name,
      args: tool_args,
      result: result,
      error: error,
      timestamp: DateTime.utc_now(),
      duration_ms: duration_ms
    }

    {result_str, step_entry, state_next}
  end

  defp dispatch_bare(resolved_name, tool_name, tool_args, state) do
    case Map.fetch(state.normalized_tools_map, resolved_name) do
      {:ok, tool_fn} when is_function(tool_fn, 1) ->
        invoke_tool(tool_fn, tool_name, tool_args)

      {:ok, {tool_fn, _opts}} when is_function(tool_fn, 1) ->
        invoke_tool(tool_fn, tool_name, tool_args)

      _ ->
        error_msg = "Tool '#{tool_name}' not found"
        {Jason.encode!(%{"error" => error_msg}), nil, error_msg}
    end
  end

  # Combined-mode preview/cache execution. On cache hit, returns the
  # canonical preview without re-invoking the tool function. On miss,
  # invokes the tool: success seeds the cache + returns preview JSON;
  # failure (raise / `{:error, _}`) does NOT seed the cache and falls
  # back to the legacy error JSON shape — same behavior native callers
  # see today.
  defp execute_with_cache(%Tool{} = tool, tool_name, tool_args, state) do
    cache_key = KeyNormalizer.canonical_cache_key(tool.name, tool_args)
    cache = state.tool_cache || %{}

    case Map.fetch(cache, cache_key) do
      {:ok, full_result} ->
        # Cache hit: rebuild the same preview shape without re-running
        # the tool function. The full result stays in cache for any
        # subsequent PTC-Lisp `(tool/...)` consumer.
        preview_map = preview_or_fallback(tool, full_result, tool_args)

        {Jason.encode!(preview_map), full_result, nil, state}

      :error ->
        resolved_name = Map.get(state.api_name_map, tool_name, tool.name)

        case Map.fetch(state.normalized_tools_map, resolved_name) do
          {:ok, tool_fn} when is_function(tool_fn, 1) ->
            run_and_cache(tool, tool_fn, tool_name, tool_args, cache_key, state)

          {:ok, {tool_fn, _opts}} when is_function(tool_fn, 1) ->
            run_and_cache(tool, tool_fn, tool_name, tool_args, cache_key, state)

          _ ->
            error_msg = "Tool '#{tool_name}' not found"
            {Jason.encode!(%{"error" => error_msg}), nil, error_msg, state}
        end
    end
  end

  defp run_and_cache(tool, tool_fn, tool_name, tool_args, cache_key, state) do
    {result_str, result, error} = invoke_tool(tool_fn, tool_name, tool_args)

    if error != nil do
      # Failure: do not seed cache. Edge case in plan: "{:error, _} and
      # raises are failures and MUST NOT seed the cache."
      {result_str, result, error, state}
    else
      # Success: unwrap `{:ok, value}` if present (Tool's existing
      # success normalization treats both raw and `{:ok, v}` as
      # successful partial values).
      full_result = unwrap_ok(result)
      new_cache = Map.put(state.tool_cache || %{}, cache_key, full_result)

      preview_map = preview_or_fallback(tool, full_result, tool_args)

      {Jason.encode!(preview_map), full_result, nil, %{state | tool_cache: new_cache}}
    end
  end

  defp preview_or_fallback(tool, full_result, args) do
    case NativePreview.build(tool, full_result, args) do
      {:ok, preview_map} -> preview_map
      {:fallback, preview_map} -> preview_map
    end
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(value), do: value

  defp preview_and_cache?(%Tool{expose: :both, cache: true}), do: true
  defp preview_and_cache?(_), do: false

  # Active = the combined-mode entry path ran (run_tool_variant set the
  # flag). Pure text mode has the flag unset even though `tool_cache`
  # may already be a `%{}` from upstream `Loop.run` defaults — so we
  # gate on the explicit flag, not on cache shape, per Addendum #15.
  defp combined_mode_active?(%{combined_mode: true}), do: true
  defp combined_mode_active?(_), do: false

  defp cached_for_telemetry(state_before, state_after, tool_meta) do
    cond do
      not preview_and_cache?(tool_meta) -> false
      not is_map(state_before.tool_cache) -> false
      # If the cache is unchanged after the call AND a value already lived
      # under the call's canonical key, this was a hit.
      state_before.tool_cache == state_after.tool_cache -> true
      true -> false
    end
  end

  # Invoke a tool function and translate any raised exception into a structured
  # error that's actually useful to (a) the LLM trying to recover and (b) the
  # developer reading logs. Vanilla `Exception.message/1` for FunctionClauseError
  # gives "no function clause matching in M.f/1" — which doesn't tell either
  # audience why the call failed.
  defp invoke_tool(tool_fn, tool_name, tool_args) do
    result = tool_fn.(tool_args)
    {encode_tool_result(result), result, nil}
  rescue
    e ->
      kind = e.__struct__ |> Module.split() |> List.last()
      base_msg = Exception.message(e)
      hint = exception_hint(e, tool_args)

      # Developer-facing log so the root cause is visible without opening
      # the trace. Args are inspected with a generous limit so the user can
      # see the actual shape mismatch.
      Logger.warning(
        "[ptc_runner] tool #{inspect(tool_name)} raised #{kind}: #{base_msg}. " <>
          "args=#{inspect(tool_args, limit: 50)}#{if hint, do: " hint=" <> hint, else: ""}"
      )

      # LLM-facing payload so it can self-correct on the next turn instead of
      # retrying the same call until max_turns.
      llm_payload =
        Jason.encode!(%{
          "error" => base_msg,
          "tool" => tool_name,
          "args_received" => tool_args,
          "hint" => hint
        })

      {llm_payload, nil, base_msg}
  end

  defp exception_hint(%FunctionClauseError{}, tool_args) do
    ~s|Tool received args #{inspect(tool_args)} but no function clause matched. | <>
      ~s|If you're using @spec auto-extraction with a bare-map argument like | <>
      ~s|`%{id: integer()}`, the LLM may be wrapping the call as | <>
      ~s|`{"map": {...}}`. Use an explicit `signature: "(id :int) -> ..."` | <>
      ~s|on the tool definition to control the parameter name the LLM sees.|
  end

  defp exception_hint(_e, _tool_args), do: nil

  defp encode_tool_result(result) do
    # Walk the result first so DateTime/NaiveDateTime/Date/Time become ISO 8601
    # strings before Jason sees them. Without this, Jason has no encoder for
    # temporal structs, falls through to the inspect fallback below, and the
    # LLM gets `~U[2026-05-03 09:14:00Z]` instead of a parseable date string.
    normalized = PtcRunner.Temporal.walk(result)

    case Jason.encode(normalized) do
      {:ok, json} -> json
      {:error, _} -> inspect(normalized, limit: 500)
    end
  end

  # ============================================================
  # Final Answer Handling (tool variant)
  # ============================================================

  defp handle_final_answer(content, agent, state) do
    if Definition.text_return?(agent) do
      # Fire on_chunk with full content for tool-variant final answer
      if state.on_chunk, do: safe_on_chunk(state.on_chunk, content)

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
        memory: state.memory || %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    final_messages = state.messages ++ [%{role: :assistant, content: text_content}]

    # Tier 3a: propagate combined-mode `ptc_lisp_execute` state on the
    # final step so callers can introspect memory/journal/tool_cache/
    # child_steps after the run terminates. Pure text mode never
    # accumulates these (tool_cache stays nil; memory stays nil), so
    # the field defaults match the legacy contract.
    step = %Step{
      return: text_content,
      fail: nil,
      memory: state.memory || %{},
      journal: state.journal,
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
      tool_calls: Enum.reverse(state.all_tool_calls),
      tool_cache: state.tool_cache || %{},
      child_steps: state.child_steps,
      summaries: state.summaries
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

  defp has_tools?(%Definition{} = agent) do
    map_size(BuiltinTools.effective_tools(agent)) > 0
  end

  defp safe_on_chunk(on_chunk, content) do
    on_chunk.(%{delta: content})
  rescue
    e ->
      require Logger
      Logger.warning("on_chunk callback failed: #{Exception.message(e)}")
  end

  defp track_on_chunk(nil), do: {fn -> false end, nil}

  defp track_on_chunk(on_chunk) do
    ref = :atomics.new(1, [])

    tracked = fn chunk ->
      :atomics.put(ref, 1, 1)
      on_chunk.(chunk)
    end

    was_called = fn -> :atomics.get(ref, 1) == 1 end
    {was_called, tracked}
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

  defp call_llm_with_telemetry(llm, input, state, _agent) do
    start_meta = %{
      agent_name: state.agent_name,
      agent_id: state.agent_id,
      turn: state.turn,
      messages: input.messages,
      model: state.llm
    }

    Telemetry.span([:llm], start_meta, fn ->
      # Bypass retry when streaming — can't retry after partial chunks sent
      retry_config = if input[:stream], do: nil, else: state.llm_retry
      result = LLMRetry.call_with_retry(llm, input, state.llm_registry, retry_config)

      {extra_measurements, stop_meta} =
        case result do
          {:ok, %{tool_calls: [_ | _], tokens: tokens}} ->
            measurements = Metrics.build_token_measurements(tokens)

            meta = %{
              agent_name: state.agent_name,
              agent_id: state.agent_id,
              turn: state.turn,
              response: "tool_calls"
            }

            {measurements, meta}

          {:ok, %{content: content, tokens: tokens}} ->
            measurements = Metrics.build_token_measurements(tokens)

            meta = %{
              agent_name: state.agent_name,
              agent_id: state.agent_id,
              turn: state.turn,
              response: content
            }

            {measurements, meta}

          {:error, _} ->
            meta = %{
              agent_name: state.agent_name,
              agent_id: state.agent_id,
              turn: state.turn,
              response: nil
            }

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
    if Definition.text_return?(agent) do
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

  defp format_type_name(:datetime),
    do: "ISO 8601 datetime string with offset (e.g. \"2026-05-03T09:14:00Z\")"

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
  defp build_example_value(:datetime), do: "2026-05-03T09:14:00Z"
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
      |> add_schema_metrics(state.schema)

    step_with_metrics = %{
      step
      | usage: usage,
        turns: Metrics.apply_trace_filter(Enum.reverse(state.turns), state.trace_mode, true),
        messages: build_collected_messages(state, state.messages),
        prompt: state.expanded_prompt,
        original_prompt: state.original_prompt,
        tools: state.normalized_tools
    }

    {:error, step_with_metrics}
  end

  # ============================================================
  # Message Collection
  # ============================================================

  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = state.current_system_prompt || ""
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
