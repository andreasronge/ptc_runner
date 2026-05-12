defmodule PtcRunnerMcp.Agentic do
  @moduledoc false

  alias PtcRunner.Step
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop.StepAssembler

  alias PtcRunnerMcp.{
    AgenticConfig,
    Envelope,
    Limits,
    PayloadMetrics
  }

  alias PtcRunnerMcp.Agentic.{
    CapabilitySummary,
    Ledger,
    McpCall,
    Planner,
    Projection,
    Prompt,
    Renderer
  }

  @tool_name "ptc_task"

  @doc false
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec tool_entry() :: map()
  def tool_entry do
    %{
      "name" => @tool_name,
      "description" => tool_description(),
      "inputSchema" => input_schema(),
      "outputSchema" => output_schema(),
      "annotations" => task_annotations()
    }
  end

  @spec validate(map()) :: {:ok, map()} | {:error, map()}
  def validate(args) when is_map(args) do
    with {:ok, task} <- validate_task(args),
         {:ok, context} <- validate_context(args),
         {:ok, constraints, warnings} <- validate_constraints(args) do
      {:ok, %{task: task, context: context, constraints: constraints, warnings: warnings}}
    else
      {:error, message} -> {:error, agentic_error(:args_error, message)}
    end
  end

  @spec run_validated(map(), keyword()) :: map()
  def run_validated(validated, opts \\ []) when is_map(validated) do
    cfg = AgenticConfig.get()
    request_id = Keyword.get(opts, :request_id)
    started = monotonic_ms()
    deadline = started + cfg.task_timeout_ms

    :telemetry.span([:ptc_runner_mcp, :agentic_task], start_meta(request_id, cfg), fn ->
      envelope = do_run_validated(validated, cfg, request_id, deadline)
      {envelope, stop_meta(request_id, envelope)}
    end)
  end

  defp do_run_validated(validated, cfg, request_id, deadline) do
    with :ok <- require_budget(deadline),
         {:ok, ledger} <- Ledger.start_link(),
         {:ok, turn_tracker} <- Agent.start_link(fn -> 1 end),
         {:ok, planner_log} <- Agent.start_link(fn -> [] end),
         assembled <- assemble_prompt(validated, cfg),
         agent <- build_subagent(assembled, ledger, turn_tracker, cfg),
         llm <- planner_llm(cfg, deadline, request_id, planner_log, turn_tracker),
         result <- run_subagent(agent, llm, validated, request_id, ledger),
         :ok <- require_budget(deadline) do
      project_subagent_result(result, ledger, planner_log, validated, cfg)
    else
      {:error, reason, message, partial} ->
        Envelope.error_envelope(error_payload(reason, message, partial, cfg))
    end
  end

  defp assemble_prompt(validated, cfg) do
    Prompt.assemble(validated,
      max_turns: cfg.max_turns,
      allow_writes: cfg.allow_writes,
      prefix: cfg.system_prompt.prefix,
      suffix: cfg.system_prompt.suffix
    )
  end

  defp build_subagent(assembled, ledger, turn_tracker, cfg) do
    SubAgent.new(
      prompt: assembled.user_message,
      system_prompt: assembled.system_prompt,
      tools:
        McpCall.build(ledger,
          max_calls: Limits.max_upstream_calls_per_program(),
          turn: fn -> Agent.get(turn_tracker, & &1) end
        ),
      max_turns: cfg.max_turns,
      retry_turns: cfg.retry_turns,
      completion_mode: :explicit,
      output: :ptc_lisp,
      timeout: Limits.program_timeout_ms(),
      max_heap: Limits.program_memory_limit_bytes()
    )
  end

  defp planner_llm(cfg, deadline, request_id, planner_log, turn_tracker) do
    fn input ->
      update_turn_tracker(turn_tracker, Map.get(input, :turn))
      prompt = render_subagent_input(input)

      case call_planner(cfg, prompt, deadline, request_id) do
        {:ok, raw, meta} ->
          Agent.update(planner_log, &[meta | &1])
          {:ok, %{content: raw, tokens: Map.get(meta, "tokens")}}

        {:error, reason, message, meta} ->
          Agent.update(planner_log, &[Map.merge(meta, %{"error" => to_string(reason)}) | &1])
          {:error, {reason, message}}
      end
    end
  end

  defp update_turn_tracker(turn_tracker, turn) when is_integer(turn) and turn > 0 do
    Agent.update(turn_tracker, fn _ -> turn end)
  end

  defp update_turn_tracker(_turn_tracker, _turn), do: :ok

  defp render_subagent_input(input) do
    messages =
      input
      |> Map.get(:messages, [])
      |> Enum.map_join("\n\n", fn message ->
        "#{Map.get(message, :role)}:\n#{Map.get(message, :content)}"
      end)

    [Map.get(input, :system), messages]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp run_subagent(agent, llm, validated, request_id, ledger) do
    SubAgent.run(agent,
      llm: llm,
      context: validated.context,
      continuation_guard: continuation_guard(ledger),
      trace_context: %{request_id: request_id}
    )
  end

  defp continuation_guard(ledger) do
    fn _turn, _state, next_state ->
      if Ledger.side_effecting_attempted?(ledger) do
        {:stop, build_partial_side_effects_step(next_state)}
      else
        :continue
      end
    end
  end

  defp build_partial_side_effects_step(next_state) do
    duration_ms = monotonic_ms() - next_state.start_time

    step =
      Step.error(
        Projection.partial_side_effects(),
        "Continuation blocked after write or unknown upstream side effects",
        next_state.memory
      )

    final_step =
      StepAssembler.finalize(step, next_state,
        duration_ms: duration_ms,
        turn_offset: -1,
        is_error: true,
        journal: next_state.journal,
        child_steps: next_state.child_steps
      )

    {:error, final_step}
  end

  defp call_planner(cfg, prompt, deadline, request_id) do
    timeout = min(cfg.planner_timeout_ms, max(deadline - monotonic_ms(), 0))

    if timeout <= 0 do
      budget_error()
    else
      sanitized_prompt = Planner.sanitize_prompt(prompt)
      planner = Application.get_env(:ptc_runner_mcp, :agentic_planner, Planner)
      collectors = PtcRunner.TraceLog.active_collectors()

      task =
        Task.async(fn ->
          PtcRunner.TraceLog.join(collectors)

          try do
            :telemetry.span(
              [:ptc_runner_mcp, :agentic_planner],
              %{request_id: to_string(request_id || ""), model: cfg.model},
              fn ->
                result =
                  planner.call(cfg.model, sanitized_prompt,
                    timeout_ms: timeout,
                    max_output_tokens: cfg.max_output_tokens
                  )

                {result, planner_stop_meta(result)}
              end
            )
          catch
            kind, reason ->
              {:error, :planner, "planner crashed: #{Exception.format_banner(kind, reason)}", %{}}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, raw, meta}} ->
          {:ok, raw, meta}

        {:ok, {:error, :config, message, meta}} ->
          {:error, :agentic_config_error, message, meta}

        {:ok, {:error, :planner, message, meta}} ->
          {:error, :planner_error, message, meta}

        {:exit, reason} ->
          {:error, :planner_error, "planner crashed: #{inspect(reason)}", %{}}

        nil ->
          {:error, :planner_timeout, "planner exceeded #{timeout}ms timeout", %{}}

        other ->
          {:error, :planner_error, "planner returned unexpected result: #{inspect(other)}", %{}}
      end
    end
  end

  defp planner_stop_meta({:ok, _raw, meta}), do: %{status: :ok, model: meta["model"]}
  defp planner_stop_meta({:error, kind, _message, _meta}), do: %{status: :error, reason: kind}

  defp project_subagent_result({:ok, step}, ledger, planner_log, validated, cfg) do
    calls = ledger_payload(ledger)
    planner = planner_payload(planner_log)

    {rendered, render_warnings} =
      Renderer.render(%{"result" => step.return}, validated.constraints, cfg.max_result_bytes)

    execution =
      rendered["execution"]
      |> Map.put("duration_ms", get_in(step.usage, [:duration_ms]) || 0)
      |> Map.put("turn_count", length(step.turns || []))

    answer = rendered["answer"]
    structured_result = rendered["structured_result"]

    payload =
      %{
        "status" => "ok",
        "answer" => answer,
        "structured_result" => structured_result,
        "warnings" => validated.warnings ++ render_warnings,
        "planner" => planner,
        "execution" => execution,
        "upstream_calls" => calls,
        "trace_id" => step.trace_id
      }
      |> maybe_put_program(final_program(step), cfg)
      |> put_ptc_metrics(final_result_bytes_for(answer, structured_result), calls, planner_log)

    Envelope.success(payload)
  end

  defp project_subagent_result({:error, step}, ledger, planner_log, _validated, cfg) do
    planner = planner_payload(planner_log)
    side_effecting_attempted? = Ledger.side_effecting_attempted?(ledger)
    calls = ledger_payload(ledger)

    partial = %{
      "planner" => planner,
      "execution" => %{
        "duration_ms" => get_in(step.usage, [:duration_ms]) || 0,
        "turn_count" => length(step.turns || [])
      },
      "upstream_calls" => calls,
      "program" => final_program(step),
      "trace_id" => step.trace_id,
      # On error `final_result_bytes` is 0 and the ratio is `null`
      # (`Plans/ptc-runner-mcp-payload-reduction.md` §4.3 / §7 #9); the
      # planner ran regardless, so the block is still attached.
      "ptc_metrics" => task_ptc_metrics(0, calls, planner_log)
    }

    Envelope.error_envelope(
      error_payload(
        map_step_reason(step, planner, side_effecting_attempted?),
        step.fail.message,
        partial,
        cfg
      )
    )
  end

  defp ledger_payload(ledger) do
    ledger
    |> Ledger.entries()
    |> Projection.ledger_entries()
  end

  # ----------------------------------------------------------------
  # `ptc_metrics` decoration (Plans/ptc-runner-mcp-payload-reduction.md §4.3)
  # ----------------------------------------------------------------

  # `ptc_task`'s `final_result_bytes` is the JSON byte size of the
  # user-facing answer subset `{answer, structured_result}` (§4.3 /
  # §7 #9). Encode failures (vanishingly rare for already-rendered
  # JSON) collapse to 0 — the ratio then degrades to `null`, which is
  # the correct honest answer.
  defp final_result_bytes_for(answer, structured_result) do
    case Jason.encode(%{"answer" => answer, "structured_result" => structured_result}) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> 0
    end
  end

  defp put_ptc_metrics(payload, final_result_bytes, calls, planner_log) do
    Map.put(payload, "ptc_metrics", task_ptc_metrics(final_result_bytes, calls, planner_log))
  end

  defp task_ptc_metrics(final_result_bytes, calls, planner_log) do
    # `prints_bytes: 0` — `ptc_task` has no `prints` array; the 0 is
    # shape parity with the `ptc_lisp_execute` block (§4.3).
    PayloadMetrics.build(final_result_bytes, 0, calls,
      server_side_llm: server_side_llm_input(planner_log)
    )
  end

  # Aggregates per-call planner meta into the `server_side_llm` input
  # the §4.3 block needs. `provider_reported` is `true` only when
  # *every* planner call (that returned content) carried a real
  # provider token count; otherwise the `*_tokens` fields collapse to
  # `nil` and clients fall back to the byte estimates. The `*_bytes`
  # figures are always summed.
  defp server_side_llm_input(planner_log) do
    metas = Agent.get(planner_log, &Enum.reverse/1)
    planner_calls = length(metas)

    prompt_bytes = sum_meta(metas, "prompt_bytes")
    completion_bytes = sum_meta(metas, ["completion_bytes", "output_bytes"])

    {provider_reported?, prompt_tokens, completion_tokens, total_tokens} =
      aggregate_provider_tokens(metas)

    %{
      provider_reported: provider_reported?,
      planner_calls: planner_calls,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: total_tokens,
      prompt_bytes: prompt_bytes,
      completion_bytes: completion_bytes
    }
  end

  # Sum a numeric field across planner-call metas, accepting a list of
  # candidate keys (first hit per meta wins). Missing / non-numeric
  # values contribute 0.
  defp sum_meta(metas, key) when is_binary(key), do: sum_meta(metas, [key])

  defp sum_meta(metas, keys) when is_list(keys) do
    Enum.reduce(metas, 0, fn meta, acc ->
      acc + first_non_neg_int(meta, keys)
    end)
  end

  defp first_non_neg_int(meta, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(meta, key) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end)
  end

  # `provider_reported` is true iff there is ≥ 1 planner-call meta AND
  # every meta's `"tokens"` carries a positive `:input`/`:output` (the
  # `PtcRunner.LLM` adapter shape — `%{input: .., output: ..}`). When
  # so, sum input/output across calls; else `nil` everywhere.
  defp aggregate_provider_tokens([]), do: {false, nil, nil, nil}

  defp aggregate_provider_tokens(metas) do
    tokens_list = Enum.map(metas, fn meta -> Map.get(meta, "tokens") end)

    if Enum.all?(tokens_list, &provider_tokens?/1) do
      prompt = Enum.reduce(tokens_list, 0, &(token_field(&1, :input) + &2))
      completion = Enum.reduce(tokens_list, 0, &(token_field(&1, :output) + &2))
      {true, prompt, completion, prompt + completion}
    else
      {false, nil, nil, nil}
    end
  end

  # A planner call's `"tokens"` carries real provider usage when it is
  # a map with a positive `:input` or `:output` count. ReqLLM's
  # adapter populates `%{input: n, output: m}` (0 when the provider
  # didn't surface usage); a stub that returns `%{}` or omits it is
  # "not reported".
  defp provider_tokens?(%{} = tokens) do
    token_field(tokens, :input) > 0 or token_field(tokens, :output) > 0
  end

  defp provider_tokens?(_), do: false

  defp token_field(tokens, key) when is_map(tokens) do
    case Map.get(tokens, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp token_field(_tokens, _key), do: 0

  defp planner_payload(planner_log) do
    calls = Agent.get(planner_log, &Enum.reverse/1)
    last = List.last(calls) || %{}

    last
    |> Map.put("calls", length(calls))
  end

  defp map_step_reason(%{fail: %{reason: :failed}}, _planner, _side_effecting_attempted?),
    do: :agent_failed

  defp map_step_reason(
         %{fail: %{reason: :partial_side_effects}},
         _planner,
         _side_effecting_attempted?
       ),
       do: Projection.partial_side_effects()

  defp map_step_reason(%{fail: %{reason: _reason}}, _planner, true),
    do: Projection.partial_side_effects()

  defp map_step_reason(%{fail: %{reason: :timeout}}, _planner, false), do: :budget_exceeded

  defp map_step_reason(
         %{fail: %{reason: :llm_error}},
         %{"error" => "agentic_config_error"},
         false
       ),
       do: :agentic_config_error

  defp map_step_reason(%{fail: %{reason: :llm_error}}, %{"error" => "planner_timeout"}, false),
    do: :planner_timeout

  defp map_step_reason(%{fail: %{reason: :llm_error}}, %{"error" => "planner_error"}, false),
    do: :planner_error

  defp map_step_reason(%{fail: %{reason: reason}}, _planner, false) when is_atom(reason),
    do: :"ptc_#{reason}"

  defp final_program(%{turns: turns}) when is_list(turns) do
    turns
    |> Enum.reverse()
    |> Enum.find_value(& &1.program)
  end

  defp final_program(_step), do: nil

  defp maybe_put_program(payload, program, %{include_program: true}),
    do: Map.put(payload, "program", program)

  defp maybe_put_program(payload, _program, _cfg), do: payload

  defp error_payload(reason, message, partial, cfg) do
    %{
      "status" => "error",
      "reason" => to_string(reason),
      "message" => message,
      "warnings" => [],
      "planner" => Map.get(partial, "planner", %{}),
      "execution" => Map.get(partial, "execution", %{}),
      "upstream_calls" => Map.get(partial, "upstream_calls", [])
    }
    |> maybe_put_program(Map.get(partial, "program"), cfg)
    |> maybe_put_trace_id(Map.get(partial, "trace_id"))
    |> maybe_put_ptc_metrics(Map.get(partial, "ptc_metrics"))
  end

  # `ptc_metrics` is attached on error envelopes only when the planner
  # ran (the `project_subagent_result/5` error path supplies it).
  # Early-abort errors (args validation, no budget) never ran the
  # planner, so they don't supply it and the key is absent (§7 #8).
  defp maybe_put_ptc_metrics(payload, metrics) when is_map(metrics),
    do: Map.put(payload, "ptc_metrics", metrics)

  defp maybe_put_ptc_metrics(payload, _metrics), do: payload

  defp maybe_put_trace_id(payload, trace_id) when is_binary(trace_id),
    do: Map.put(payload, "trace_id", trace_id)

  defp maybe_put_trace_id(payload, _trace_id), do: payload

  defp validate_task(args) do
    case Map.get(args, "task") do
      task when is_binary(task) ->
        task = String.trim(task)

        if task == "",
          do: {:error, "argument `task` must be a non-empty string"},
          else: {:ok, task}

      value ->
        {:error, "argument `task` must be a string, got #{type_label(value)}"}
    end
  end

  defp validate_context(args) do
    case Map.fetch(args, "context") do
      :error ->
        {:ok, %{}}

      {:ok, nil} ->
        {:ok, %{}}

      {:ok, value} when not is_map(value) or is_struct(value) ->
        {:error, "argument `context` must be a JSON object, got #{type_label(value)}"}

      {:ok, value} ->
        check_context(value)
    end
  end

  defp check_context(map) do
    with {:ok, encoded} <- Jason.encode(map),
         :ok <- check_context_size(encoded),
         :ok <- check_context_keys(map) do
      {:ok, map}
    else
      {:error, %Jason.EncodeError{} = reason} ->
        {:error, "argument `context` is not JSON-encodable: #{inspect(reason)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp check_context_size(encoded) do
    size = byte_size(encoded)
    cap = Limits.max_context_bytes()

    if size > cap,
      do: {:error, "argument `context` exceeds max_context_bytes (#{size} > #{cap})"},
      else: :ok
  end

  defp check_context_keys(map) do
    Enum.reduce_while(map, :ok, fn {k, _v}, _acc ->
      cond do
        not is_binary(k) ->
          {:halt, {:error, "argument `context` keys must be strings (got: #{inspect(k)})"}}

        k == "" ->
          {:halt, {:error, "argument `context` keys must be non-empty"}}

        String.contains?(k, "/") ->
          {:halt, {:error, "argument `context` keys may not contain `/`: #{inspect(k)}"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_constraints(args) do
    case Map.fetch(args, "constraints") do
      :error ->
        {:ok, %{}, []}

      {:ok, constraints} ->
        with :ok <- check_constraints_size(constraints) do
          Renderer.normalize_constraints(constraints)
        end
    end
  end

  defp check_constraints_size(constraints) do
    case Jason.encode(constraints) do
      {:ok, encoded} ->
        size = byte_size(encoded)
        cap = Limits.max_context_bytes()

        if size > cap,
          do: {:error, "argument `constraints` exceeds max_context_bytes (#{size} > #{cap})"},
          else: :ok

      {:error, reason} ->
        {:error, "argument `constraints` is not JSON-encodable: #{inspect(reason)}"}
    end
  end

  defp input_schema do
    %{
      "type" => "object",
      "required" => ["task"],
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "Plain-English task for the agentic aggregator."
        },
        "context" => %{
          "type" => "object",
          "description" => "Optional JSON values available under data/."
        },
        "constraints" => %{
          "type" => "object",
          "description" => "Optional soft constraints such as max_items or preferred_fields."
        }
      }
    }
  end

  # `Plans/ptc-runner-mcp-payload-reduction.md` §5: the `ptc_task`
  # `outputSchema` gains an optional `ptc_metrics` object and the
  # `upstream_calls[]` items document the new `result_bytes` /
  # `oversize` fields. Both are additive — no `additionalProperties`
  # constraint — so older clients are unaffected.
  @upstream_calls_item_schema %{
    "type" => "object",
    "properties" => %{
      "server" => %{"type" => "string"},
      "tool" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "duration_ms" => %{"type" => "integer", "minimum" => 0},
      "effect" => %{"type" => "string"},
      "turn" => %{"type" => "integer"},
      "args_hash" => %{"type" => "string"},
      "result_bytes" => %{"type" => ["integer", "null"], "minimum" => 0},
      "oversize" => %{"type" => "boolean"},
      "reason" => %{"type" => "string"},
      "error" => %{"type" => "string"}
    }
  }

  @ptc_metrics_property %{"type" => ["object", "null"]}

  defp output_schema do
    upstream_calls_schema = %{"type" => "array", "items" => @upstream_calls_item_schema}

    %{
      "type" => "object",
      "oneOf" => [
        %{
          "type" => "object",
          "required" => [
            "status",
            "answer",
            "structured_result",
            "warnings",
            "planner",
            "execution",
            "upstream_calls"
          ],
          "properties" => %{
            "upstream_calls" => upstream_calls_schema,
            "ptc_metrics" => @ptc_metrics_property
          }
        },
        %{
          "type" => "object",
          "required" => [
            "status",
            "reason",
            "message",
            "warnings",
            "planner",
            "execution",
            "upstream_calls"
          ],
          "properties" => %{
            "upstream_calls" => upstream_calls_schema,
            "ptc_metrics" => @ptc_metrics_property
          }
        }
      ]
    }
  end

  defp tool_description do
    """
    Use this tool for bounded plain-English tasks over the configured upstream MCP servers. Describe the result you want; the aggregator will plan and execute internal upstream calls.

    Available upstream capabilities:
    #{capability_summary_for_tool_description()}

    Do not try to call upstream MCP servers through this tool. Ask for the outcome in plain English.
    """
  end

  defp capability_summary_for_tool_description do
    cfg = AgenticConfig.get()

    cfg.capability_summary ||
      CapabilitySummary.from_frozen(max_bytes: cfg.capability_summary_max_bytes)
  end

  defp task_annotations do
    if PtcRunnerMcp.AggregatorConfig.read_only?() do
      %{
        "readOnlyHint" => true,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => true
      }
    else
      %{
        "readOnlyHint" => false,
        "destructiveHint" => true,
        "idempotentHint" => false,
        "openWorldHint" => true
      }
    end
  end

  defp require_budget(deadline) do
    if monotonic_ms() <= deadline, do: :ok, else: budget_error()
  end

  defp budget_error, do: {:error, :budget_exceeded, "agentic task budget exceeded", %{}}

  defp agentic_error(reason, message) do
    Envelope.error_envelope(%{
      "status" => "error",
      "reason" => to_string(reason),
      "message" => message,
      "warnings" => [],
      "planner" => %{},
      "execution" => %{},
      "upstream_calls" => []
    })
  end

  defp start_meta(request_id, cfg),
    do: %{request_id: to_string(request_id || ""), model: cfg.model}

  defp stop_meta(request_id, envelope) do
    sc = Map.get(envelope, "structuredContent", %{})

    %{
      request_id: to_string(request_id || ""),
      status: Map.get(sc, "status"),
      reason: Map.get(sc, "reason")
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp type_label(v) when is_struct(v), do: "struct"
  defp type_label(v) when is_map(v), do: "object"
  defp type_label(v) when is_list(v), do: "array"
  defp type_label(v) when is_integer(v), do: "integer"
  defp type_label(v) when is_float(v), do: "number"
  defp type_label(v) when is_boolean(v), do: "boolean"
  defp type_label(nil), do: "null"
  defp type_label(_), do: "unknown"
end
