defmodule PtcRunner.SubAgent.Loop.JsonMode do
  @moduledoc """
  Execution loop for JSON output mode.

  JSON mode is a simpler alternative to PTC-Lisp execution where the LLM
  returns structured JSON directly, validated against the agent's signature.

  ## Flow

  1. Build prompt using JSON templates (no PTC-Lisp spec)
  2. Call LLM with `%{output: :json, schema: ...}` in input
  3. Parse JSON from response
  4. Validate against signature
  5. If invalid and turns remaining → retry with error feedback
  6. Return `Step` struct with parsed JSON (atom keys)

  ## Differences from PTC-Lisp Mode

  | Aspect | PTC-Lisp | JSON Mode |
  |--------|----------|-----------|
  | System prompt | Full spec + tool docs | Minimal (json-system.md) |
  | Response parsing | ResponseHandler.parse | Jason.decode |
  | Execution | Lisp.run/2 | None (direct validation) |
  | Return value | From `(return ...)` | Parsed JSON |
  | Memory | Accumulated | Always `%{}` |
  | Retries | On execution error | On validation error |

  This is an internal module called by `SubAgent.run/2` when `output: :json`.
  """

  alias PtcRunner.Prompts
  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{JsonParser, KeyNormalizer, Signature, Telemetry}
  alias PtcRunner.SubAgent.Loop.{LLMRetry, Metrics}
  alias PtcRunner.Turn

  @doc """
  Generate a preview of the JSON mode prompts.

  Returns the system and user messages that would be sent to the LLM,
  plus the JSON schema used for validation.
  """
  @spec preview_prompt(SubAgent.t(), map()) :: %{
          system: String.t(),
          user: String.t(),
          schema: map() | nil
        }
  def preview_prompt(%SubAgent{} = agent, context) do
    alias PtcRunner.SubAgent.PromptExpander

    # Expand the mission template with actual values (JSON mode has no Data section)
    {:ok, expanded_prompt} = PromptExpander.expand(agent.prompt, context, on_missing: :keep)

    # Build user message using the same logic as the execution loop
    state = %{context: context, expanded_prompt: expanded_prompt}
    user_message = build_user_message(agent, state)

    %{
      system: build_system_prompt(agent),
      user: user_message,
      schema: build_schema(agent)
    }
  end

  @doc """
  Execute a SubAgent in JSON mode.

  ## Parameters

  - `agent` - A `%SubAgent{}` struct with `output: :json`
  - `llm` - LLM callback function
  - `state` - Initial loop state from Loop.run/2

  ## Returns

  - `{:ok, Step.t()}` on success
  - `{:error, Step.t()}` on failure
  """
  @spec run(SubAgent.t(), term(), map()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(%SubAgent{} = agent, llm, state) do
    # Initial JSON mode state
    json_state =
      state
      |> Map.put(:schema, build_schema(agent))
      |> Map.put(:json_mode, true)

    json_driver_loop(agent, llm, json_state)
  end

  # ============================================================
  # Termination Checks
  # ============================================================

  # Check all termination conditions before executing a turn.
  # Returns {:stop, result} to terminate or :continue to proceed.
  @spec check_json_termination(SubAgent.t(), map()) :: {:stop, {:error, Step.t()}} | :continue
  defp check_json_termination(agent, state) do
    cond do
      # Max turns exceeded
      state.turn > agent.max_turns ->
        {:stop,
         build_termination_error(
           :max_turns_exceeded,
           "Exceeded max_turns limit of #{agent.max_turns}",
           state
         )}

      # Global turn budget exhausted
      state.remaining_turns <= 0 ->
        {:stop, build_termination_error(:turn_budget_exhausted, "Turn budget exhausted", state)}

      # Mission timeout exceeded
      state.mission_deadline && mission_timeout_exceeded?(state.mission_deadline) ->
        {:stop, build_termination_error(:mission_timeout, "Mission timeout exceeded", state)}

      true ->
        :continue
    end
  end

  # ============================================================
  # Iterative Driver Loop (TCO-friendly)
  # ============================================================

  # Main iterative loop that drives JSON mode execution.
  # Emits telemetry immediately after each turn completes.
  @spec json_driver_loop(SubAgent.t(), term(), map()) :: {:ok, Step.t()} | {:error, Step.t()}
  defp json_driver_loop(agent, llm, state) do
    case check_json_termination(agent, state) do
      {:stop, result} ->
        result

      :continue ->
        # JSON mode always uses :normal turn type
        state = Map.put(state, :current_turn_type, :normal)

        # Emit turn start event (consistent metadata with PTC-Lisp mode)
        Telemetry.emit([:turn, :start], %{}, %{
          agent: agent,
          turn: state.turn,
          type: :normal,
          tools_count: 0
        })

        turn_start = System.monotonic_time()

        # Execute single turn - returns signal
        case execute_json_turn(agent, llm, state) do
          {:continue, next_state, turn} ->
            # Emit turn stop IMMEDIATELY (not batched)
            Metrics.emit_turn_stop_immediate(
              turn,
              agent,
              state,
              turn_start,
              next_state.turn_tokens
            )

            # TCO: tail-recursive call
            json_driver_loop(agent, llm, next_state)

          {:stop, result, turn, turn_tokens} ->
            # Emit turn stop for final turn
            Metrics.emit_turn_stop_immediate(turn, agent, state, turn_start, turn_tokens)
            result
        end
    end
  end

  # Execute a single JSON mode turn
  @spec execute_json_turn(SubAgent.t(), term(), map()) ::
          {:continue, map(), Turn.t()}
          | {:stop, {:ok | :error, Step.t()}, Turn.t() | nil, map() | nil}
  defp execute_json_turn(agent, llm, state) do
    # Build prompts - apply system_prompt customization if provided
    system_prompt = build_system_prompt(agent)

    # For first turn, build user message from template
    # For subsequent turns, use accumulated messages
    messages =
      if state.turn == 1 do
        user_message = build_user_message(agent, state)
        [%{role: :user, content: user_message}]
      else
        state.messages
      end

    # Build LLM input with JSON mode indicator
    llm_input = %{
      system: system_prompt,
      messages: messages,
      turn: state.turn,
      output: :json,
      schema: state.schema,
      cache: state.cache
    }

    # Call LLM with telemetry
    case call_llm_with_telemetry(llm, llm_input, state, agent) do
      {:ok, %{content: content, tokens: tokens}} ->
        state_with_tokens =
          state
          |> Metrics.accumulate_tokens(tokens)
          |> Map.put(:current_messages, messages)
          |> Map.put(:current_system_prompt, system_prompt)

        handle_json_response(content, agent, state_with_tokens)

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

  # Build JSON schema from agent's parsed signature (or nil if no signature)
  defp build_schema(%{parsed_signature: sig}) when not is_nil(sig),
    do: Signature.to_json_schema(sig)

  defp build_schema(_), do: nil

  # Build user message from template
  defp build_user_message(agent, state) do
    # Build output instruction based on return type
    output_instruction = format_output_instruction(agent)

    # Build field descriptions from signature
    field_descriptions = format_field_descriptions(agent)

    # Build example output from signature
    example_output = format_example_output(agent)

    # Expand the user message template
    # Note: Data is embedded via mustache in expanded_prompt (no separate data section)
    Prompts.json_user()
    |> String.replace("{{task}}", state.expanded_prompt)
    |> String.replace("{{output_instruction}}", output_instruction)
    |> String.replace("{{field_descriptions}}", field_descriptions)
    |> String.replace("{{example_output}}", example_output)
  end

  # Format output instruction based on return type
  defp format_output_instruction(%{parsed_signature: nil}) do
    "Return a JSON object with these fields:"
  end

  defp format_output_instruction(%{parsed_signature: {:signature, _params, {:list, _}}}) do
    "Return a JSON array:"
  end

  defp format_output_instruction(%{parsed_signature: {:signature, _params, _return_type}}) do
    "Return a JSON object with these fields:"
  end

  # Format field descriptions from signature
  defp format_field_descriptions(%{parsed_signature: nil}) do
    "(any valid JSON object)"
  end

  defp format_field_descriptions(%{parsed_signature: {:signature, _params, return_type}} = agent) do
    format_type_description(return_type, agent.field_descriptions || %{})
  end

  # Format type as field descriptions
  defp format_type_description({:map, fields}, field_descriptions) do
    Enum.map_join(fields, "\n", fn {name, type} ->
      type_str = format_type_name(type)
      desc = Map.get(field_descriptions, String.to_atom(name), "")
      desc_part = if desc != "", do: " - #{desc}", else: ""
      "- `#{name}` (#{type_str})#{desc_part}"
    end)
  end

  defp format_type_description(type, _field_descriptions) do
    "(#{format_type_name(type)})"
  end

  # Format type name for display
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

  # Format example output from signature
  defp format_example_output(%{parsed_signature: nil}) do
    ~s|{"field": "value"}|
  end

  defp format_example_output(%{parsed_signature: {:signature, _params, return_type}}) do
    example = build_example_value(return_type)
    Jason.encode!(example, pretty: true)
  end

  # Build example value for a type
  defp build_example_value(:string), do: "..."
  defp build_example_value(:int), do: 0
  defp build_example_value(:float), do: 0.0
  defp build_example_value(:bool), do: true
  defp build_example_value(:keyword), do: "keyword"
  defp build_example_value(:any), do: nil
  defp build_example_value(:map), do: %{}
  defp build_example_value({:list, inner}), do: [build_example_value(inner)]
  defp build_example_value({:optional, inner}), do: build_example_value(inner)

  defp build_example_value({:map, fields}) do
    fields
    |> Enum.map(fn {name, type} -> {name, build_example_value(type)} end)
    |> Map.new()
  end

  # Call LLM with telemetry wrapper
  defp call_llm_with_telemetry(llm, input, state, agent) do
    start_meta = %{agent: agent, turn: state.turn, messages: input.messages}

    Telemetry.span([:llm], start_meta, fn ->
      result = LLMRetry.call_with_retry(llm, input, state.llm_registry, state.llm_retry)

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

  # Handle JSON response - parse and validate
  # Returns signal: {:continue, state, turn} or {:stop, result, turn, turn_tokens}
  @spec handle_json_response(String.t(), SubAgent.t(), map()) ::
          {:continue, map(), Turn.t()}
          | {:stop, {:ok | :error, Step.t()}, Turn.t() | nil, map() | nil}
  defp handle_json_response(response, agent, state) do
    # Parse JSON from response
    case JsonParser.parse(response) do
      {:ok, parsed} when is_map(parsed) ->
        # Check if this is a wrapped array response (schema wraps arrays in {"items": [...]})
        if signature_expects_list?(agent.parsed_signature) do
          case Map.get(parsed, "items") || Map.get(parsed, :items) do
            items when is_list(items) ->
              validate_and_complete_list(items, response, agent, state)

            _ ->
              handle_parse_error(
                "Expected {\"items\": [...]} wrapper for array response",
                response,
                agent,
                state
              )
          end
        else
          validate_and_complete(parsed, response, agent, state)
        end

      {:ok, parsed} when is_list(parsed) ->
        # Direct array response (some LLMs may return this)
        if signature_expects_list?(agent.parsed_signature) do
          validate_and_complete_list(parsed, response, agent, state)
        else
          handle_parse_error(
            "Response must be a JSON object, not an array or primitive",
            response,
            agent,
            state
          )
        end

      {:ok, _primitive} ->
        handle_parse_error(
          "Response must be a JSON object, not an array or primitive",
          response,
          agent,
          state
        )

      {:error, :no_json_found} ->
        handle_parse_error("No valid JSON found in response", response, agent, state)

      {:error, :invalid_json} ->
        handle_parse_error("JSON parse error", response, agent, state)
    end
  end

  # Check if the signature expects a list as return type
  defp signature_expects_list?(nil), do: false
  defp signature_expects_list?({:signature, _params, {:list, _}}), do: true
  defp signature_expects_list?(_), do: false

  # Validate parsed list and complete or retry - returns signal
  defp validate_and_complete_list(parsed_list, response, agent, state) do
    # Atomize elements based on signature's inner type
    atomized = atomize_list(parsed_list, agent.parsed_signature)

    # Validate against signature
    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state)
    end
  end

  # Atomize list elements based on signature
  # Note: Callers already guarantee list input via guards (lines 378, 394)
  defp atomize_list(list, {:signature, _params, {:list, inner_type}}) when is_list(list) do
    Enum.map(list, &atomize_value(&1, inner_type))
  end

  defp atomize_list(list, _) when is_list(list), do: list

  # Validate parsed JSON and complete or retry - returns signal
  defp validate_and_complete(parsed, response, agent, state) do
    # Convert string keys to atoms (safe - from signature)
    atomized = atomize_keys(parsed, agent.parsed_signature)

    # Validate against signature if present
    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state)
    end
  end

  # Validate return value against signature
  defp validate_return(%{parsed_signature: nil}, _value), do: :ok
  defp validate_return(%{parsed_signature: {:signature, _, :any}}, _value), do: :ok

  defp validate_return(%{parsed_signature: parsed_sig}, value) do
    Signature.validate(parsed_sig, value)
  end

  # Atomize keys based on signature (safe conversion)
  defp atomize_keys(map, nil) when is_map(map) do
    # Without signature, convert all keys using existing_atom (safe)
    Map.new(map, fn {k, v} ->
      key =
        case k do
          k when is_atom(k) -> k
          k when is_binary(k) -> safe_to_atom(k)
        end

      {key, atomize_value(v, nil)}
    end)
  end

  defp atomize_keys(map, {:signature, _params, return_type}) when is_map(map) do
    atomize_value(map, return_type)
  end

  # Atomize value based on expected type
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

  # Safe atom conversion - try existing atom first, keep string if not found
  # This prevents atom table exhaustion from LLM-generated keys
  defp safe_to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  # Handle parse error - retry with feedback or return error signal
  defp handle_parse_error(error, response, agent, state) do
    if state.turn >= agent.max_turns do
      # No more retries - return error
      {turn, step} = build_error_step(:json_parse_error, error, response, state, agent)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      # Retry with error feedback
      retry_with_feedback(error, response, agent, state)
    end
  end

  # Handle validation error - retry with feedback or return error signal
  defp handle_validation_error(errors, response, agent, state) do
    if state.turn >= agent.max_turns do
      # No more retries - return error
      error_msg = format_validation_errors(errors)
      {turn, step} = build_error_step(:validation_error, error_msg, response, state, agent)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      # Retry with error feedback
      error_msg = format_validation_errors(errors)
      retry_with_feedback(error_msg, response, agent, state)
    end
  end

  # Format validation errors for display
  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
      path_str = if path == [], do: "root", else: Enum.join(path, ".")
      "#{path_str}: #{message}"
    end)
  end

  # Retry with error feedback - returns {:continue, new_state, turn} signal
  @spec retry_with_feedback(String.t(), String.t(), SubAgent.t(), map()) ::
          {:continue, map(), Turn.t()}
  defp retry_with_feedback(error, response, agent, state) do
    # Build error feedback message
    error_message = build_error_feedback(error, response, agent)

    # Build Turn struct for the failed attempt
    turn =
      Metrics.build_turn(state, response, nil, %{error: error},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    # Update state for next turn
    new_state = %{
      state
      | turn: state.turn + 1,
        messages:
          state.messages ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: error_message}
            ],
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        # Preserve turn_tokens for telemetry
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  # Build error feedback message from template
  defp build_error_feedback(error, invalid_response, agent) do
    expected_format = format_example_output(agent)

    Prompts.json_error()
    |> String.replace("{{error_message}}", to_string(error))
    |> String.replace("{{invalid_response}}", truncate(invalid_response, 500))
    |> String.replace("{{expected_format}}", expected_format)
  end

  # Truncate string to max length
  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string

  defp truncate(string, max_length) do
    String.slice(string, 0, max_length) <> "..."
  end

  # Build success step - returns {turn, step} tuple for signal construction
  defp build_success_step(return_value, response, state, agent) do
    # Normalize return value keys (hyphen -> underscore at boundary)
    normalized_return = KeyNormalizer.normalize_keys(return_value)

    # Build Turn struct
    turn =
      Metrics.build_turn(state, response, nil, normalized_return,
        success?: true,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    # Include the final assistant response in messages
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    # Build usage with schema metrics
    usage =
      state
      |> Metrics.build_final_usage(duration_ms, 0)
      |> add_schema_metrics(state.schema)

    final_step = %Step{
      return: normalized_return,
      fail: nil,
      memory: %{},
      usage: usage,
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
      prints: [],
      tool_calls: []
    }

    {turn, final_step}
  end

  # Build error step - returns {turn, step} tuple for signal construction
  @spec build_error_step(atom(), String.t(), String.t(), map(), SubAgent.t()) ::
          {Turn.t(), Step.t()}
  defp build_error_step(reason, message, response, state, _agent) do
    # Build Turn struct
    turn =
      Metrics.build_turn(state, response, nil, %{error: message},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time

    error_step = Step.error(reason, message, %{})

    # Include the final assistant response in messages
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    # Build usage with schema metrics
    usage =
      state
      |> Metrics.build_final_usage(duration_ms, 0)
      |> add_schema_metrics(state.schema)

    final_step = %{
      error_step
      | usage: usage,
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

  # Build termination error (max_turns, turn_budget, mission_timeout)
  defp build_termination_error(reason, message, state) do
    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    step = Step.error(reason, message, %{})

    # Build usage with schema metrics
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
        original_prompt: state.original_prompt
    }

    {:error, step_with_metrics}
  end

  # Check if mission timeout has been exceeded
  defp mission_timeout_exceeded?(deadline) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end

  # Build collected messages with system prompt prepended, or nil if not collecting
  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = Map.get(state, :current_system_prompt, Prompts.json_system())
    [%{role: :system, content: system_prompt} | messages]
  end

  # Add schema metrics to usage map
  defp add_schema_metrics(usage, schema) when is_map(schema) do
    schema_json = Jason.encode!(schema)

    usage
    |> Map.put(:schema_used, true)
    |> Map.put(:schema_bytes, byte_size(schema_json))
  end

  defp add_schema_metrics(usage, nil) do
    Map.put(usage, :schema_used, false)
  end

  # Build system prompt with optional customization from agent
  # Supports the same customization options as PTC-Lisp mode:
  # - %{prefix: "...", suffix: "..."} - Wrap default prompt
  # - String - Complete override
  # - Function - Transform default prompt
  defp build_system_prompt(%{system_prompt: nil}), do: Prompts.json_system()

  defp build_system_prompt(%{system_prompt: override}) when is_binary(override), do: override

  defp build_system_prompt(%{system_prompt: transformer}) when is_function(transformer, 1) do
    transformer.(Prompts.json_system())
  end

  defp build_system_prompt(%{system_prompt: opts}) when is_map(opts) do
    base = Prompts.json_system()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")

    [prefix, base, suffix]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp build_system_prompt(_agent), do: Prompts.json_system()
end
