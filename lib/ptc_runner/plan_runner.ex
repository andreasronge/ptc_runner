defmodule PtcRunner.PlanRunner do
  @moduledoc """
  Execute parsed plans with SubAgents.

  Takes a normalized `PtcRunner.Plan` and executes each task in dependency order,
  using SubAgents for each task. Results flow between tasks via template expansion.

  ## Parallel Execution

  Tasks are grouped into phases by dependency level. Within each phase,
  all tasks execute in parallel. Phases execute sequentially.

  ## Error Handling

  Each task can specify `on_failure`:
  - `:stop` (default) - Stop execution on failure
  - `:skip` - Log and continue with other tasks
  - `:retry` - Retry up to `max_retries` times before failing
  - `:replan` - On deliberate agent failure via `(fail "reason")`, trigger replanning

  ## Example

      {:ok, plan} = PtcRunner.Plan.parse(llm_generated_plan)
      {:ok, results} = PtcRunner.PlanRunner.execute(plan,
        llm: my_llm,
        base_tools: %{
          "search" => &MyApp.search/1,
          "fetch" => &MyApp.fetch/1
        }
      )

  ## Result Flow

  Task results are available to subsequent tasks via the `results` map:
  - In task input: `"Analyze {{results.research_task.data}}"`
  - Previous task outputs are automatically injected

  ## Options

  - `llm` - Required. LLM callback for all agents
  - `llm_registry` - Optional map of atom -> llm callback
  - `base_tools` - Tool implementations (map of name -> function)
  - `available_tools` - Tool descriptions (map of name -> description string). Used to
    enrich raw function tools with signatures so the LLM knows how to call them.
    Format: `"Description. Input: {param: type}. Output: {field: type}"`
  - `timeout` - Per-task timeout in ms (default: 30_000)
  - `max_turns` - Max turns per agent (default: 5)
  - `max_concurrency` - Max parallel tasks per phase (default: 10)
  - `reviews` - Map of task_id => decision for human review tasks (default: %{})
  - `initial_results` - Pre-populated results map (default: %{}). Tasks with IDs already
    in this map are skipped. Used for replanning - pass completed results from previous
    execution to avoid re-running successful tasks.
  - `on_event` - Optional callback for task lifecycle events. Receives tuples like
    `{:task_started, %{task_id: id, attempt: n}}`, `{:task_succeeded, %{...}}`, etc.
  - `builtin_tools` - List of builtin tool families to enable for PTC-Lisp agents
    (default: `[]`). Available: `:grep` (adds grep and grep-n tools).
    Only injected for agents running in `:ptc_lisp` output mode.
  - `quality_gate` - Enable pre-flight data sufficiency check before tasks with dependencies
    (default: `false`). When enabled, a lightweight SubAgent validates upstream results before
    each dependent task. On failure, triggers `{:replan_required, context}`.
  - `quality_gate_llm` - Optional separate LLM callback for quality gate checks.
    Falls back to the main `llm` if not provided.

  ## Human Review Tasks

  Plans can include `type: "human_review"` tasks that pause execution until
  a human provides a decision. When encountered:

  1. First invocation returns `{:waiting, pending_reviews, partial_results}`
  2. Application presents review to human, collects decision
  3. Re-invoke with `reviews: %{"task_id" => decision}` to continue

  Example:

      # First call - hits human review, pauses
      {:waiting, pending, results} = PlanRunner.execute(plan, llm: llm)

      # Collect human decision (app-specific)
      decision = get_human_decision(hd(pending))

      # Continue with the decision
      {:ok, final_results} = PlanRunner.execute(plan,
        llm: llm,
        reviews: Map.put(results, hd(pending).task_id, decision)
      )
  """

  alias PtcRunner.Lisp
  alias PtcRunner.Plan
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.TraceLog

  require Logger

  @type result :: %{
          task_id: String.t(),
          status: :ok | :error,
          value: term(),
          duration_ms: non_neg_integer()
        }

  @type pending_review :: %{
          task_id: String.t(),
          prompt: String.t(),
          context: map()
        }

  @type replan_context :: %{
          task_id: String.t(),
          task_input: term(),
          task_output: term(),
          diagnosis: String.t(),
          completed_results: %{String.t() => term()},
          agent_spec: Plan.agent_spec() | nil
        }

  @type execute_result ::
          {:ok, %{String.t() => term()}}
          | {:error, String.t(), %{String.t() => term()}, term()}
          | {:waiting, [pending_review()], %{String.t() => term()}}
          | {:replan_required, replan_context()}

  @doc """
  Execute a parsed plan.

  Runs tasks in parallel phases (respecting dependencies).
  Each task's results are available to subsequent tasks via template expansion.

  ## Parameters

  - `plan` - Parsed `%Plan{}` struct
  - `opts` - Execution options

  ## Returns

  - `{:ok, results}` - Map of task_id to task result value
  - `{:error, failed_task_id, partial_results, reason}` - First critical failure with partial results
  - `{:waiting, pending_reviews, partial_results}` - Paused at human review
  - `{:replan_required, context}` - Verification failed with `:replan` strategy

  """
  @spec execute(Plan.t(), keyword()) :: execute_result()
  def execute(%Plan{} = plan, opts) do
    llm = Keyword.fetch!(opts, :llm)
    base_tools = Keyword.get(opts, :base_tools, %{})
    available_tools = Keyword.get(opts, :available_tools, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_turns = Keyword.get(opts, :max_turns, 5)
    llm_registry = Keyword.get(opts, :llm_registry, %{})
    max_concurrency = Keyword.get(opts, :max_concurrency, 10)
    reviews = Keyword.get(opts, :reviews, %{})
    initial_results = Keyword.get(opts, :initial_results, %{})
    on_event = Keyword.get(opts, :on_event)

    # Enrich base_tools with signatures from available_tools descriptions
    enriched_tools = enrich_tools_with_descriptions(base_tools, available_tools)

    # Group tasks into parallel phases by dependency level
    phases = Plan.group_by_level(plan.tasks)

    exec_opts = %{
      llm: llm,
      llm_registry: llm_registry,
      base_tools: enriched_tools,
      builtin_tools: Keyword.get(opts, :builtin_tools, []),
      timeout: timeout,
      max_turns: max_turns,
      max_concurrency: max_concurrency,
      reviews: reviews,
      on_event: on_event,
      quality_gate: Keyword.get(opts, :quality_gate, false),
      quality_gate_llm: Keyword.get(opts, :quality_gate_llm),
      mission: Keyword.get(opts, :mission)
    }

    # Execute phases sequentially, tasks within each phase in parallel
    # Start with initial_results (for replanning skip-if-present)
    execute_phases(phases, plan.agents, initial_results, exec_opts)
  end

  defp execute_phases([], _agents, results, _opts) do
    {:ok, results}
  end

  defp execute_phases([phase | rest], agents, results, opts) do
    case execute_phase(phase, agents, results, opts) do
      {:ok, phase_results, skipped} ->
        # Merge phase results and continue
        merged = Map.merge(results, phase_results)

        if skipped != [] do
          Logger.debug("Skipped tasks: #{inspect(skipped)}")
        end

        execute_phases(rest, agents, merged, opts)

      {:waiting, pending_reviews, phase_results} ->
        # Human review required - pause execution
        merged = Map.merge(results, phase_results)
        {:waiting, pending_reviews, merged}

      {:replan_required, context} ->
        # Verification failed with replan strategy - return context with completed results
        {:replan_required, Map.put(context, :completed_results, results)}

      {:error, task_id, partial_results, reason} ->
        # Critical failure - stop execution
        merged = Map.merge(results, partial_results)
        {:error, task_id, merged, reason}
    end
  end

  # Execute all tasks in a phase in parallel
  # Skip tasks whose IDs are already in results (for replanning)
  defp execute_phase(tasks, agents, results, opts) do
    # Partition tasks: already completed vs need to run
    {completed, to_run} = Enum.split_with(tasks, fn task -> Map.has_key?(results, task.id) end)

    # Log and emit events for skipped tasks
    if completed != [] do
      skipped_ids = Enum.map(completed, & &1.id)
      Logger.debug("Skipping already-completed tasks: #{inspect(skipped_ids)}")

      for task <- completed do
        emit_event(opts, {:task_skipped, %{task_id: task.id, reason: :already_completed}})
      end
    end

    # Build results for skipped tasks (use existing values)
    skipped_results = Enum.map(completed, fn task -> {task, {:ok, Map.get(results, task.id)}} end)

    # Emit task.start telemetry for all tasks about to run
    for task <- to_run do
      # Add dependency result sizes for synthesis gates
      dep_meta =
        if task.type == :synthesis_gate do
          dep_summary =
            for key <- task.depends_on, Map.has_key?(results, key), into: %{} do
              {key, byte_size(inspect(results[key]))}
            end

          %{dependency_result_sizes: dep_summary}
        else
          %{}
        end

      :telemetry.execute(
        [:ptc_runner, :plan_executor, :task, :start],
        %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
        Map.merge(
          %{
            task_id: task.id,
            span_id: task.id,
            task: task_to_map(task),
            agent: task.agent,
            input: task.input,
            attempt: 1
          },
          dep_meta
        )
      )
    end

    # Capture trace context for propagation to worker processes
    trace_collectors = TraceLog.active_collectors()
    parent_span_id = Telemetry.current_span_id()

    # Run remaining tasks in parallel
    # Returns {task, result, duration_ms} tuples for telemetry
    executed_results =
      to_run
      |> Task.async_stream(
        fn task ->
          execute_task_with_timing(task, agents, results, opts, trace_collectors, parent_span_id)
        end,
        max_concurrency: opts.max_concurrency,
        timeout: opts.timeout * opts.max_turns + 5000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {:timeout, nil, {:error, reason}}
      end)

    # Emit telemetry for each executed task from main process
    for {task, duration_ms, result} <- executed_results do
      {status, result_value} =
        case result do
          {:ok, value} -> {:ok, value}
          {:waiting, pending} -> {:waiting, pending}
          {:skipped, diagnosis} -> {:skipped, diagnosis}
          {:error, reason} -> {:error, reason}
          {:replan_required, context} -> {:replan_required, context}
        end

      extra_meta =
        case result do
          {:error, {:synthesis_error, _id, reason}} -> %{validation_error: reason}
          {:error, {:verification_failed, _id, diagnosis}} -> %{verification_error: diagnosis}
          _ -> %{}
        end

      :telemetry.execute(
        [:ptc_runner, :plan_executor, :task, :stop],
        %{duration: duration_ms * 1_000_000},
        Map.merge(
          %{
            task_id: task.id,
            span_id: task.id,
            status: status,
            result: result_value,
            duration_ms: duration_ms
          },
          extra_meta
        )
      )
    end

    # Convert back to {task, result} format
    executed_as_pairs =
      Enum.map(executed_results, fn {task, _duration, result} -> {task, result} end)

    # Combine skipped and executed results
    all_results = skipped_results ++ executed_as_pairs

    # Process results, respecting on_failure settings
    process_phase_results(all_results)
  end

  defp process_phase_results(task_results) do
    # First pass: collect any pending reviews or replan requests
    pending_reviews =
      task_results
      |> Enum.flat_map(fn
        {_task, {:waiting, pending}} -> pending
        _ -> []
      end)

    replan_requests =
      task_results
      |> Enum.flat_map(fn
        {_task, {:replan_required, context}} -> [context]
        _ -> []
      end)

    # If any tasks are waiting for review, pause the whole phase
    cond do
      pending_reviews != [] ->
        # Collect partial results from completed tasks in this phase
        partial_results =
          task_results
          |> Enum.flat_map(fn
            {task, {:ok, value}} -> [{task.id, value}]
            _ -> []
          end)
          |> Map.new()

        {:waiting, pending_reviews, partial_results}

      replan_requests != [] ->
        # Return first replan request (could enhance to batch them later)
        {:replan_required, hd(replan_requests)}

      true ->
        # Normal processing - no reviews or replans pending
        Enum.reduce_while(task_results, {:ok, %{}, []}, fn
          {task, {:ok, value}}, {:ok, results, skipped} ->
            {:cont, {:ok, Map.put(results, task.id, value), skipped}}

          {task, {:skipped, _diagnosis}}, {:ok, results, skipped} ->
            # Verification skipped - don't include in results
            {:cont, {:ok, results, [task.id | skipped]}}

          {task, {:error, reason}}, {:ok, results, skipped} ->
            handle_task_failure(task, reason, results, skipped)

          {:timeout, {:error, reason}}, {:ok, results, _skipped} ->
            # Task timed out at the async_stream level - we don't have the task info
            {:halt, {:error, "unknown", results, {:timeout, reason}}}
        end)
    end
  end

  defp handle_task_failure(task, reason, results, skipped) do
    case {task.on_failure, task.critical} do
      {:skip, _} ->
        Logger.warning("Task #{task.id} failed (skipped): #{inspect(reason)}")
        {:cont, {:ok, results, [task.id | skipped]}}

      {:stop, true} ->
        {:halt, {:error, task.id, results, reason}}

      {:stop, false} ->
        Logger.warning("Task #{task.id} failed (non-critical, skipped): #{inspect(reason)}")
        {:cont, {:ok, results, [task.id | skipped]}}

      {:retry, true} ->
        # Retries already exhausted in execute_task_with_retry
        {:halt, {:error, task.id, results, reason}}

      {:retry, false} ->
        Logger.warning("Task #{task.id} failed after retries (skipped): #{inspect(reason)}")
        {:cont, {:ok, results, [task.id | skipped]}}

      {:replan, _} ->
        # Deliberate replan already handled in do_execute_with_attempts;
        # if we reach here it means a non-deliberate failure on a :replan task
        {:halt, {:error, task.id, results, reason}}
    end
  end

  # Execute task and return {task, duration_ms, result} for telemetry from main process
  defp execute_task_with_timing(task, agents, results, opts, trace_collectors, parent_span_id) do
    # Re-attach trace context in this worker process for cross-process trace propagation
    # This ensures SubAgent events are captured AND linked to parent span hierarchy
    TraceLog.join(trace_collectors, parent_span_id)

    start_time = System.monotonic_time(:millisecond)
    emit_event(opts, {:task_started, %{task_id: task.id, attempt: 1}})

    result = execute_task_with_retry(task, agents, results, opts)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, _value} ->
        emit_event(opts, {:task_succeeded, %{task_id: task.id, duration_ms: duration_ms}})

      {:waiting, _pending} ->
        :ok

      {:skipped, _diagnosis} ->
        :ok

      {:error, reason} ->
        emit_event(opts, {:task_failed, %{task_id: task.id, reason: reason}})

      {:replan_required, _context} ->
        :ok
    end

    {task, duration_ms, result}
  end

  # Execute a task with retry support
  # Consider both on_failure and on_verification_failure when determining max attempts
  defp execute_task_with_retry(task, agents, results, opts) do
    max_attempts =
      cond do
        task.on_failure == :retry -> task.max_retries
        task.on_verification_failure == :retry -> task.max_retries
        true -> 1
      end

    execute_with_attempts(task, agents, results, opts, max_attempts, 1)
  end

  defp execute_with_attempts(task, agents, results, opts, max_attempts, attempt) do
    # Run quality gate check on first attempt only (upstream data hasn't changed on retries)
    gate_result =
      if attempt == 1,
        do: maybe_run_quality_gate(task, agents, results, opts),
        else: :proceed

    case gate_result do
      :proceed ->
        do_execute_with_attempts(task, agents, results, opts, max_attempts, attempt)

      {:replan_required, context} ->
        {:replan_required, context}
    end
  end

  defp do_execute_with_attempts(task, agents, results, opts, max_attempts, attempt) do
    case execute_task(task, agents, results, opts) do
      {:ok, value} ->
        # Run verification if predicate is specified
        case run_verification(task, value, results) do
          :passed ->
            {:ok, value}

          {:failed, diagnosis} ->
            handle_verification_failure(
              task,
              value,
              diagnosis,
              agents,
              results,
              opts,
              max_attempts,
              attempt
            )

          {:error, reason} ->
            {:error, {:verification_error, reason}}
        end

      {:waiting, pending} ->
        # Human review - pass through
        {:waiting, pending}

      {:error, reason} ->
        cond do
          # Deliberate failure — agent analyzed the data and says it's the wrong path.
          # Skip retries entirely: retrying won't change the document contents.
          task.on_failure == :replan and deliberate_fail?(reason) ->
            diagnosis = format_fail_diagnosis(reason)
            {:replan_required, %{task_id: task.id, task_output: nil, diagnosis: diagnosis}}

          # System error with retries remaining — backoff and retry
          attempt < max_attempts ->
            Logger.debug(
              "Task #{task.id} failed (attempt #{attempt}/#{max_attempts}): #{inspect(reason)}"
            )

            Process.sleep(100 * attempt)
            execute_with_attempts(task, agents, results, opts, max_attempts, attempt + 1)

          # No retries left
          true ->
            {:error, reason}
        end
    end
  end

  # --- Quality Gate ---

  # Skip gate if task has no dependencies (nothing to check)
  defp maybe_run_quality_gate(%{depends_on: []}, _agents, _results, _opts), do: :proceed

  defp maybe_run_quality_gate(task, agents, results, opts) do
    agent_spec = Map.get(agents, task.agent, %{prompt: "", tools: []})
    has_tools = agent_spec.tools != []

    should_run =
      case Map.get(task, :quality_gate) do
        true -> true
        false -> false
        # Tasks with tools are data producers — skip gate unless explicitly enabled
        nil when has_tools -> false
        nil -> opts.quality_gate != false
      end

    if should_run do
      emit_event(opts, {:quality_gate_started, %{task_id: task.id}})

      :telemetry.execute(
        [:ptc_runner, :plan_executor, :quality_gate, :start],
        %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
        %{task_id: task.id, span_id: task.id}
      )

      run_quality_gate(task, results, opts)
    else
      :proceed
    end
  end

  defp run_quality_gate(task, results, opts) do
    gate_start = System.monotonic_time()
    dep_results = Map.take(results, task.depends_on)
    expanded_input = expand_input(task.input, results)
    prompt = build_quality_gate_prompt(task, expanded_input, dep_results, opts.mission)

    gate_llm = opts.quality_gate_llm || opts.llm

    agent =
      SubAgent.new(
        prompt: prompt,
        output: :json,
        signature:
          "{sufficient :bool, missing [:string], evidence [{field :string, found :bool, source :string}]}",
        max_turns: 1,
        timeout: opts.timeout
      )

    case SubAgent.run(agent, llm: gate_llm) do
      {:ok, step} ->
        case step.return do
          %{"sufficient" => true} = gate_result ->
            evidence = Map.get(gate_result, "evidence", [])

            :telemetry.execute(
              [:ptc_runner, :plan_executor, :quality_gate, :stop],
              %{duration: System.monotonic_time() - gate_start},
              %{task_id: task.id, span_id: task.id, status: :passed, evidence: evidence}
            )

            emit_event(
              opts,
              {:quality_gate_passed, %{task_id: task.id, evidence: evidence}}
            )

            :proceed

          %{"sufficient" => false, "missing" => missing} = gate_result ->
            evidence = Map.get(gate_result, "evidence", [])

            diagnosis =
              "Quality gate: upstream data insufficient for task '#{task.id}'. " <>
                "Missing: #{Enum.join(missing, ", ")}"

            Logger.info(diagnosis)

            :telemetry.execute(
              [:ptc_runner, :plan_executor, :quality_gate, :stop],
              %{duration: System.monotonic_time() - gate_start},
              %{
                task_id: task.id,
                span_id: task.id,
                status: :failed,
                missing: missing,
                evidence: evidence
              }
            )

            emit_event(
              opts,
              {:quality_gate_failed, %{task_id: task.id, missing: missing, evidence: evidence}}
            )

            {:replan_required,
             %{
               task_id: task.id,
               task_output: nil,
               diagnosis: diagnosis
             }}

          _ ->
            Logger.warning(
              "Quality gate returned unexpected format for task '#{task.id}', proceeding"
            )

            :telemetry.execute(
              [:ptc_runner, :plan_executor, :quality_gate, :stop],
              %{duration: System.monotonic_time() - gate_start},
              %{task_id: task.id, span_id: task.id, status: :error, reason: :unexpected_format}
            )

            emit_event(
              opts,
              {:quality_gate_error, %{task_id: task.id, reason: :unexpected_format}}
            )

            :proceed
        end

      {:error, step} ->
        Logger.warning(
          "Quality gate SubAgent error for task '#{task.id}': #{inspect(step.fail)}, proceeding"
        )

        :telemetry.execute(
          [:ptc_runner, :plan_executor, :quality_gate, :stop],
          %{duration: System.monotonic_time() - gate_start},
          %{task_id: task.id, span_id: task.id, status: :error, reason: step.fail}
        )

        emit_event(opts, {:quality_gate_error, %{task_id: task.id, reason: step.fail}})
        :proceed
    end
  end

  defp build_quality_gate_prompt(task, expanded_input, dep_results, mission) do
    dep_summaries =
      Enum.map_join(dep_results, "\n\n", fn {task_id, value} ->
        formatted =
          case value do
            v when is_binary(v) -> truncate(v, 2000)
            v -> v |> Jason.encode!(pretty: true) |> truncate(2000)
          end

        "### #{task_id}\n#{formatted}"
      end)

    signature_info =
      case Map.get(task, :signature) do
        nil -> ""
        sig -> "\n- Expected output signature: `#{sig}`"
      end

    mission_info =
      if mission do
        "\n\n## Original Mission\n#{truncate(mission, 1000)}"
      else
        ""
      end

    """
    You are a data sufficiency checker. Verify that available upstream data contains \
    every data point the downstream task needs.
    #{mission_info}

    ## Downstream Task
    - Task ID: #{task.id}
    - Task description: #{format_input(expanded_input)}#{signature_info}

    ## Available Upstream Data
    #{dep_summaries}

    ## Instructions
    1. Read the downstream task description and signature to identify every specific \
    data point required (e.g., "net sales", "total assets", "employee count").
    2. For EACH required data point, search the upstream data and record evidence:
       - `field`: the data point name (e.g., "net sales")
       - `found`: true only if the exact value appears in the upstream data
       - `source`: the upstream task_id where the value was found, or "NOT FOUND"
    3. Mark `sufficient: true` ONLY if every required data point has `found: true`.
    4. List any unfound data points in `missing`.

    Be precise: a data point is "found" only if the actual numeric value or text \
    is present in the upstream data. Do not assume values can be derived or inferred \
    from unrelated fields.
    """
  end

  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str
  defp truncate(str, max_len), do: String.slice(str, 0, max_len - 3) <> "..."

  # --- Task Execution ---

  defp execute_task(task, agents, results, opts) do
    case task.type do
      :synthesis_gate ->
        execute_synthesis_gate(task, agents, results, opts)

      :human_review ->
        execute_human_review(task, results, opts)

      :task ->
        execute_regular_task(task, agents, results, opts)
    end
  end

  # Human review: pauses execution until a human provides a decision
  defp execute_human_review(task, results, opts) do
    # Check if a decision has been provided for this task
    case Map.fetch(opts.reviews, task.id) do
      {:ok, decision} ->
        # Decision provided - use it as the result
        Logger.debug("Human review '#{task.id}' resolved with decision")
        {:ok, decision}

      :error ->
        # No decision yet - return waiting status
        # Expand the prompt with any available results
        expanded_prompt = expand_input(task.input, results)

        pending = %{
          task_id: task.id,
          prompt: expanded_prompt,
          context: %{
            depends_on: task.depends_on,
            upstream_results: Map.take(results, task.depends_on)
          }
        }

        {:waiting, [pending]}
    end
  end

  # Synthesis gate: compresses results from upstream dependencies into a summary
  defp execute_synthesis_gate(task, agents, results, opts) do
    agent_spec = Map.get(agents, task.agent, %{prompt: "", tools: []})

    # Only include results from tasks this gate depends on
    # This prevents context bloat when gates synthesize specific branches
    relevant_results = Map.take(results, task.depends_on)

    # Format relevant results for the gate to process (no truncation — gates compress)
    results_summary = format_upstream_results(relevant_results)

    # Build gate prompt with compression instructions
    gate_prompt = build_gate_prompt(agent_spec, task.input, results_summary)

    # Gates default to JSON mode but can be overridden via task.output
    output_mode = Map.get(task, :output) || :json
    signature = Map.get(task, :signature) || ":any"

    agent =
      SubAgent.new(
        prompt: gate_prompt,
        signature: signature,
        max_turns: 1,
        timeout: opts.timeout,
        output: output_mode
      )

    context = %{
      input: task.input,
      results: relevant_results,
      is_synthesis_gate: true
    }

    case SubAgent.run(agent,
           llm: opts.llm,
           llm_registry: opts.llm_registry,
           context: context
         ) do
      {:ok, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})

        # Validate synthesis result - blank/malformed is fatal for downstream tasks
        case validate_synthesis_result(step.return) do
          :ok -> {:ok, step.return}
          {:error, reason} -> {:error, {:synthesis_error, task.id, reason}}
        end

      {:error, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})
        {:error, step.fail}
    end
  end

  # Validate synthesis gate result - blank or malformed results fail fast
  defp validate_synthesis_result(nil), do: {:error, "Synthesis produced no result"}
  defp validate_synthesis_result(""), do: {:error, "Synthesis produced empty result"}

  defp validate_synthesis_result(result) when is_binary(result) do
    trimmed = String.trim(result)

    cond do
      trimmed == "" ->
        {:error, "Synthesis produced whitespace-only result"}

      byte_size(trimmed) < 10 ->
        {:error, "Synthesis result too short (#{byte_size(trimmed)} chars)"}

      true ->
        :ok
    end
  end

  defp validate_synthesis_result(result) when is_map(result) do
    if map_size(result) == 0 do
      {:error, "Synthesis produced empty map"}
    else
      :ok
    end
  end

  defp validate_synthesis_result(result) when is_list(result) do
    if result == [] do
      {:error, "Synthesis produced empty list"}
    else
      :ok
    end
  end

  defp validate_synthesis_result(_), do: :ok

  defp execute_regular_task(%{agent: "direct"} = task, agents, results, opts) do
    execute_direct_task(task, agents, results, opts)
  end

  defp execute_regular_task(task, agents, results, opts) do
    # Get agent spec (or use default)
    agent_spec = Map.get(agents, task.agent, %{prompt: "", tools: []})

    # Build context with previous results
    context = %{
      input: task.input,
      results: results
    }

    # Expand input template with results
    expanded_input = expand_input(task.input, results)

    # Get system feedback if present (from smart retry)
    system_feedback = Map.get(task, :system_feedback)

    # Build prompt from agent spec and task (with optional feedback)
    prompt = build_prompt(agent_spec, expanded_input, system_feedback)

    # Inject dependency results for tasks with depends_on
    prompt =
      if task.depends_on != [] do
        dep_results = Map.take(results, task.depends_on)
        inject_dependency_results(prompt, dep_results)
      else
        prompt
      end

    # Resolve tools from base_tools
    tools = select_tools(agent_spec.tools, opts.base_tools)

    # Determine output mode:
    # 1. Use task.output if explicitly specified
    # 2. Otherwise auto-detect: tools present -> :ptc_lisp, no tools -> :json
    output_mode =
      case Map.get(task, :output) do
        nil -> if map_size(tools) > 0, do: :ptc_lisp, else: :json
        mode -> mode
      end

    agent_opts =
      case output_mode do
        :ptc_lisp ->
          # PTC-Lisp mode (with or without tools)
          base_opts = [
            prompt: prompt,
            tools: tools,
            output: :ptc_lisp,
            max_turns: opts.max_turns,
            timeout: opts.timeout
          ]

          # Inject builtin_tools for PTC-Lisp agents
          base_opts =
            if opts.builtin_tools != [],
              do: Keyword.put(base_opts, :builtin_tools, opts.builtin_tools),
              else: base_opts

          # Add signature if present in task
          base_opts =
            if sig = Map.get(task, :signature),
              do: Keyword.put(base_opts, :signature, sig),
              else: base_opts

          base_opts

        :json ->
          # JSON mode (simpler, no code generation needed)
          # Use task signature if provided, otherwise fall back to :any
          signature = Map.get(task, :signature) || ":any"

          [
            prompt: prompt,
            signature: signature,
            max_turns: opts.max_turns,
            timeout: opts.timeout,
            output: :json
          ]
      end

    agent = SubAgent.new(agent_opts)

    case SubAgent.run(agent,
           llm: opts.llm,
           llm_registry: opts.llm_registry,
           context: context
         ) do
      {:ok, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})
        {:ok, step.return}

      {:error, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})
        {:error, step.fail}
    end
  end

  # --- Direct Task Execution ---

  # Execute a task with agent: "direct" by running the input as PTC-Lisp code.
  # No SubAgent, no LLM call. The planner provides the code directly.
  #
  # Upstream results are available via `data/results` in the Lisp environment,
  # avoiding string injection issues from template expansion into Lisp source.
  # All base_tools are available by default (no "direct" agent definition needed).
  defp execute_direct_task(task, _agents, results, opts) do
    dep_results = Map.take(results, task.depends_on)

    lisp_opts = [
      tools: opts.base_tools,
      context: %{"results" => dep_results},
      timeout: opts.timeout,
      max_heap: Map.get(opts, :max_heap, 1_250_000)
    ]

    lisp_opts =
      if sig = Map.get(task, :signature),
        do: Keyword.put(lisp_opts, :signature, sig),
        else: lisp_opts

    case Lisp.run(task.input, lisp_opts) do
      {:ok, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})
        {:ok, step.return}

      {:error, step} ->
        emit_event(opts, {:task_step, %{task_id: task.id, step: step}})
        {:error, step.fail}
    end
  rescue
    e ->
      {:error, {:direct_execution_error, Exception.message(e)}}
  end

  # --- Verification ---

  # Run verification predicate if specified
  defp run_verification(%{verification: nil}, _output, _results), do: :passed

  defp run_verification(%{verification: predicate} = task, output, results) do
    # Build depends map from task's depends_on
    depends = Map.take(results, task.depends_on)

    # Create bindings for the Lisp predicate
    # Use string keys for data/input, data/result, data/depends namespace access
    bindings = %{
      "input" => task.input,
      "result" => output,
      "depends" => depends
    }

    case Lisp.run(predicate, context: bindings, timeout: 1000) do
      {:ok, step} ->
        case step.return do
          true -> :passed
          false -> {:failed, "Verification failed"}
          diagnosis when is_binary(diagnosis) -> {:failed, diagnosis}
          other -> {:failed, "Verification returned unexpected value: #{inspect(other)}"}
        end

      {:error, step} ->
        {:error, step.fail}
    end
  end

  # Handle verification failure based on on_verification_failure setting
  defp handle_verification_failure(
         task,
         output,
         diagnosis,
         agents,
         results,
         opts,
         max_attempts,
         attempt
       ) do
    case task.on_verification_failure do
      :stop ->
        Logger.warning("Task #{task.id} verification failed: #{diagnosis}")
        {:error, {:verification_failed, task.id, diagnosis}}

      :skip ->
        Logger.warning("Task #{task.id} verification failed (skipped): #{diagnosis}")
        {:skipped, diagnosis}

      :retry when attempt < max_attempts ->
        Logger.debug(
          "Task #{task.id} verification failed (attempt #{attempt}/#{max_attempts}): #{diagnosis}"
        )

        # Smart retry: inject diagnosis into task input
        task_with_feedback = inject_verification_feedback(task, diagnosis)

        # Backoff before retry
        Process.sleep(100 * attempt)

        execute_with_attempts(
          task_with_feedback,
          agents,
          results,
          opts,
          max_attempts,
          attempt + 1
        )

      :retry ->
        # Retries exhausted
        Logger.warning(
          "Task #{task.id} verification failed after #{attempt} attempts: #{diagnosis}"
        )

        if task.critical do
          {:error, {:verification_failed, task.id, diagnosis}}
        else
          {:skipped, diagnosis}
        end

      :replan ->
        Logger.info("Task #{task.id} verification failed, requesting replan: #{diagnosis}")

        {:replan_required,
         %{
           task_id: task.id,
           task_output: output,
           diagnosis: diagnosis,
           completed_results: results
         }}
    end
  end

  # Only replan when the agent deliberately called (fail "reason"),
  # not on system errors (timeouts, LLM failures, etc.)
  defp deliberate_fail?(%{reason: :failed}), do: true
  defp deliberate_fail?(_), do: false

  defp format_fail_diagnosis(%{message: message}) when is_binary(message), do: message
  defp format_fail_diagnosis(reason), do: inspect(reason)

  # Inject verification feedback into task for smart retry
  # Uses a separate system_feedback field that build_prompt renders
  defp inject_verification_feedback(task, diagnosis) do
    Map.put(task, :system_feedback, diagnosis)
  end

  # Format upstream results for injection into prompts (synthesis gates, regular tasks, etc.)
  # Sorts by task_id for reproducible prompts and truncates large values.
  defp format_upstream_results(results, opts \\ []) do
    max_len = Keyword.get(opts, :max_len, :infinity)

    results
    |> Enum.sort_by(fn {task_id, _} -> task_id end)
    |> Enum.map_join("\n\n", fn {task_id, value} ->
      formatted_value =
        case value do
          v when is_binary(v) -> v
          v -> Jason.encode!(v, pretty: true)
        end

      formatted_value =
        if max_len != :infinity, do: truncate(formatted_value, max_len), else: formatted_value

      "### #{task_id}\n#{formatted_value}"
    end)
  end

  # Inject upstream dependency results into a regular task's prompt
  defp inject_dependency_results(prompt, dep_results) when map_size(dep_results) == 0, do: prompt

  defp inject_dependency_results(prompt, dep_results) do
    formatted = format_upstream_results(dep_results, max_len: 5000)

    """
    #{prompt}

    ## Upstream Results
    #{formatted}
    """
  end

  # Build prompt for synthesis gate with compression instructions
  defp build_gate_prompt(%{prompt: agent_prompt}, task_input, results_summary) do
    base_prompt =
      if agent_prompt == "" do
        "You are a synthesis agent that compresses and summarizes information."
      else
        agent_prompt
      end

    """
    #{base_prompt}

    ## Your Task
    #{task_input}

    ## IMPORTANT: Compression Required
    You are a SYNTHESIS GATE. Your job is to compress the following task results into a concise summary.
    - Extract only the key findings, decisions, and data points
    - Remove redundant information and verbose explanations
    - Preserve critical facts, numbers, and conclusions
    - Output should be significantly shorter than the input
    - Structure your output for easy consumption by downstream tasks

    ## Previous Task Results to Synthesize
    #{results_summary}

    ## Instructions
    Produce a compressed JSON summary that captures the essential information from the above results.
    """
  end

  # Expand {{results.task_id}} and {{results.task_id.field}} patterns
  defp expand_input(input, results) when is_binary(input) do
    Regex.replace(~r/\{\{results\.([^}]+)\}\}/, input, fn _match, path ->
      case resolve_path(path, results) do
        {:ok, value} -> format_value(value)
        :error -> "{{results.#{path}}}"
      end
    end)
  end

  defp expand_input(input, _results), do: input

  defp resolve_path(path, results) do
    parts = String.split(path, ".")

    case parts do
      [task_id] ->
        case Map.fetch(results, task_id) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end

      [task_id | field_path] ->
        case Map.fetch(results, task_id) do
          {:ok, value} -> get_nested(value, field_path)
          :error -> :error
        end
    end
  end

  defp get_nested(value, []) do
    {:ok, value}
  end

  defp get_nested(value, [key | rest]) when is_map(value) do
    # Try both string and atom keys
    case Map.fetch(value, key) do
      {:ok, v} ->
        get_nested(v, rest)

      :error ->
        case Map.fetch(value, String.to_existing_atom(key)) do
          {:ok, v} -> get_nested(v, rest)
          :error -> :error
        end
    end
  rescue
    ArgumentError -> :error
  end

  defp get_nested(_, _), do: :error

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Jason.encode!(value)

  # Build prompt from agent spec and expanded input
  # Handles system_feedback separately from input for smart retry

  defp build_prompt(%{prompt: ""}, input, nil), do: format_input(input)

  defp build_prompt(%{prompt: ""}, input, feedback) do
    """
    #{format_input(input)}

    ## System Feedback
    IMPORTANT: Your previous attempt failed verification.
    Error: "#{feedback}"
    Please adjust your approach to satisfy this requirement.
    """
  end

  defp build_prompt(%{prompt: agent_prompt}, input, nil) do
    """
    #{agent_prompt}

    Task: #{format_input(input)}
    """
  end

  defp build_prompt(%{prompt: agent_prompt}, input, feedback) do
    """
    #{agent_prompt}

    Task: #{format_input(input)}

    ## System Feedback
    IMPORTANT: Your previous attempt failed verification.
    Error: "#{feedback}"
    Please adjust your approach to satisfy this requirement.
    """
  end

  # Format input for prompts - maps rendered as JSON, not Elixir syntax
  defp format_input(input) when is_binary(input), do: input
  defp format_input(input) when is_map(input), do: Jason.encode!(input, pretty: true)
  defp format_input(input) when is_list(input), do: Jason.encode!(input, pretty: true)
  defp format_input(input), do: to_string(input)

  # Enrich base_tools with signatures from available_tools descriptions.
  # This allows raw anonymous functions to be properly documented for the LLM.
  #
  # available_tools format: %{"tool_name" => "Description. Input: {param: type}. Output: ..."}
  # base_tools format: %{"tool_name" => fn | {fn, signature} | {fn, opts}}
  #
  # If a base_tool is a raw function and there's a matching available_tool description,
  # we convert the description to a signature and wrap the function.
  defp enrich_tools_with_descriptions(base_tools, available_tools)
       when map_size(available_tools) == 0 do
    base_tools
  end

  defp enrich_tools_with_descriptions(base_tools, available_tools) do
    Map.new(base_tools, fn {name, tool_def} ->
      case {tool_def, Map.get(available_tools, name)} do
        # Raw function with available description -> enrich with signature
        {fun, desc} when is_function(fun) and is_binary(desc) ->
          signature = description_to_signature(desc)
          {name, {fun, signature: signature, description: desc}}

        # Already has signature or no description -> keep as-is
        _ ->
          {name, tool_def}
      end
    end)
  end

  # Convert a tool description string to a PTC signature.
  # Input format: "Description. Input: {param: type, ...}. Output: {field: type, ...}"
  # Output format: "(param :type, ...) -> {field :type, ...}"
  defp description_to_signature(description) do
    input_part = extract_io_part(description, ~r/Input:\s*\{([^}]+)\}/i)
    output_part = extract_io_part(description, ~r/Output:\s*\{([^}]+)\}/i)

    input_sig = if input_part, do: "(#{format_params(input_part)})", else: "()"
    output_sig = if output_part, do: "{#{format_params(output_part)}}", else: ":any"

    "#{input_sig} -> #{output_sig}"
  end

  defp extract_io_part(description, regex) do
    case Regex.run(regex, description) do
      [_, match] -> match
      nil -> nil
    end
  end

  # Convert "param: type, param2: type2" to "param :type, param2 :type2"
  defp format_params(params_str) do
    params_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map_join(", ", fn param ->
      case String.split(param, ":", parts: 2) do
        [name, type] -> "#{String.trim(name)} :#{String.trim(type)}"
        [name] -> "#{String.trim(name)} :any"
      end
    end)
  end

  # Select tools based on agent's requested tools
  defp select_tools([], _base_tools), do: %{}

  defp select_tools(tool_names, base_tools) do
    tool_names
    |> Enum.filter(&Map.has_key?(base_tools, &1))
    |> Map.new(fn name -> {name, Map.fetch!(base_tools, name)} end)
  end

  # Emit event if callback is provided
  defp emit_event(%{on_event: nil}, _event), do: :ok

  defp emit_event(%{on_event: callback}, event) when is_function(callback, 1),
    do: callback.(event)

  # Convert task struct to map for telemetry
  defp task_to_map(task) do
    %{
      id: task.id,
      agent: task.agent,
      input: task.input,
      output: Map.get(task, :output),
      signature: Map.get(task, :signature),
      depends_on: task.depends_on,
      type: task.type,
      verification: task.verification,
      on_verification_failure: task.on_verification_failure,
      quality_gate: Map.get(task, :quality_gate)
    }
  end
end
