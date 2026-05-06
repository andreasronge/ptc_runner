defmodule PtcRunner.SubAgent.Loop.PtcToolCall do
  @moduledoc """
  Native tool-call transport handler for `ptc_transport: :tool_call` agents.

  Owns the loop branch that consumes assistant turns shaped as native
  `tool_calls` (the `ptc_lisp_execute` invocation) plus the direct
  final-answer path. App tools are never exposed as provider-native
  tools — they remain callable only from inside a PTC-Lisp program via
  `(tool/name ...)`. The system prompt continues to render the full
  app-tool inventory.

  See `Plans/ptc-lisp-tool-call-transport.md` for the full design.

  ## Naming

  In this module, "tool call" without qualifier refers to a *native*
  tool call (the `ptc_lisp_execute` invocation on the provider wire).
  PTC-Lisp `(tool/...)` invocations continue to be called "app tool
  calls" and surface as `lisp_step.tool_calls`.

  ## Public surface

  - `tool_name/0`, `tool_description/0`, `tool_schema/0`, `request_tools/1`
    — Phase 3 schema/request shape (unchanged).
  - `handle_response/3` — Phase 4 entry point. Branches on the assistant
    response to either execute a single `ptc_lisp_execute` call, treat
    direct content as a final answer, or surface a paired protocol error.
  """

  alias PtcRunner.{Lisp, PtcToolProtocol, Step, Turn}
  alias PtcRunner.Lisp.Format
  alias PtcRunner.SubAgent.{BuiltinTools, Definition, KeyNormalizer}

  alias PtcRunner.SubAgent.Loop

  alias PtcRunner.SubAgent.Loop.{
    Budget,
    JsonHandler,
    Metrics,
    ResponseHandler,
    ReturnValidation,
    State,
    StepAssembler,
    ToolNormalizer,
    TurnFeedback
  }

  @ptc_lisp_execute_name "ptc_lisp_execute"

  # Canonical description string — single source of truth lives in
  # `PtcRunner.PtcToolProtocol`, parameterized by capability profile.
  # The v1 PTC `:tool_call` transport uses
  # `:in_process_with_app_tools`, which is byte-for-byte locked to the
  # historical wording (Addendum #10 of the text-mode plan). Tests
  # assert stable substrings against the same source of truth.

  @doc """
  The reserved native tool name (`"ptc_lisp_execute"`).
  """
  @spec tool_name() :: String.t()
  def tool_name, do: @ptc_lisp_execute_name

  @doc """
  The canonical description string for the `ptc_lisp_execute` tool in
  v1 PTC `:tool_call` mode.

  Delegates to `PtcRunner.PtcToolProtocol.tool_description/1` with the
  `:in_process_with_app_tools` profile. Tests assert stable substrings
  against this value; do not paraphrase the guidance elsewhere.
  """
  @spec tool_description() :: String.t()
  def tool_description, do: PtcToolProtocol.tool_description(:in_process_with_app_tools)

  @doc """
  Build the OpenAI-format tool schema for `ptc_lisp_execute`.

  Returns a single map. The intended use in `:tool_call` mode is to put
  exactly this one entry in the LLM request's `tools` field — app tools
  are never included.

  ## Examples

      iex> schema = PtcRunner.SubAgent.Loop.PtcToolCall.tool_schema()
      iex> schema["type"]
      "function"
      iex> schema["function"]["name"]
      "ptc_lisp_execute"
      iex> schema["function"]["parameters"]["required"]
      ["program"]

  """
  @spec tool_schema() :: map()
  def tool_schema do
    %{
      "type" => "function",
      "function" => %{
        "name" => @ptc_lisp_execute_name,
        "description" => PtcToolProtocol.tool_description(:in_process_with_app_tools),
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

  @doc """
  Build the request `tools` list for an agent.

  In `:tool_call` mode, returns exactly one entry — the
  `ptc_lisp_execute` schema — regardless of how many app tools the agent
  declares. App tools stay in the system prompt's Tool Inventory and are
  callable only from inside the sandboxed program.

  In `:content` mode, returns `nil` so the request omits the `tools`
  field (matching today's behavior where PTC-Lisp app tools are not
  exposed as native provider tools).
  """
  @spec request_tools(Definition.t()) :: [map()] | nil
  def request_tools(%{ptc_transport: :tool_call}), do: [tool_schema()]
  def request_tools(_agent), do: nil

  # ============================================================
  # Phase 4 — Response handler
  # ============================================================

  @doc """
  Handle an assistant turn under `ptc_transport: :tool_call`.

  Returns the same signal as content-mode response handling:

  - `{:continue, new_state, turn}` for non-terminating turns.
  - `{:stop, {:ok | :error, step}, turn, turn_tokens}` to terminate.

  Branches:

  - **No native tool calls**: treat direct content as the final answer
    (signature handling matrix). Markdown-fenced clojure as content
    triggers targeted feedback (R16).
  - **Exactly one `ptc_lisp_execute` call**: execute, append paired
    `role: :tool` message, continue or terminate on `(return)`/`(fail)`.
  - **One unknown tool call**: paired `unknown_tool` error, continue.
  - **More than one native tool call**: paired `multiple_tool_calls`
    error per `tool_call_id`, continue (R12, R13).
  """
  @spec handle_response(map(), Definition.t(), State.t()) ::
          {:continue, State.t(), Turn.t()}
          | {:stop, {:ok | :error, Step.t()}, Turn.t() | nil, map() | nil}
  def handle_response(response, agent, state) do
    tool_calls = Map.get(response, :tool_calls) || []
    content = Map.get(response, :content)

    case tool_calls do
      [] ->
        handle_direct_final(content, agent, state)

      [single] ->
        handle_single_call(single, content, agent, state)

      _ ->
        handle_multiple_calls(tool_calls, content, agent, state)
    end
  end

  # ----------------------------------------------------------------
  # Single native call
  # ----------------------------------------------------------------

  defp handle_single_call(call, assistant_content, agent, state) do
    name = Map.get(call, :name) || Map.get(call, "name")
    id = Map.get(call, :id) || Map.get(call, "id")

    if name != @ptc_lisp_execute_name do
      recover_protocol_error(
        [%{id: id, name: name}],
        assistant_content,
        :unknown_tool,
        unknown_tool_message(name),
        agent,
        state
      )
    else
      case extract_program(call) do
        {:ok, program} ->
          execute_program(program, call, assistant_content, agent, state)

        {:error, reason, message} ->
          recover_protocol_error(
            [%{id: id, name: name}],
            assistant_content,
            reason,
            message,
            agent,
            state
          )
      end
    end
  end

  # ----------------------------------------------------------------
  # Multi-call rejection (R12, R13)
  # ----------------------------------------------------------------

  defp handle_multiple_calls(calls, assistant_content, agent, state) do
    rejected =
      Enum.map(calls, fn c ->
        %{
          id: Map.get(c, :id) || Map.get(c, "id"),
          name: Map.get(c, :name) || Map.get(c, "name")
        }
      end)

    recover_protocol_error(
      rejected,
      assistant_content,
      :multiple_tool_calls,
      multiple_tool_calls_message(),
      agent,
      state
    )
  end

  # ----------------------------------------------------------------
  # Successful execution path
  # ----------------------------------------------------------------

  defp execute_program(program, native_call, assistant_content, agent, state) do
    exec_context =
      if state.last_fail do
        Map.put(state.context, :fail, state.last_fail)
      else
        state.context
      end

    tools = BuiltinTools.effective_tools(agent)
    normalized_tools = ToolNormalizer.normalize(tools, state, agent)

    lisp_opts = build_lisp_opts(agent, state, exec_context, normalized_tools)

    case Lisp.run(program, lisp_opts) do
      {:ok, lisp_step} ->
        emit_pmap_telemetry(state, lisp_step)
        handle_lisp_success(program, native_call, assistant_content, lisp_step, agent, state)

      {:error, lisp_step} ->
        emit_pmap_telemetry(state, lisp_step)

        handle_lisp_runtime_error(
          program,
          native_call,
          assistant_content,
          lisp_step,
          agent,
          state
        )
    end
  end

  # Heads, in priority order:
  # 1. (return v): terminate with success step + paired final tool result.
  # 2. (fail v):  terminate with error step + paired final tool result.
  # 3. Memory-limit exceeded: rollback or fatal (parity with :content mode).
  # 4. Otherwise: intermediate value -> continue, advance turn_history.

  defp handle_lisp_success(
         program,
         native_call,
         assistant_content,
         %{return: {:__ptc_return__, return_value}} = lisp_step,
         agent,
         state
       ) do
    normalized_value = KeyNormalizer.normalize_keys(return_value)
    unwrapped_step = %{lisp_step | return: normalized_value}

    case ReturnValidation.validate(agent, normalized_value) do
      :ok ->
        terminate_with_return(
          program,
          native_call,
          assistant_content,
          unwrapped_step,
          agent,
          state
        )

      {:error, validation_errors} ->
        handle_return_validation_error(
          program,
          native_call,
          assistant_content,
          unwrapped_step,
          agent,
          state,
          validation_errors
        )
    end
  end

  # `(fail v)` must be matched before the single-shot catch-all below;
  # otherwise a single-shot agent's explicit failure would be routed
  # through `terminate_with_return/6` and surface as `{:ok, step}` instead
  # of `{:error, step}`. Parity with multi-turn `:tool_call` mode and with
  # `:content` mode.
  defp handle_lisp_success(
         program,
         native_call,
         assistant_content,
         %{return: {:__ptc_fail__, fail_args}} = lisp_step,
         agent,
         state
       ) do
    terminate_with_fail(
      program,
      native_call,
      assistant_content,
      lisp_step,
      fail_args,
      agent,
      state
    )
  end

  # Single-shot mode without retry_turns: skip validation (parity with :content mode).
  defp handle_lisp_success(
         program,
         native_call,
         assistant_content,
         lisp_step,
         %{max_turns: 1, retry_turns: 0} = agent,
         state
       ) do
    normalized_step = %{lisp_step | return: KeyNormalizer.normalize_keys(lisp_step.return)}

    terminate_with_return(
      program,
      native_call,
      assistant_content,
      normalized_step,
      agent,
      state
    )
  end

  defp handle_lisp_success(program, native_call, assistant_content, lisp_step, agent, state) do
    case check_memory_limit(lisp_step.memory, agent.memory_limit) do
      {:ok, _size} ->
        continue_with_intermediate(
          program,
          native_call,
          assistant_content,
          lisp_step,
          agent,
          state
        )

      {:error, :memory_limit_exceeded, actual_size} ->
        handle_memory_limit_exceeded(
          program,
          native_call,
          assistant_content,
          lisp_step,
          agent,
          state,
          actual_size
        )
    end
  end

  defp continue_with_intermediate(
         program,
         native_call,
         assistant_content,
         lisp_step,
         agent,
         state
       ) do
    execution = TurnFeedback.execution_feedback(agent, state, lisp_step)
    tool_result_json = PtcToolProtocol.render_success(lisp_step, execution: execution)

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        lisp_step.return,
        success?: true,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    truncated_result = ResponseHandler.truncate_for_history(lisp_step.return)
    updated_history = update_turn_history(state.turn_history, truncated_result)

    new_state =
      build_continuation_state(
        state,
        turn,
        assistant_content,
        native_call,
        tool_result_json,
        memory: lisp_step.memory,
        journal: lisp_step.journal,
        tool_cache: lisp_step.tool_cache,
        child_steps: state.child_steps ++ lisp_step.child_steps,
        summaries: Map.merge(state.summaries, lisp_step.summaries),
        turn_history: updated_history
      )

    {:continue, new_state, turn}
  end

  defp terminate_with_return(
         program,
         native_call,
         assistant_content,
         lisp_step,
         agent,
         state
       ) do
    execution = TurnFeedback.execution_feedback(agent, state, lisp_step)
    tool_result_json = PtcToolProtocol.render_success(lisp_step, execution: execution)

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        lisp_step.return,
        success?: true,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type || :normal
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    final_messages =
      state.messages ++
        assistant_with_tool_calls_messages(assistant_content, [native_call], [
          {Map.get(native_call, :id) || Map.get(native_call, "id"), tool_result_json}
        ])

    final_step =
      StepAssembler.finalize(lisp_step, state,
        duration_ms: duration_ms,
        memory_bytes: lisp_step.usage.memory_bytes,
        final_turn: turn,
        final_messages: final_messages,
        field_descriptions: agent.field_descriptions,
        summaries: Map.merge(state.summaries, lisp_step.summaries),
        child_steps: state.child_steps ++ lisp_step.child_steps
      )

    {:stop, {:ok, final_step}, turn, state.turn_tokens}
  end

  defp terminate_with_fail(
         program,
         native_call,
         assistant_content,
         lisp_step,
         fail_args,
         _agent,
         state
       ) do
    {fail_message, fail_value_preview} = fail_message_and_preview(fail_args)

    tool_result_json =
      PtcToolProtocol.render_error(:fail, fail_message,
        result: fail_value_preview,
        feedback: fail_message
      )

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        fail_args,
        success?: false,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    error_step = Step.error(:failed, inspect(fail_args), lisp_step.memory)

    final_messages =
      state.messages ++
        assistant_with_tool_calls_messages(assistant_content, [native_call], [
          {Map.get(native_call, :id) || Map.get(native_call, "id"), tool_result_json}
        ])

    final_step =
      StepAssembler.finalize(error_step, state,
        duration_ms: duration_ms,
        memory_bytes: lisp_step.usage.memory_bytes,
        is_error: true,
        final_turn: turn,
        final_messages: final_messages,
        journal: lisp_step.journal,
        child_steps: state.child_steps ++ lisp_step.child_steps
      )

    {:stop, {:error, final_step}, turn, state.turn_tokens}
  end

  defp handle_lisp_runtime_error(
         program,
         native_call,
         assistant_content,
         lisp_step,
         _agent,
         state
       ) do
    fail = lisp_step.fail
    reason_atom = classify_lisp_error(fail)
    message = fail.message
    tool_result_json = PtcToolProtocol.render_error(reason_atom, message)

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        fail,
        success?: false,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    new_state =
      build_continuation_state(
        state,
        turn,
        assistant_content,
        native_call,
        tool_result_json,
        memory: lisp_step.memory,
        journal: lisp_step.journal,
        tool_cache: lisp_step.tool_cache,
        child_steps: state.child_steps ++ lisp_step.child_steps,
        last_fail: fail,
        last_return_error: message
      )

    {:continue, new_state, turn}
  end

  defp handle_return_validation_error(
         program,
         native_call,
         assistant_content,
         lisp_step,
         agent,
         state,
         errors
       ) do
    error_message = ReturnValidation.format_error_for_llm(agent, lisp_step.return, errors)

    tool_result_json =
      PtcToolProtocol.render_error(:runtime_error, error_message)

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        %{
          reason: :return_validation_failed,
          message: error_message,
          actual_value: lisp_step.return,
          errors: errors
        },
        success?: false,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    new_state =
      build_continuation_state(
        state,
        turn,
        assistant_content,
        native_call,
        tool_result_json,
        memory: lisp_step.memory,
        journal: lisp_step.journal,
        tool_cache: lisp_step.tool_cache,
        child_steps: state.child_steps ++ lisp_step.child_steps,
        last_return_error: error_message
      )

    {:continue, new_state, turn}
  end

  defp handle_memory_limit_exceeded(
         program,
         native_call,
         assistant_content,
         lisp_step,
         agent,
         state,
         actual_size
       ) do
    error_msg =
      "Memory limit exceeded (#{actual_size} bytes > #{agent.memory_limit} bytes)."

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, native_call),
        program,
        lisp_step.return,
        success?: false,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory,
        type: state.current_turn_type
      )

    if agent.memory_strategy == :rollback do
      tool_result_json =
        PtcToolProtocol.render_error(:memory_limit, error_msg <> " Last turn rolled back.")

      new_state =
        build_continuation_state(
          state,
          turn,
          assistant_content,
          native_call,
          tool_result_json,
          memory: state.memory,
          turn_history: state.turn_history
        )

      {:continue, new_state, turn}
    else
      duration_ms = System.monotonic_time(:millisecond) - state.start_time
      tool_result_json = PtcToolProtocol.render_error(:memory_limit, error_msg)
      error_step = Step.error(:memory_limit_exceeded, error_msg, lisp_step.memory)

      final_messages =
        state.messages ++
          assistant_with_tool_calls_messages(assistant_content, [native_call], [
            {Map.get(native_call, :id) || Map.get(native_call, "id"), tool_result_json}
          ])

      final_step =
        StepAssembler.finalize(error_step, state,
          duration_ms: duration_ms,
          memory_bytes: actual_size,
          is_error: true,
          final_turn: turn,
          final_messages: final_messages,
          journal: lisp_step.journal,
          child_steps: state.child_steps ++ lisp_step.child_steps
        )

      {:stop, {:error, final_step}, turn, state.turn_tokens}
    end
  end

  # ----------------------------------------------------------------
  # Direct final-answer path (R9, R10, R16)
  # ----------------------------------------------------------------

  defp handle_direct_final(nil, agent, state) do
    # No tool calls and no content — treat as malformed assistant turn.
    error_message =
      "Assistant turn returned no content and no tool calls. Either call ptc_lisp_execute or return the final answer directly."

    direct_final_feedback_continuation(error_message, agent, state, "")
  end

  defp handle_direct_final(content, agent, state) when is_binary(content) do
    if fenced_clojure_content?(content) do
      # R16 — targeted feedback, no signature validation
      msg =
        "In ptc_transport: :tool_call, call the ptc_lisp_execute tool with the program instead of returning fenced code."

      direct_final_feedback_continuation(msg, agent, state, content)
    else
      process_direct_final_content(content, agent, state)
    end
  end

  defp process_direct_final_content(content, agent, state) do
    case agent.parsed_signature do
      nil ->
        complete_direct_final(content, content, agent, state)

      {:signature, _params, :string} ->
        complete_direct_final(content, content, agent, state)

      {:signature, _params, :any} ->
        complete_direct_final(content, content, agent, state)

      {:signature, _params, return_type} ->
        parse_and_complete_direct_final(content, return_type, agent, state)
    end
  end

  defp parse_and_complete_direct_final(content, return_type, agent, state) do
    trimmed = String.trim(content)

    case parse_for_type(trimmed, return_type) do
      {:ok, parsed} ->
        coerced = JsonHandler.atomize_value(parsed, return_type)

        case JsonHandler.validate_return(agent, coerced) do
          :ok ->
            complete_direct_final(coerced, content, agent, state)

          {:error, errors} ->
            msg =
              "Return validation failed: " <>
                JsonHandler.format_validation_errors(errors)

            direct_final_feedback_continuation(msg, agent, state, content)
        end

      {:error, message} ->
        direct_final_feedback_continuation(message, agent, state, content)
    end
  end

  # Parse a piece of content into a value of the expected type.
  # `:datetime` accepts both JSON-quoted ISO-8601 and a bare ISO-8601 string.
  defp parse_for_type(content, :datetime) do
    case Jason.decode(content) do
      {:ok, val} ->
        {:ok, val}

      {:error, _} ->
        case DateTime.from_iso8601(content) do
          {:ok, _dt, _offset} -> {:ok, content}
          {:error, _} -> {:error, "Could not parse datetime from response: #{inspect(content)}"}
        end
    end
  end

  defp parse_for_type(content, {:optional, _inner}) do
    case Jason.decode(content) do
      {:ok, val} -> {:ok, val}
      {:error, _} -> {:error, "Could not parse JSON from response."}
    end
  end

  defp parse_for_type(content, _type) do
    case Jason.decode(content) do
      {:ok, val} -> {:ok, val}
      {:error, _} -> {:error, "Could not parse JSON from response."}
    end
  end

  # Build the final Step for a direct content answer, preserving PTC loop state (R10).
  # Does NOT reuse JsonHandler's step-building path (per the plan); builds a
  # PTC-aware Step inline so memory / journal / tool_cache / child_steps /
  # summaries from the latest accumulated loop state flow through to the
  # caller, even when zero `ptc_lisp_execute` calls happened.
  defp complete_direct_final(value, raw_content, agent, state) do
    normalized_return = KeyNormalizer.normalize_keys(value)

    turn =
      Metrics.build_turn(state, raw_content, nil, normalized_return,
        success?: true,
        prints: [],
        tool_calls: [],
        memory: state.memory,
        type: state.current_turn_type || :normal
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    final_messages = state.messages ++ [%{role: :assistant, content: raw_content}]

    final_step = %Step{
      return: normalized_return,
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
      messages: collected_messages(state, final_messages),
      prompt: state.expanded_prompt,
      original_prompt: state.original_prompt,
      prints: [],
      tool_calls: [],
      tools: state.normalized_tools,
      name: state.agent_name,
      child_steps: state.child_steps,
      tool_cache: state.tool_cache || %{},
      summaries: state.summaries || %{}
    }

    {:stop, {:ok, final_step}, turn, state.turn_tokens}
  end

  defp collected_messages(%{collect_messages: false}, _messages), do: nil

  defp collected_messages(%{collect_messages: true} = state, messages) do
    case state.collected_system_prompt do
      nil -> messages
      sys -> [%{role: :system, content: sys} | messages]
    end
  end

  defp direct_final_feedback_continuation(message, agent, state, raw_content) do
    feedback = TurnFeedback.build_error_feedback(message, agent, state)

    turn =
      Metrics.build_turn(
        state,
        raw_content,
        nil,
        %{reason: :direct_final_invalid, message: message},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: state.memory,
        type: state.current_turn_type
      )

    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++
            [
              %{role: :assistant, content: raw_content},
              %{role: :user, content: feedback}
            ],
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        work_turns_remaining: decrement_work(state),
        retry_turns_remaining: decrement_retry(state),
        last_return_error: message,
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  # ----------------------------------------------------------------
  # Protocol-error recovery path (R12, R13, R14)
  # ----------------------------------------------------------------

  defp recover_protocol_error(rejected_calls, assistant_content, reason, message, agent, state) do
    tool_result_json = protocol_error_tool_result_json(reason, message)

    paired =
      Enum.map(rejected_calls, fn %{id: id} -> {id, tool_result_json} end)

    canonical_call = List.first(rejected_calls) || %{id: nil, name: nil}

    fake_native_call_for_turn = %{
      id: canonical_call.id,
      name: canonical_call.name,
      args: %{}
    }

    feedback = TurnFeedback.build_error_feedback(message, agent, state)

    turn =
      Metrics.build_turn(
        state,
        raw_response_for_turn(assistant_content, fake_native_call_for_turn),
        nil,
        %{reason: reason, message: message},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: state.memory,
        type: state.current_turn_type
      )

    # Build assistant + tool messages directly so multi-call rejection
    # produces one paired tool message per id.
    raw_calls_for_message = build_native_calls_for_history(rejected_calls)

    assistant_msg = %{
      role: :assistant,
      content: assistant_content || "",
      tool_calls: raw_calls_for_message
    }

    tool_msgs =
      Enum.map(paired, fn {id, json} ->
        %{role: :tool, tool_call_id: id, content: json}
      end)

    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++ [assistant_msg | tool_msgs] ++ [%{role: :user, content: feedback}],
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        work_turns_remaining: decrement_work(state),
        retry_turns_remaining: decrement_retry(state),
        last_return_error: message,
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp build_continuation_state(
         state,
         turn,
         assistant_content,
         native_call,
         tool_result_json,
         opts
       ) do
    in_retry_phase = state.work_turns_remaining <= 0

    {new_work_turns, new_retry_turns} =
      if in_retry_phase do
        {state.work_turns_remaining, state.retry_turns_remaining - 1}
      else
        {state.work_turns_remaining - 1, state.retry_turns_remaining}
      end

    id = Map.get(native_call, :id) || Map.get(native_call, "id")

    new_messages =
      state.messages ++
        assistant_with_tool_calls_messages(assistant_content, [native_call], [
          {id, tool_result_json}
        ])

    %{
      state
      | turn: state.turn + 1,
        messages: new_messages,
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        work_turns_remaining: new_work_turns,
        retry_turns_remaining: new_retry_turns,
        memory: Keyword.get(opts, :memory, state.memory),
        journal: Keyword.get(opts, :journal, state.journal),
        summaries: Keyword.get(opts, :summaries, state.summaries),
        last_fail: Keyword.get(opts, :last_fail),
        last_return_error: Keyword.get(opts, :last_return_error),
        turn_history: Keyword.get(opts, :turn_history, state.turn_history),
        tool_cache: Keyword.get(opts, :tool_cache, state.tool_cache),
        child_steps: Keyword.get(opts, :child_steps, state.child_steps),
        turn_tokens: state.turn_tokens
    }
  end

  defp assistant_with_tool_calls_messages(assistant_content, native_calls, paired_results) do
    raw_calls = build_native_calls_for_history(native_calls)

    assistant_msg = %{
      role: :assistant,
      content: assistant_content || "",
      tool_calls: raw_calls
    }

    tool_msgs =
      Enum.map(paired_results, fn {id, content} ->
        %{role: :tool, tool_call_id: id, content: content}
      end)

    [assistant_msg | tool_msgs]
  end

  defp build_native_calls_for_history(calls) do
    Enum.map(calls, fn c ->
      id = Map.get(c, :id) || Map.get(c, "id")
      name = Map.get(c, :name) || Map.get(c, "name")
      args = Map.get(c, :args) || Map.get(c, "args") || %{}

      %{
        id: id,
        type: "function",
        function: %{
          name: name,
          arguments: if(is_binary(args), do: args, else: Jason.encode!(args))
        }
      }
    end)
  end

  defp raw_response_for_turn(content, native_call) do
    # The "raw response" stored on the Turn is what the LLM returned.
    # In :tool_call mode, the relevant artifact is the native tool_call
    # invocation rather than fenced text. Combine content (if any) with
    # an inspectable summary of the call so trace viewers can show both.
    summary = inspect(Map.take(native_call, [:id, :name, :args]))

    if is_binary(content) and content != "" do
      content <> "\n" <> summary
    else
      summary
    end
  end

  defp build_lisp_opts(agent, state, exec_context, all_tools) do
    [
      context: exec_context,
      memory: state.memory,
      tools: all_tools,
      turn_history: state.turn_history,
      float_precision: agent.float_precision,
      max_print_length: Keyword.get(agent.format_options, :max_print_length),
      timeout: agent.timeout,
      pmap_timeout: agent.pmap_timeout,
      pmap_max_concurrency: agent.pmap_max_concurrency,
      budget: Budget.build_introspection_map(agent, state),
      trace_context: state.trace_context,
      journal: state.journal,
      tool_cache: state.tool_cache
    ]
    |> maybe_put(:max_heap, state.max_heap)
    |> maybe_put(:max_tool_calls, agent.max_tool_calls)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp decrement_work(state) do
    if state.work_turns_remaining > 0,
      do: state.work_turns_remaining - 1,
      else: state.work_turns_remaining
  end

  defp decrement_retry(state) do
    if state.work_turns_remaining > 0 do
      state.retry_turns_remaining
    else
      max(state.retry_turns_remaining - 1, 0)
    end
  end

  defp update_turn_history(history, new_result) do
    (history ++ [new_result]) |> Enum.take(-3)
  end

  defp memory_size(memory) when is_map(memory), do: :erlang.external_size(memory)

  defp check_memory_limit(memory, limit) when is_integer(limit) do
    size = memory_size(memory)
    if size > limit, do: {:error, :memory_limit_exceeded, size}, else: {:ok, size}
  end

  defp check_memory_limit(_memory, nil), do: {:ok, 0}

  # Delegate to `Loop.emit_pmap_telemetry/2` so `:tool_call` mode emits
  # the same `[:pmap, :start | :stop]` / `[:pcalls, :start | :stop]`
  # events as `:content` mode (R27).
  defp emit_pmap_telemetry(state, lisp_step) do
    Loop.emit_pmap_telemetry(state, lisp_step)
  end

  # ----------------------------------------------------------------
  # Argument extraction (R14)
  # ----------------------------------------------------------------

  defp extract_program(call) do
    if Map.has_key?(call, :args_error) and call.args_error do
      {:error, :args_error, "Invalid tool arguments: #{call.args_error}"}
    else
      args = Map.get(call, :args) || Map.get(call, "args")
      program = if is_map(args), do: Map.get(args, "program") || Map.get(args, :program)

      validate_program(program)
    end
  end

  defp validate_program(nil) do
    {:error, :args_error, "ptc_lisp_execute requires a non-empty `program` string argument."}
  end

  defp validate_program(program) when not is_binary(program) do
    {:error, :args_error, "ptc_lisp_execute `program` must be a string, got #{inspect(program)}."}
  end

  defp validate_program(program) when is_binary(program) do
    if String.trim(program) == "" do
      {:error, :args_error, "ptc_lisp_execute `program` must be a non-empty string."}
    else
      {:ok, program}
    end
  end

  # ----------------------------------------------------------------
  # Tool-result JSON shapers
  # ----------------------------------------------------------------
  #
  # Success and execution-error rendering moved to
  # `PtcRunner.PtcToolProtocol` (Tier 0 of the text-mode plan); call
  # sites delegate to `PtcToolProtocol.render_success/2` and
  # `PtcToolProtocol.render_error/3`.
  #
  # Protocol-error rendering stays local: protocol errors
  # (`multiple_tool_calls`, `mixed_with_ptc_lisp_execute`,
  # `unknown_tool`) are reasons specific to the v1 PTC `:tool_call`
  # transport. They are *not* members of the shared
  # `PtcToolProtocol.error_reason()` union — that union is reserved for
  # in-program failure modes. Keeping this renderer local prevents the
  # shared protocol surface from leaking transport-level concerns.

  @doc false
  @spec protocol_error_tool_result_json(atom(), String.t()) :: String.t()
  def protocol_error_tool_result_json(reason, message) do
    Jason.encode!(%{
      "status" => "error",
      "reason" => Atom.to_string(reason),
      "message" => message,
      "feedback" => message
    })
  end

  # Reached only via Lisp.run/2's `{:error, lisp_step}` branch where
  # `lisp_step.fail` is always a populated map per `Step.fail()` —
  # dialyzer narrows the input type accordingly, so no nil clause needed.
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

  # ----------------------------------------------------------------
  # Protocol-error message renderers (R24)
  # ----------------------------------------------------------------

  defp unknown_tool_message(name) do
    "Unknown native tool `#{inspect(name)}`. Only `ptc_lisp_execute` is available natively in this transport."
  end

  defp multiple_tool_calls_message do
    "exactly one ptc_lisp_execute call per assistant turn"
  end

  # ----------------------------------------------------------------
  # Fenced-clojure detection (R16)
  # ----------------------------------------------------------------

  defp fenced_clojure_content?(content) do
    blocks = ResponseHandler.extract_fenced_blocks(content)

    Enum.any?(blocks, fn {lang, body} ->
      lang in ["clojure", "lisp"] or
        (lang == "" and String.starts_with?(String.trim(body), "("))
    end)
  end
end
