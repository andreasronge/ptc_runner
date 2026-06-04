defmodule PtcRunner.SubAgent.Runner do
  @moduledoc """
  Internal execution boundary for `%PtcRunner.SubAgent.Definition{}` agents.

  Holds the Definition run path — validation, context preparation, the
  single-shot fast path, and dispatch to `PtcRunner.SubAgent.Loop` — so that
  internal callers (the public facade, the compiler) can execute a Definition
  without going through `PtcRunner.SubAgent`. This keeps a single source of
  truth for Definition execution and avoids the facade back-edge in the
  SubAgent dependency cycle.

  The string-convenience and `CompiledAgent` forms of `run/2` remain on the
  public `PtcRunner.SubAgent` facade; only Definition execution lives here.
  """

  alias PtcRunner.SubAgent.Definition
  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.SubAgent.LLMResolver
  alias PtcRunner.SubAgent.Loop
  alias PtcRunner.SubAgent.Loop.Metrics
  alias PtcRunner.SubAgent.Loop.ResponseHandler
  alias PtcRunner.SubAgent.PromptExpander
  alias PtcRunner.SubAgent.SubAgentTool
  alias PtcRunner.SubAgent.SystemPrompt
  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.TraceLog.Collector

  @doc """
  Executes a `%Definition{}` agent with the given runtime options.

  Validates the LLM, prepares context (handling Step auto-chaining), then
  dispatches to either the single-shot fast path or `Loop.run/2`. Returns
  `{:ok, Step.t()}` or `{:error, Step.t()}`.
  """
  @spec run(Definition.t(), keyword()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def run(%Definition{} = agent, opts) do
    # Auto-inject trace_context if TraceLog is active but trace_context not provided
    opts = maybe_inject_trace_context(opts)

    # Resolve :self tools before execution so they have proper signatures in prompts
    agent =
      if Enum.any?(agent.tools, fn {_, v} -> v == :self end) do
        %{agent | tools: resolve_self_tools(agent.tools, agent)}
      else
        agent
      end

    start_time = System.monotonic_time(:millisecond)

    # Validate required llm option
    llm = Keyword.get(opts, :llm) || agent.llm

    # Validate llm_registry if provided
    llm_registry = Keyword.get(opts, :llm_registry, %{})

    with :ok <- validate_llm_presence(llm, start_time),
         :ok <- validate_llm_registry(llm_registry, start_time) do
      # Get and prepare context (handles Step auto-chaining)
      raw_context = Keyword.get(opts, :context, %{})

      # Validate tool/data name conflicts
      validate_tool_data_conflict!(agent.tools, raw_context)

      case prepare_context(raw_context) do
        {:chained_failure, upstream_fail} ->
          # Short-circuit: upstream agent failed
          duration_ms = System.monotonic_time(:millisecond) - start_time

          step =
            PtcRunner.Step.error(
              :chained_failure,
              "Upstream agent failed: #{upstream_fail.reason}",
              %{},
              %{upstream: upstream_fail}
            )

          updated_step = %{step | usage: %{duration_ms: duration_ms, memory_bytes: 0}}
          {:error, updated_step}

        {context, received_field_descriptions} ->
          # Determine execution mode
          # JSON and tool_calling modes always use the loop (even for single-shot)
          # PTC-Lisp single-shot (max_turns == 1, no tools) uses run_single_shot for efficiency
          if agent.completion_mode == :implicit and agent.output == :ptc_lisp and
               agent.max_turns == 1 and map_size(agent.tools) == 0 and agent.retry_turns == 0 do
            # PTC-Lisp single-shot mode
            run_single_shot(
              agent,
              llm,
              context,
              start_time,
              llm_registry,
              received_field_descriptions,
              opts
            )
          else
            # Loop mode (including text mode) - delegate to Loop.run/2
            # Update opts with prepared context and received field descriptions
            updated_opts =
              opts
              |> Keyword.put(:context, context)
              |> Keyword.put(:llm, llm)
              |> Keyword.put(:_received_field_descriptions, received_field_descriptions)

            Loop.run(agent, updated_opts)
          end
      end
    else
      error -> error
    end
  end

  @doc """
  Resolves `:self` sentinels in a tools map to `SubAgentTool` structs.

  Public so the facade's prompt-preview path can reuse the same resolution.
  """
  def resolve_self_tools(tools, agent) do
    Map.new(tools, fn
      {name, :self} ->
        {name,
         %SubAgentTool{
           agent: agent,
           bound_llm: nil,
           signature: agent.signature,
           description:
             agent.description || "Recursively invoke this agent on a subset of the input"
         }}

      other ->
        other
    end)
  end

  defp validate_llm_presence(nil, start_time) do
    return_error(:llm_required, "llm option is required", %{}, start_time)
  end

  defp validate_llm_presence(_llm, _start_time), do: :ok

  defp validate_llm_registry(registry, start_time) when is_map(registry) do
    # Check that all registry values are function/1
    invalid_entries =
      Enum.reject(registry, fn {_key, value} -> is_function(value, 1) end)

    if invalid_entries == [] do
      :ok
    else
      {key, _value} = hd(invalid_entries)

      return_error(
        :invalid_llm_registry,
        "llm_registry values must be function/1. Invalid entry: #{inspect(key)}",
        %{},
        start_time
      )
    end
  end

  defp validate_llm_registry(_registry, start_time) do
    return_error(:invalid_llm_registry, "llm_registry must be a map", %{}, start_time)
  end

  # Validates that tool names don't conflict with context data keys.
  # Conflicts would cause undefined behavior in the tool/ and data/ namespaces.
  defp validate_tool_data_conflict!(tools, _raw_context) when map_size(tools) == 0 do
    # No tools, no conflict possible
    :ok
  end

  defp validate_tool_data_conflict!(tools, %PtcRunner.Step{} = step) do
    # Extract context map from Step
    context_map =
      case step do
        %{fail: fail} when fail != nil -> %{}
        %{return: return} when is_map(return) -> return
        _ -> %{}
      end

    validate_tool_data_conflict!(tools, context_map)
  end

  defp validate_tool_data_conflict!(tools, context) when is_map(context) do
    # Convert tool names to strings for comparison
    tool_names = Map.keys(tools) |> Enum.map(&to_string/1) |> MapSet.new()
    # Convert context keys to strings for comparison
    context_keys = Map.keys(context) |> Enum.map(&to_string/1) |> MapSet.new()

    conflicts = MapSet.intersection(tool_names, context_keys)

    if MapSet.size(conflicts) > 0 do
      conflict_name = conflicts |> MapSet.to_list() |> List.first()
      raise ArgumentError, "#{conflict_name} is both a tool and data - rename one"
    end

    :ok
  end

  defp validate_tool_data_conflict!(_tools, _context), do: :ok

  # Prepares context for execution, handling Step auto-chaining
  # Returns {:chained_failure, fail} | {context_map, field_descriptions | nil}
  defp prepare_context(%PtcRunner.Step{fail: fail} = _step) when fail != nil do
    {:chained_failure, fail}
  end

  defp prepare_context(
         %PtcRunner.Step{fail: nil, return: return, field_descriptions: descs} = _step
       )
       when is_map(return) do
    {return, descs}
  end

  defp prepare_context(%PtcRunner.Step{fail: nil, return: nil, field_descriptions: descs} = _step) do
    {%{}, descs}
  end

  defp prepare_context(%PtcRunner.Step{fail: nil, field_descriptions: descs} = _step) do
    # Non-map return value - can't use as context directly
    # This will be caught by template expansion or signature validation
    {%{}, descs}
  end

  defp prepare_context(context) when is_map(context), do: {context, nil}
  defp prepare_context(nil), do: {%{}, nil}

  # Single-shot execution: one LLM call, no tools, expression result returned
  defp run_single_shot(
         agent,
         llm,
         context,
         _start_time,
         _llm_registry,
         received_field_descriptions,
         opts
       )
       when agent.ptc_transport == :tool_call do
    # `:tool_call` transport always routes through Loop.run/2 even for
    # single-shot agents — the single-shot fast path here only handles
    # the fenced-Clojure (`:content`) response shape.
    updated_opts =
      opts
      |> Keyword.put(:context, context)
      |> Keyword.put(:llm, llm)
      |> Keyword.put(:_received_field_descriptions, received_field_descriptions)

    Loop.run(agent, updated_opts)
  end

  defp run_single_shot(
         agent,
         llm,
         context,
         start_time,
         llm_registry,
         received_field_descriptions,
         opts
       ) do
    collect_messages = Keyword.get(opts, :collect_messages, false)

    # Expand template in mission
    expanded_prompt = expand_template(agent.prompt, context)

    # Build resolution context for language_spec callbacks
    messages = [%{role: :user, content: expanded_prompt}]

    resolution_context = %{
      turn: 1,
      model: llm,
      memory: %{},
      messages: messages
    }

    # Use SystemPrompt.generate for consistency with loop mode
    # Pass received field descriptions for rendering in prompt
    system_prompt =
      SystemPrompt.generate(agent,
        context: context,
        resolution_context: resolution_context,
        received_field_descriptions: received_field_descriptions
      )

    # Build LLM input
    llm_input = %{
      system: system_prompt,
      messages: [%{role: :user, content: expanded_prompt}]
    }

    # Call LLM
    case LLMResolver.resolve(llm, llm_input, llm_registry) do
      {:ok, %{content: content, tokens: tokens}} ->
        # Extract code from response content
        case extract_code(content) do
          {:ok, code} ->
            # Execute via Lisp. The single-shot fast path (max_turns == 1) is a
            # SubAgent execution surface too, so it must attach the configured
            # `runtime_prelude` (plan §1A) — otherwise a program calling a
            # prelude export fails with an unknown namespace. `nil` is inert.
            lisp_result =
              case PtcRunner.Lisp.run(code,
                     context: context,
                     tools: %{},
                     float_precision: agent.float_precision,
                     prelude: agent.runtime_prelude
                   ) do
                {:ok, step} -> Definition.unwrap_sentinels(step)
                other -> other
              end

            # Add usage metrics, field_descriptions, and trace from this execution
            case lisp_result do
              {:ok, step} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time

                trace =
                  build_single_shot_trace(
                    agent,
                    system_prompt,
                    llm_input,
                    content,
                    code,
                    {:ok, step},
                    opts
                  )

                collected_messages =
                  build_single_shot_messages(
                    collect_messages,
                    system_prompt,
                    expanded_prompt,
                    content
                  )

                # Normalize return value keys (hyphen -> underscore at boundary)
                normalized_step = %{step | return: KeyNormalizer.normalize_keys(step.return)}

                updated_step =
                  normalized_step
                  |> update_step_usage(duration_ms, tokens)
                  |> Map.put(:field_descriptions, agent.field_descriptions)
                  |> Map.put(:turns, trace)
                  |> Map.put(:messages, collected_messages)

                {:ok, updated_step}

              {:error, step} ->
                duration_ms = System.monotonic_time(:millisecond) - start_time

                trace =
                  build_single_shot_trace(
                    agent,
                    system_prompt,
                    llm_input,
                    content,
                    code,
                    {:error, step},
                    opts
                  )

                collected_messages =
                  build_single_shot_messages(
                    collect_messages,
                    system_prompt,
                    expanded_prompt,
                    content
                  )

                updated_step =
                  step
                  |> update_step_usage(duration_ms, tokens)
                  |> Map.put(:turns, trace)
                  |> Map.put(:messages, collected_messages)

                {:error, updated_step}
            end

          :none ->
            return_error(
              :no_code_found,
              "No PTC-Lisp code found in LLM response",
              %{},
              start_time
            )
        end

      {:error, reason} ->
        return_error(:llm_error, "LLM call failed: #{inspect(reason)}", %{}, start_time)
    end
  end

  # Expand template placeholders with context values
  defp expand_template(prompt, context) when is_map(context) do
    {:ok, result} = PromptExpander.expand(prompt, context, on_missing: :keep)
    result
  end

  # Extract PTC-Lisp code from LLM response.
  # Delegates to ResponseHandler.parse/1 which uses a line-by-line fence parser
  # that correctly handles backtick fences inside string literals.
  defp extract_code(text) do
    case ResponseHandler.parse(text) do
      {:ok, _code} = ok -> ok
      {:error, _} -> :none
    end
  end

  # Helper to create error Step
  defp return_error(reason, message, memory, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    step = PtcRunner.Step.error(reason, message, memory)

    updated_step = %{step | usage: %{duration_ms: duration_ms, memory_bytes: 0}}

    {:error, updated_step}
  end

  # Update step with usage metrics (for single-shot mode)
  defp update_step_usage(step, duration_ms, tokens) do
    usage = step.usage || %{memory_bytes: 0}
    base_usage = Map.put(usage, :duration_ms, duration_ms)

    # Add token counts if available
    usage_with_tokens =
      case tokens do
        %{input: input, output: output} ->
          Map.merge(base_usage, %{
            input_tokens: input,
            output_tokens: output,
            total_tokens: LLMResolver.total_tokens(tokens),
            llm_requests: 1
          })

        _ ->
          base_usage
      end

    %{step | usage: usage_with_tokens}
  end

  # Build collected messages for single-shot mode (or nil if not collecting)
  defp build_single_shot_messages(false, _system_prompt, _user_prompt, _assistant_content),
    do: nil

  defp build_single_shot_messages(true, system_prompt, user_prompt, assistant_content) do
    [
      %{role: :system, content: system_prompt},
      %{role: :user, content: user_prompt},
      %{role: :assistant, content: assistant_content}
    ]
  end

  # Helper to build trace for single-shot execution
  defp build_single_shot_trace(
         _agent,
         system_prompt,
         llm_input,
         response,
         code,
         lisp_result,
         opts
       ) do
    trace_mode = Keyword.get(opts, :trace, true)
    debug = Keyword.get(opts, :debug, false)

    state = %{
      turn: 1,
      debug: debug,
      trace_mode: trace_mode,
      context: lisp_result |> elem(1) |> Map.get(:context, %{}),
      memory: %{},
      # Metrics.build_turn looks for :current_messages, not :messages
      current_messages: llm_input.messages,
      current_system_prompt: system_prompt
    }

    {status, lisp_step} = lisp_result

    turn =
      Metrics.build_turn(
        state,
        response,
        code,
        lisp_step.return || lisp_step.fail,
        success?: status == :ok,
        prints: lisp_step.prints,
        tool_calls: lisp_step.tool_calls,
        memory: lisp_step.memory
      )

    Metrics.apply_trace_filter([turn], trace_mode, status == :error)
  end

  # Auto-inject trace_context if TraceLog is active and trace_context not already provided.
  # This enables automatic trace propagation to nested agents when running inside
  # TraceLog.with_trace/2 without requiring explicit trace_context option.
  defp maybe_inject_trace_context(opts) do
    if Keyword.has_key?(opts, :trace_context) do
      # trace_context already provided (e.g., from ToolNormalizer for child agents)
      opts
    else
      # Check if TraceLog is active in this process
      case PtcRunner.TraceLog.current_collector() do
        nil ->
          opts

        collector ->
          # Get trace_id and path from the collector, build initial trace_context
          trace_id = Collector.trace_id(collector)
          trace_path = Collector.path(collector)
          parent_span_id = Telemetry.current_span_id()

          trace_context = %{
            trace_id: trace_id,
            parent_span_id: parent_span_id,
            depth: 0,
            trace_dir: Path.dirname(trace_path)
          }

          Keyword.put(opts, :trace_context, trace_context)
      end
    end
  end
end
