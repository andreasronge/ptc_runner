defmodule PtcRunner.PlanExecutor do
  @moduledoc """
  Execute plans with automatic replanning support.

  PlanExecutor provides two levels of API:

  ## Telemetry Events

  PlanExecutor emits telemetry events for observability:

  - `[:ptc_runner, :plan_executor, :plan, :generated]` - Plan generated
    - metadata: `%{plan: plan, mission: mission}`
  - `[:ptc_runner, :plan_executor, :execution, :start]` - Execution starting
    - metadata: `%{plan: plan, mission: mission, attempt: n}`
  - `[:ptc_runner, :plan_executor, :execution, :stop]` - Execution finished
    - measurements: `%{duration: native_time}`
    - metadata: `%{status: :ok | :error, results: map}`
  - `[:ptc_runner, :plan_executor, :task, :start]` - Task starting
    - metadata: `%{task_id: id, task: task, attempt: n}`
  - `[:ptc_runner, :plan_executor, :task, :stop]` - Task finished
    - measurements: `%{duration: native_time}`
    - metadata: `%{task_id: id, status: :ok | :error | :skipped, result: term}`
  - `[:ptc_runner, :plan_executor, :replan, :start]` - Replan starting
    - metadata: `%{task_id: id, diagnosis: string, attempt: n}`
  - `[:ptc_runner, :plan_executor, :replan, :stop]` - Replan finished
    - metadata: `%{new_task_count: n}`


  ## High-Level API: `run/2`

  The "one-stop-shop" for autonomous execution. Generates a plan from a mission
  and executes it with automatic replanning:

      {:ok, results, metadata} = PlanExecutor.run("Research AAPL stock price",
        llm: my_llm,
        available_tools: %{
          "search" => "Search the web for information",
          "fetch_price" => "Get stock price for a symbol"
        },
        base_tools: %{
          "search" => &MyApp.search/1,
          "fetch_price" => &MyApp.fetch_price/1
        }
      )

  ## Low-Level API: `execute/3`

  For when you already have a plan and want fine-grained control:

      {:ok, plan} = MetaPlanner.plan(mission, llm: llm)
      {:ok, metadata} = PlanExecutor.execute(plan, mission, llm: my_llm)

  ## Execution Lifecycle

  1. Generate plan via MetaPlanner (for `run/2`)
  2. Validate plan structure
  3. Execute via PlanRunner
  4. If verification fails with `:replan`, generate repair plan
  5. Re-execute with repair plan (preserving completed results)
  6. Repeat until success, max replans reached, or unrecoverable error

  ## Loop Prevention

  The executor enforces limits to prevent runaway costs:
  - `max_replan_attempts` - Max replans for the same task (default: 3)
  - `max_total_replans` - Max total replans per execution (default: 5)
  - `replan_cooldown_ms` - Delay between replan attempts (default: 1000)

  ## Observability

  Use the `on_event` callback for real-time execution visibility:

      PlanExecutor.run(mission,
        llm: my_llm,
        on_event: &PlanTracer.log_event/1
      )

  """

  alias PtcRunner.CapabilityRegistry.TrialHistory
  alias PtcRunner.MetaPlanner
  alias PtcRunner.Plan
  alias PtcRunner.PlanRunner

  require Logger

  @default_max_replan_attempts 3
  @default_max_total_replans 5
  @default_replan_cooldown_ms 1000

  # Event types emitted via on_event callback
  # Planning events (run/2 only)
  @type event ::
          {:planning_started, %{mission: String.t()}}
          | {:planning_finished, %{task_count: non_neg_integer()}}
          | {:planning_failed, %{reason: term()}}
          | {:planning_retry, %{validation_errors: non_neg_integer()}}
          # Execution events
          | {:execution_started, %{mission: String.t(), task_count: non_neg_integer()}}
          | {:execution_finished,
             %{status: :ok | :error | :waiting, duration_ms: non_neg_integer()}}
          | {:task_started, %{task_id: String.t(), attempt: pos_integer()}}
          | {:task_succeeded, %{task_id: String.t(), duration_ms: non_neg_integer()}}
          | {:task_failed, %{task_id: String.t(), reason: term()}}
          | {:task_skipped, %{task_id: String.t(), reason: :already_completed}}
          | {:verification_failed, %{task_id: String.t(), diagnosis: String.t()}}
          | {:replan_started,
             %{task_id: String.t(), diagnosis: String.t(), total_replans: non_neg_integer()}}
          | {:replan_finished, %{new_tasks: non_neg_integer()}}

  @type event_callback :: (event() -> any()) | nil

  @type run_result ::
          {:ok, %{String.t() => term()}, execution_metadata()}
          | {:error, term(), execution_metadata()}
          | {:waiting, [PlanRunner.pending_review()], execution_metadata()}

  @type replan_record :: %{
          attempt: pos_integer(),
          task_id: String.t(),
          timestamp: DateTime.t(),
          input: String.t(),
          approach: String.t(),
          output: String.t(),
          diagnosis: String.t(),
          new_task_count: pos_integer()
        }

  @type execution_metadata :: %{
          results: %{String.t() => term()},
          replan_count: non_neg_integer(),
          execution_attempts: non_neg_integer(),
          total_duration_ms: non_neg_integer(),
          replan_history: [replan_record()]
        }

  @type execute_result ::
          {:ok, execution_metadata()}
          | {:error, term(), execution_metadata()}
          | {:waiting, [PlanRunner.pending_review()], execution_metadata()}

  # ============================================================================
  # High-Level API
  # ============================================================================

  @doc """
  Generate and execute a plan from a natural language mission.

  This is the "one-stop-shop" API that handles the full lifecycle:
  1. Generate plan via MetaPlanner
  2. Validate plan structure
  3. Execute with automatic replanning

  ## Parameters

  - `mission` - Natural language description of what to accomplish
  - `opts` - Execution options

  ## Options

  All `execute/3` options are supported, plus:

  - `available_tools` - Map of tool_name => description for planning
  - `constraints` - Optional planning constraints/guidelines

  ## Returns

  - `{:ok, results, metadata}` - Success with task results and execution stats
  - `{:error, reason, metadata}` - Failure with partial results and stats
  - `{:waiting, pending, metadata}` - Paused at human review

  ## Example

      {:ok, results, metadata} = PlanExecutor.run("Research AAPL stock",
        llm: my_llm,
        available_tools: %{
          "search" => "Search the web. Input: query. Output: list of results",
          "fetch_price" => "Get stock price. Input: symbol. Output: {price, change}"
        },
        base_tools: %{
          "search" => &MyApp.search/1,
          "fetch_price" => &MyApp.fetch_price/1
        },
        on_event: &PlanTracer.log_event/1
      )

  """
  @spec run(String.t(), keyword()) :: run_result()
  def run(mission, opts) do
    llm = Keyword.fetch!(opts, :llm)
    available_tools = Keyword.get(opts, :available_tools, %{})
    constraints = Keyword.get(opts, :constraints)
    on_event = Keyword.get(opts, :on_event)

    # Emit planning started event
    if on_event, do: on_event.({:planning_started, %{mission: mission}})

    # Generate plan with self-correction
    plan_opts = [
      llm: llm,
      available_tools: available_tools,
      constraints: constraints
    ]

    case generate_valid_initial_plan(mission, plan_opts, on_event) do
      {:ok, plan} ->
        if on_event, do: on_event.({:planning_finished, %{task_count: length(plan.tasks)}})

        # Emit telemetry with full plan structure
        :telemetry.execute(
          [:ptc_runner, :plan_executor, :plan, :generated],
          %{system_time: System.system_time()},
          %{plan: plan_to_map(plan), mission: mission, task_count: length(plan.tasks)}
        )

        # Pass constraints through to execute for replanning
        execute_opts =
          if constraints do
            Keyword.put(opts, :constraints, constraints)
          else
            opts
          end

        # Execute the plan
        case execute(plan, mission, execute_opts) do
          {:ok, metadata} ->
            {:ok, metadata.results, metadata}

          {:waiting, pending, metadata} ->
            {:waiting, pending, metadata}

          {:error, reason, metadata} ->
            {:error, reason, metadata}
        end

      {:error, reason} ->
        if on_event, do: on_event.({:planning_failed, %{reason: reason}})

        {:error, {:planning_failed, reason}, build_metadata_empty()}
    end
  end

  # Generate initial plan with self-correcting validation retry
  defp generate_valid_initial_plan(mission, plan_opts, on_event) do
    generator = fn opts -> MetaPlanner.plan(mission, opts) end

    on_retry = fn validation_issues ->
      Logger.warning(
        "PlanExecutor: Initial plan invalid, attempting self-correction with feedback"
      )

      if on_event,
        do: on_event.({:planning_retry, %{validation_errors: length(validation_issues)}})
    end

    on_success = fn -> Logger.info("PlanExecutor: Initial plan self-correction succeeded") end

    on_final_failure = fn retry_issues ->
      Logger.error("PlanExecutor: Initial plan invalid after self-correction")

      for issue <- retry_issues do
        Logger.error("  [#{issue.category}] #{issue.message}")
      end
    end

    validate_plan_with_retry(
      generator,
      plan_opts,
      {:initial_plan_invalid, on_retry, on_success, on_final_failure}
    )
  end

  # ============================================================================
  # Low-Level API
  # ============================================================================

  @doc """
  Execute a plan with automatic replanning on verification failures.

  ## Parameters

  - `plan` - Parsed `%Plan{}` struct
  - `mission` - Original mission description (needed for replanning context)
  - `opts` - Execution options

  ## Options

  All PlanRunner options are supported, plus:

  - `max_replan_attempts` - Max replans per task (default: 3)
  - `max_total_replans` - Max total replans (default: 5)
  - `replan_cooldown_ms` - Delay between replans (default: 1000)
  - `on_event` - Optional callback for lifecycle events. See `t:event/0` for event types.

  ## Returns

  - `{:ok, metadata}` - Success with results and execution stats
  - `{:error, reason, metadata}` - Failure with partial results and stats
  - `{:waiting, pending, metadata}` - Paused at human review

  """
  @spec execute(Plan.t(), String.t(), keyword()) :: execute_result()
  def execute(%Plan{} = plan, mission, opts) do
    # Validate plan before execution
    case Plan.validate(plan) do
      :ok ->
        # Sanitize: remove invalid verification predicates
        {sanitized_plan, warnings} = Plan.sanitize(plan)

        for warning <- warnings do
          Logger.warning("PlanExecutor: #{warning.message}")
        end

        do_execute(sanitized_plan, mission, opts)

      {:error, issues} ->
        Logger.error("PlanExecutor: Initial plan validation failed")

        for issue <- issues do
          Logger.error("  [#{issue.category}] #{issue.message}")
        end

        {:error, {:invalid_plan, issues}, build_metadata_empty()}
    end
  end

  defp do_execute(plan, mission, opts) do
    max_replan_attempts = Keyword.get(opts, :max_replan_attempts, @default_max_replan_attempts)
    max_total_replans = Keyword.get(opts, :max_total_replans, @default_max_total_replans)
    replan_cooldown_ms = Keyword.get(opts, :replan_cooldown_ms, @default_replan_cooldown_ms)
    on_event = Keyword.get(opts, :on_event)
    initial_results = Keyword.get(opts, :initial_results, %{})
    registry = Keyword.get(opts, :registry)
    context_tags = Keyword.get(opts, :context_tags, [])

    # Filter out executor-specific options for PlanRunner
    # Keep on_event so PlanRunner can emit task-level events
    # Drop initial_results since we manage it via completed_results
    runner_opts =
      Keyword.drop(opts, [
        :max_replan_attempts,
        :max_total_replans,
        :replan_cooldown_ms,
        :initial_results
      ])

    # Extract constraints for replanning (passed through from run/2)
    constraints = Keyword.get(opts, :constraints)

    state = %{
      plan: plan,
      mission: mission,
      opts: runner_opts,
      completed_results: initial_results,
      replan_count: 0,
      execution_attempts: 0,
      replan_history: [],
      task_replan_counts: %{},
      max_replan_attempts: max_replan_attempts,
      max_total_replans: max_total_replans,
      replan_cooldown_ms: replan_cooldown_ms,
      on_event: on_event,
      constraints: constraints,
      registry: registry,
      context_tags: context_tags,
      start_time: System.monotonic_time(:millisecond)
    }

    # Emit execution_started event
    emit_event(state, {:execution_started, %{mission: mission, task_count: length(plan.tasks)}})

    # Compute phase summary for telemetry
    phases = Plan.group_by_level(plan.tasks)

    phase_summary =
      Enum.with_index(phases, fn phase_tasks, idx ->
        %{phase: idx, task_ids: Enum.map(phase_tasks, & &1.id)}
      end)

    # Emit telemetry for execution start with full plan
    :telemetry.execute(
      [:ptc_runner, :plan_executor, :execution, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{
        plan: plan_to_map(plan),
        mission: mission,
        task_count: length(plan.tasks),
        phases: phase_summary,
        attempt: 1
      }
    )

    result = execute_loop(state)

    # Emit telemetry for execution stop
    duration = System.monotonic_time(:millisecond) - state.start_time

    {status, results, replan_count} =
      case result do
        {:ok, metadata} -> {:ok, metadata.results, metadata.replan_count}
        {:waiting, _, metadata} -> {:waiting, metadata.results, metadata.replan_count}
        {:error, _, metadata} -> {:error, metadata.results, metadata.replan_count}
      end

    :telemetry.execute(
      [:ptc_runner, :plan_executor, :execution, :stop],
      %{duration: duration * 1_000_000},
      %{
        status: status,
        results: results,
        replan_count: replan_count,
        total_tasks: map_size(results),
        task_ids: Map.keys(results)
      }
    )

    result
  end

  defp execute_loop(state) do
    state = %{state | execution_attempts: state.execution_attempts + 1}

    Logger.info(
      "PlanExecutor: Execution attempt #{state.execution_attempts} " <>
        "(replans: #{state.replan_count}/#{state.max_total_replans})"
    )

    # Execute with current completed results as initial_results
    runner_opts = Keyword.put(state.opts, :initial_results, state.completed_results)

    case PlanRunner.execute(state.plan, runner_opts) do
      {:ok, results} ->
        # Success!
        metadata = build_metadata(state, results)

        # Record trial if registry present
        record_execution_trial(state, true, nil)

        emit_event(
          state,
          {:execution_finished, %{status: :ok, duration_ms: metadata.total_duration_ms}}
        )

        {:ok, metadata}

      {:waiting, pending, partial_results} ->
        # Human review needed
        merged_results = Map.merge(state.completed_results, partial_results)
        metadata = build_metadata(state, merged_results)

        emit_event(
          state,
          {:execution_finished, %{status: :waiting, duration_ms: metadata.total_duration_ms}}
        )

        {:waiting, pending, metadata}

      {:replan_required, context} ->
        handle_replan(state, context)

      {:error, task_id, partial_results, reason} ->
        # Unrecoverable error
        merged_results = Map.merge(state.completed_results, partial_results)
        metadata = build_metadata(state, merged_results)

        # Record failure trial
        record_execution_trial(state, false, "task error: #{inspect(reason)}")

        emit_event(
          state,
          {:execution_finished, %{status: :error, duration_ms: metadata.total_duration_ms}}
        )

        {:error, {:task_failed, task_id, reason}, metadata}
    end
  end

  defp handle_replan(state, context) do
    task_id = context.task_id
    diagnosis = context.diagnosis

    # Emit verification_failed event
    emit_event(state, {:verification_failed, %{task_id: task_id, diagnosis: diagnosis}})

    # Check loop limits
    task_replan_count = Map.get(state.task_replan_counts, task_id, 0)

    cond do
      state.replan_count >= state.max_total_replans ->
        Logger.warning("PlanExecutor: Max total replans (#{state.max_total_replans}) reached")
        metadata = build_metadata(state, state.completed_results)

        # Record failure trial
        record_execution_trial(state, false, "max replans exceeded")

        emit_event(
          state,
          {:execution_finished, %{status: :error, duration_ms: metadata.total_duration_ms}}
        )

        {:error, {:max_replans_exceeded, :total, state.replan_count}, metadata}

      task_replan_count >= state.max_replan_attempts ->
        Logger.warning(
          "PlanExecutor: Max replans for task '#{task_id}' (#{state.max_replan_attempts}) reached"
        )

        metadata = build_metadata(state, state.completed_results)

        # Record failure trial
        record_execution_trial(state, false, "per-task replan limit for #{task_id}")

        emit_event(
          state,
          {:execution_finished, %{status: :error, duration_ms: metadata.total_duration_ms}}
        )

        {:error, {:max_replans_exceeded, :per_task, task_id, task_replan_count}, metadata}

      true ->
        do_replan(state, context, task_id, diagnosis, task_replan_count)
    end
  end

  defp do_replan(state, context, task_id, diagnosis, task_replan_count) do
    Logger.info(
      "PlanExecutor: Task '#{task_id}' requires replan (attempt #{task_replan_count + 1}/#{state.max_replan_attempts})"
    )

    Logger.info("PlanExecutor: Diagnosis: #{diagnosis}")

    # Emit replan_started event
    emit_event(
      state,
      {:replan_started,
       %{task_id: task_id, diagnosis: diagnosis, total_replans: state.replan_count + 1}}
    )

    # Emit replan telemetry
    :telemetry.execute(
      [:ptc_runner, :plan_executor, :replan, :start],
      %{system_time: System.system_time()},
      %{task_id: task_id, diagnosis: diagnosis, attempt: task_replan_count + 1}
    )

    # Cooldown before replanning
    if state.replan_cooldown_ms > 0 do
      Process.sleep(state.replan_cooldown_ms)
    end

    # Merge any new completed results from this execution attempt
    completed_results = Map.merge(state.completed_results, context.completed_results)

    failure_context = %{
      task_id: task_id,
      task_output: context.task_output,
      diagnosis: diagnosis
    }

    # Try to generate a valid repair plan (with one self-correction retry)
    case generate_valid_repair_plan(state, completed_results, failure_context) do
      {:ok, repair_plan} ->
        # Emit replan_finished event
        emit_event(state, {:replan_finished, %{new_tasks: length(repair_plan.tasks)}})

        # Emit replan stop telemetry
        :telemetry.execute(
          [:ptc_runner, :plan_executor, :replan, :stop],
          %{},
          %{new_task_count: length(repair_plan.tasks), task_id: task_id}
        )

        # Build enriched replan record for trial history
        replan_record = build_replan_record(state, failure_context, length(repair_plan.tasks))

        # Update state and continue
        updated_state = %{
          state
          | plan: repair_plan,
            completed_results: completed_results,
            replan_count: state.replan_count + 1,
            replan_history: state.replan_history ++ [replan_record],
            task_replan_counts: Map.update(state.task_replan_counts, task_id, 1, &(&1 + 1))
        }

        execute_loop(updated_state)

      {:error, {:repair_plan_invalid, validation_issues}} ->
        Logger.error("PlanExecutor: Repair plan failed validation (after self-correction)")

        for issue <- validation_issues do
          Logger.error("  [#{issue.category}] #{issue.message}")
        end

        metadata = build_metadata(state, state.completed_results)

        emit_event(
          state,
          {:execution_finished, %{status: :error, duration_ms: metadata.total_duration_ms}}
        )

        {:error, {:repair_plan_invalid, validation_issues}, metadata}

      {:error, reason} ->
        Logger.error("PlanExecutor: Failed to generate repair plan: #{inspect(reason)}")
        metadata = build_metadata(state, state.completed_results)

        emit_event(
          state,
          {:execution_finished, %{status: :error, duration_ms: metadata.total_duration_ms}}
        )

        {:error, {:replan_generation_failed, reason}, metadata}
    end
  end

  # Generate a repair plan with self-correcting validation retry
  # If the first attempt produces an invalid plan, feed validation errors back for one retry
  defp generate_valid_repair_plan(state, completed_results, failure_context) do
    base_opts =
      state.opts
      |> Keyword.put(:original_plan, state.plan)
      |> Keyword.put(:trial_history, state.replan_history)
      |> then(fn opts ->
        if state.constraints do
          Keyword.put(opts, :constraints, state.constraints)
        else
          opts
        end
      end)

    generator = fn opts ->
      MetaPlanner.replan(state.mission, completed_results, failure_context, opts)
    end

    on_retry = fn _validation_issues ->
      Logger.warning(
        "PlanExecutor: Repair plan invalid, attempting self-correction with feedback"
      )
    end

    on_success = fn -> Logger.info("PlanExecutor: Self-correction succeeded") end

    validate_plan_with_retry(
      generator,
      base_opts,
      {:repair_plan_invalid, on_retry, on_success, fn _ -> :ok end}
    )
  end

  # Validate a generated plan with one retry on validation failure
  # generator: fn opts -> {:ok, plan} | {:error, reason}
  # callbacks: {error_tag, on_retry, on_success, on_final_failure}
  defp validate_plan_with_retry(
         generator,
         opts,
         {error_tag, on_retry, on_success, on_final_failure}
       ) do
    case generator.(opts) do
      {:ok, plan} ->
        case Plan.validate(plan) do
          :ok ->
            {:ok, sanitize_plan(plan)}

          {:error, validation_issues} ->
            on_retry.(validation_issues)
            retry_opts = Keyword.put(opts, :validation_errors, validation_issues)
            validate_plan_retry(generator, retry_opts, error_tag, on_success, on_final_failure)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_plan_retry(generator, opts, error_tag, on_success, on_final_failure) do
    case generator.(opts) do
      {:ok, retry_plan} ->
        case Plan.validate(retry_plan) do
          :ok ->
            on_success.()
            {:ok, sanitize_plan(retry_plan)}

          {:error, retry_issues} ->
            on_final_failure.(retry_issues)
            {:error, {error_tag, retry_issues}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sanitize_plan(plan) do
    {sanitized_plan, warnings} = Plan.sanitize(plan)

    for warning <- warnings do
      Logger.warning("PlanExecutor: #{warning.message}")
    end

    sanitized_plan
  end

  defp build_metadata(state, results) do
    %{
      results: results,
      replan_count: state.replan_count,
      execution_attempts: state.execution_attempts,
      total_duration_ms: System.monotonic_time(:millisecond) - state.start_time,
      replan_history: state.replan_history
    }
  end

  defp build_metadata_empty do
    %{
      results: %{},
      replan_count: 0,
      execution_attempts: 0,
      total_duration_ms: 0,
      replan_history: []
    }
  end

  # Emit event if callback is provided
  defp emit_event(%{on_event: nil}, _event), do: :ok

  defp emit_event(%{on_event: callback}, event) when is_function(callback, 1),
    do: callback.(event)

  # ============================================================================
  # Trial History Helpers
  # ============================================================================

  @doc false
  # Build an enriched replan record for trial history
  def build_replan_record(state, failure_context, new_task_count) do
    task = find_task_by_id(state.plan, failure_context.task_id)

    %{
      attempt: state.replan_count + 1,
      task_id: failure_context.task_id,
      timestamp: DateTime.utc_now(),
      input: truncate_value(task && task.input, 300),
      approach: build_approach_summary(state.plan, failure_context.task_id),
      output: truncate_value(failure_context.task_output, 500),
      diagnosis: truncate_value(failure_context.diagnosis, 300),
      new_task_count: new_task_count
    }
  end

  @doc false
  # Build a summary of the approach used for a task (agent + tools)
  # Note: task input is stored separately in the replan record
  def build_approach_summary(plan, task_id) do
    task = find_task_by_id(plan, task_id)

    if task do
      agent_spec = Map.get(plan.agents, task.agent, %{prompt: "", tools: []})

      "Agent: #{task.agent}\nTools: #{format_tools(agent_spec.tools)}"
      |> truncate_value(400)
    else
      "(task not found)"
    end
  end

  defp find_task_by_id(plan, task_id) do
    Enum.find(plan.tasks, fn t -> t.id == task_id end)
  end

  defp format_tools([]), do: "(none)"
  defp format_tools(tools) when is_list(tools), do: Enum.join(tools, ", ")
  defp format_tools(_), do: "(none)"

  @doc false
  # Truncate any value to a maximum length, handling maps/lists via Jason
  def truncate_value(nil, _max_length), do: "(nil)"

  def truncate_value(value, max_length) when is_binary(value) do
    if String.length(value) <= max_length do
      value
    else
      String.slice(value, 0, max_length - 3) <> "..."
    end
  end

  def truncate_value(value, max_length) do
    case Jason.encode(value) do
      {:ok, json} -> truncate_value(json, max_length)
      {:error, _} -> truncate_value(inspect(value), max_length)
    end
  end

  # ============================================================================
  # Registry Trial Recording
  # ============================================================================

  # Extract all tools used across all agents in a plan
  defp extract_tools_used(plan) do
    plan.agents
    |> Enum.flat_map(fn {_id, spec} -> Map.get(spec, :tools, []) end)
    |> Enum.uniq()
  end

  # Record execution trial to the registry if present
  defp record_execution_trial(%{registry: nil}, _success?, _diagnosis), do: :ok

  defp record_execution_trial(state, success?, diagnosis) do
    TrialHistory.record_trial(state.registry, %{
      tools_used: extract_tools_used(state.plan),
      skills_used: [],
      context_tags: state.context_tags || [],
      model_id: nil,
      success: success?,
      diagnosis: diagnosis
    })
  end

  # ============================================================================
  # Telemetry Helpers
  # ============================================================================

  # Convert plan to a map suitable for telemetry (avoids struct serialization issues)
  defp plan_to_map(%Plan{} = plan) do
    %{
      agents:
        Map.new(plan.agents, fn {id, agent} ->
          {id,
           %{
             prompt: agent.prompt,
             tools: agent.tools
           }}
        end),
      tasks:
        Enum.map(plan.tasks, fn task ->
          %{
            id: task.id,
            agent: task.agent,
            input: task.input,
            signature: task.signature,
            depends_on: task.depends_on,
            type: task.type,
            verification: task.verification,
            on_verification_failure: task.on_verification_failure
          }
        end)
    }
  end
end
