defmodule PtcRunner.SubAgent.Loop.JsonHandler do
  @moduledoc """
  Shared JSON response handling for text mode variants.

  Extracted from JsonMode and ToolCallingMode to eliminate duplication.
  Provides JSON parsing, validation, key atomization, and error handling
  that is shared across the json-only and tool-calling code paths.
  """

  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{JsonParser, KeyNormalizer, Signature}
  alias PtcRunner.SubAgent.Loop.Metrics

  # ============================================================
  # JSON Response Handling
  # ============================================================

  @doc """
  Handle a JSON answer from an LLM response.

  Parses JSON from the response content, validates against the agent's signature,
  and returns the appropriate signal for the driver loop.

  Returns:
  - `{:stop, {:ok, step}, turn, turn_tokens}` on success
  - `{:stop, {:error, step}, turn, turn_tokens}` on final failure
  - `{:continue, state, turn}` for retry with feedback
  """
  @spec handle_json_answer(String.t(), SubAgent.t(), map(), keyword()) ::
          {:continue, map(), map()}
          | {:stop, {:ok | :error, Step.t()}, map() | nil, map() | nil}
  def handle_json_answer(content, agent, state, opts \\ []) do
    case JsonParser.parse(content) do
      {:ok, parsed} when is_map(parsed) ->
        if signature_expects_list?(agent.parsed_signature) do
          case Map.get(parsed, "items") || Map.get(parsed, :items) do
            items when is_list(items) ->
              validate_and_complete_list(items, content, agent, state, opts)

            _ ->
              handle_parse_error(
                "Expected {\"items\": [...]} wrapper for array response",
                content,
                agent,
                state,
                opts
              )
          end
        else
          validate_and_complete(parsed, content, agent, state, opts)
        end

      {:ok, parsed} when is_list(parsed) ->
        if signature_expects_list?(agent.parsed_signature) do
          validate_and_complete_list(parsed, content, agent, state, opts)
        else
          handle_parse_error(
            "Response must be a JSON object, not an array or primitive",
            content,
            agent,
            state,
            opts
          )
        end

      {:ok, _primitive} ->
        handle_parse_error(
          "Response must be a JSON object, not an array or primitive",
          content,
          agent,
          state,
          opts
        )

      {:error, :no_json_found} ->
        handle_parse_error("No valid JSON found in response", content, agent, state, opts)

      {:error, :invalid_json} ->
        handle_parse_error("JSON parse error", content, agent, state, opts)
    end
  end

  # ============================================================
  # Signature Helpers
  # ============================================================

  @doc "Check if the signature expects a list as return type."
  @spec signature_expects_list?(term()) :: boolean()
  def signature_expects_list?(nil), do: false
  def signature_expects_list?({:signature, _params, {:list, _}}), do: true
  def signature_expects_list?(_), do: false

  # ============================================================
  # Key Atomization
  # ============================================================

  @doc "Atomize map keys based on signature (safe conversion)."
  @spec atomize_keys(map(), term()) :: map()
  def atomize_keys(map, nil) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key =
        case k do
          k when is_atom(k) -> k
          k when is_binary(k) -> safe_to_atom(k)
        end

      {key, atomize_value(v, nil)}
    end)
  end

  def atomize_keys(map, {:signature, _params, return_type}) when is_map(map) do
    atomize_value(map, return_type)
  end

  @doc "Atomize list elements based on signature."
  @spec atomize_list(list(), term()) :: list()
  def atomize_list(list, {:signature, _params, {:list, inner_type}}) when is_list(list) do
    Enum.map(list, &atomize_value(&1, inner_type))
  end

  def atomize_list(list, _) when is_list(list), do: list

  @doc "Atomize value based on expected type."
  @spec atomize_value(term(), term()) :: term()
  def atomize_value(map, {:map, fields}) when is_map(map) do
    field_types = Map.new(fields)

    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_atom(k), else: k
      field_type = Map.get(field_types, to_string(key)) || Map.get(field_types, k)
      {key, atomize_value(v, field_type)}
    end)
  end

  def atomize_value(list, {:list, inner_type}) when is_list(list) do
    Enum.map(list, &atomize_value(&1, inner_type))
  end

  def atomize_value(value, {:optional, inner_type}) do
    atomize_value(value, inner_type)
  end

  def atomize_value(map, _type) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: safe_to_atom(k), else: k
      {key, atomize_value(v, nil)}
    end)
  end

  def atomize_value(list, _type) when is_list(list) do
    Enum.map(list, &atomize_value(&1, nil))
  end

  def atomize_value(value, _type), do: value

  @doc "Safe atom conversion - try existing atom first, keep string if not found."
  @spec safe_to_atom(String.t()) :: atom() | String.t()
  def safe_to_atom(string) when is_binary(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  # ============================================================
  # Validation
  # ============================================================

  @doc "Validate return value against signature."
  @spec validate_return(SubAgent.t(), term()) :: :ok | {:error, list()}
  def validate_return(%{parsed_signature: nil}, _value), do: :ok
  def validate_return(%{parsed_signature: {:signature, _, :any}}, _value), do: :ok

  def validate_return(%{parsed_signature: parsed_sig}, value) do
    Signature.validate(parsed_sig, value)
  end

  @doc "Format validation errors for display."
  @spec format_validation_errors(list()) :: String.t()
  def format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
      path_str = if path == [], do: "root", else: Enum.join(path, ".")
      "#{path_str}: #{message}"
    end)
  end

  # ============================================================
  # Validate and Complete
  # ============================================================

  @doc "Validate parsed JSON map and complete or retry."
  @spec validate_and_complete(map(), String.t(), SubAgent.t(), map(), keyword()) ::
          {:continue, map(), map()}
          | {:stop, {:ok | :error, Step.t()}, map() | nil, map() | nil}
  def validate_and_complete(parsed, response, agent, state, opts \\ []) do
    atomized = atomize_keys(parsed, agent.parsed_signature)

    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent, opts)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state, opts)
    end
  end

  @doc "Validate parsed list and complete or retry."
  @spec validate_and_complete_list(list(), String.t(), SubAgent.t(), map(), keyword()) ::
          {:continue, map(), map()}
          | {:stop, {:ok | :error, Step.t()}, map() | nil, map() | nil}
  def validate_and_complete_list(parsed_list, response, agent, state, opts \\ []) do
    atomized = atomize_list(parsed_list, agent.parsed_signature)

    case validate_return(agent, atomized) do
      :ok ->
        {turn, step} = build_success_step(atomized, response, state, agent, opts)
        {:stop, {:ok, step}, turn, state.turn_tokens}

      {:error, validation_errors} ->
        handle_validation_error(validation_errors, response, agent, state, opts)
    end
  end

  # ============================================================
  # Error Handling
  # ============================================================

  @doc "Handle parse error - retry with feedback or return error signal."
  @spec handle_parse_error(String.t(), String.t(), SubAgent.t(), map(), keyword()) ::
          {:continue, map(), map()}
          | {:stop, {:error, Step.t()}, map() | nil, map() | nil}
  def handle_parse_error(error, response, agent, state, opts \\ []) do
    if state.turn >= agent.max_turns do
      {turn, step} = build_error_step(:json_parse_error, error, response, state, agent, opts)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      retry_with_feedback(error, response, agent, state, opts)
    end
  end

  @doc "Handle validation error - retry with feedback or return error signal."
  @spec handle_validation_error(list(), String.t(), SubAgent.t(), map(), keyword()) ::
          {:continue, map(), map()}
          | {:stop, {:error, Step.t()}, map() | nil, map() | nil}
  def handle_validation_error(errors, response, agent, state, opts \\ []) do
    error_msg = format_validation_errors(errors)

    if state.turn >= agent.max_turns do
      {turn, step} = build_error_step(:validation_error, error_msg, response, state, agent, opts)
      {:stop, {:error, step}, turn, state.turn_tokens}
    else
      retry_with_feedback(error_msg, response, agent, state, opts)
    end
  end

  # ============================================================
  # Step Building
  # ============================================================

  defp build_success_step(return_value, response, state, agent, opts) do
    normalized_return = KeyNormalizer.normalize_keys(return_value)

    # Tool calling mode includes tool_calls in the turn and step
    all_tool_calls = Keyword.get(opts, :all_tool_calls, [])

    turn =
      Metrics.build_turn(state, response, nil, normalized_return,
        success?: true,
        prints: [],
        tool_calls: all_tool_calls,
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    # Build usage - add schema metrics if schema present
    usage =
      state
      |> Metrics.build_final_usage(duration_ms, 0)
      |> add_schema_metrics(state[:schema])

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
      tool_calls: all_tool_calls,
      tools: state[:normalized_tools]
    }

    {turn, final_step}
  end

  defp build_error_step(reason, message, response, state, _agent, opts) do
    all_tool_calls = Keyword.get(opts, :all_tool_calls, [])

    turn =
      Metrics.build_turn(state, response, nil, %{error: message},
        success?: false,
        prints: [],
        tool_calls: all_tool_calls,
        memory: %{}
      )

    duration_ms = System.monotonic_time(:millisecond) - state.start_time
    error_step = Step.error(reason, message, %{})
    final_messages = state.messages ++ [%{role: :assistant, content: response}]

    usage =
      state
      |> Metrics.build_final_usage(duration_ms, 0)
      |> add_schema_metrics(state[:schema])

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

  # ============================================================
  # Retry
  # ============================================================

  defp retry_with_feedback(error, response, _agent, state, opts) do
    build_error_feedback = Keyword.get(opts, :build_error_feedback)

    error_message =
      if build_error_feedback do
        build_error_feedback.(error, response)
      else
        "Error: #{error}. Please return a valid JSON object matching the expected output format."
      end

    turn =
      Metrics.build_turn(state, response, nil, %{error: error},
        success?: false,
        prints: [],
        tool_calls: [],
        memory: %{}
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
        turns: [turn | state.turns],
        remaining_turns: state.remaining_turns - 1,
        turn_tokens: state.turn_tokens
    }

    {:continue, new_state, turn}
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp add_schema_metrics(usage, schema) when is_map(schema) do
    schema_json = Jason.encode!(schema)

    usage
    |> Map.put(:schema_used, true)
    |> Map.put(:schema_bytes, byte_size(schema_json))
  end

  defp add_schema_metrics(usage, _), do: Map.put(usage, :schema_used, false)

  defp build_collected_messages(%{collect_messages: false}, _messages), do: nil

  defp build_collected_messages(%{collect_messages: true} = state, messages) do
    system_prompt = Map.get(state, :current_system_prompt, "")
    [%{role: :system, content: system_prompt} | messages]
  end
end
