defmodule PtcRunner.PlanCritic do
  @moduledoc """
  Adversarial review of execution plans before they run.

  The PlanCritic acts as an "SRE" that validates plans for:
  - Missing synthesis gates (context window risk)
  - Loose coupling (tasks expecting data that may not exist)
  - Optimism bias (wrong error handling for flaky operations)
  - Structural issues (circular deps, orphan tasks)

  ## Usage

      {:ok, critique} = PlanCritic.review(plan, llm: my_llm)

      if critique.score < 8 do
        {:ok, refined_plan} = MetaPlanner.refine(plan, critique)
      end

  ## Static vs LLM Analysis

  The critic performs both:
  - **Static analysis**: Structural checks that don't need an LLM
  - **LLM analysis**: Semantic checks that require understanding intent
  """

  alias PtcRunner.Plan
  alias PtcRunner.SubAgent

  require Logger

  @type issue :: %{
          category: atom(),
          severity: :critical | :warning | :info,
          task_id: String.t() | nil,
          message: String.t(),
          recommendation: String.t()
        }

  @type critique :: %{
          score: 1..10,
          issues: [issue()],
          summary: String.t(),
          recommendations: [String.t()]
        }

  @doc """
  Review a plan and return a structured critique.

  Combines static analysis (fast, deterministic) with optional LLM analysis
  (slower, semantic understanding).

  ## Options

  - `llm` - LLM callback for semantic analysis (optional)
  - `static_only` - Skip LLM analysis, only do structural checks (default: false)

  ## Returns

  A critique map with:
  - `score` - Overall quality score 1-10
  - `issues` - List of specific issues found
  - `summary` - Human-readable summary
  - `recommendations` - List of actionable fixes
  """
  @spec review(Plan.t(), keyword()) :: {:ok, critique()} | {:error, term()}
  def review(%Plan{} = plan, opts \\ []) do
    static_only = Keyword.get(opts, :static_only, false)

    # Phase 1: Static analysis (always runs)
    static_issues = run_static_analysis(plan)

    # Phase 2: LLM analysis (optional)
    llm_issues =
      if static_only do
        []
      else
        case Keyword.fetch(opts, :llm) do
          {:ok, llm} -> run_llm_analysis(plan, llm, opts)
          :error -> []
        end
      end

    all_issues = static_issues ++ llm_issues

    # Calculate score based on issues
    score = calculate_score(all_issues)

    # Generate summary and recommendations
    summary = generate_summary(all_issues, score)
    recommendations = extract_recommendations(all_issues)

    {:ok,
     %{
       score: score,
       issues: all_issues,
       summary: summary,
       recommendations: recommendations
     }}
  end

  @doc """
  Quick static-only review (no LLM needed).
  """
  @spec static_review(Plan.t()) :: {:ok, critique()}
  def static_review(%Plan{} = plan) do
    review(plan, static_only: true)
  end

  # --- Static Analysis ---

  defp run_static_analysis(plan) do
    [
      check_missing_gates(plan),
      check_parallel_explosion(plan),
      check_optimism_bias(plan),
      check_orphan_tasks(plan),
      check_missing_dependencies(plan),
      check_disconnected_flow(plan)
    ]
    |> List.flatten()
  end

  # Check for parallel phases without downstream synthesis gates
  defp check_missing_gates(plan) do
    phases = Plan.group_by_level(plan.tasks)

    phases
    |> Enum.with_index()
    |> Enum.flat_map(fn {phase, idx} ->
      parallel_count = length(phase)
      has_gate_downstream = has_downstream_gate?(phases, idx)

      if parallel_count >= 3 and not has_gate_downstream do
        [
          %{
            category: :missing_gate,
            severity: :warning,
            task_id: nil,
            message:
              "Phase #{idx} has #{parallel_count} parallel tasks but no synthesis gate downstream",
            recommendation:
              "Add a synthesis_gate task after phase #{idx} to compress results before subsequent tasks"
          }
        ]
      else
        []
      end
    end)
  end

  defp has_downstream_gate?(phases, current_idx) do
    phases
    |> Enum.drop(current_idx + 1)
    |> Enum.any?(fn phase ->
      Enum.any?(phase, fn task -> task.type == :synthesis_gate end)
    end)
  end

  # Check for too many parallel tasks (context explosion risk)
  defp check_parallel_explosion(plan) do
    phases = Plan.group_by_level(plan.tasks)

    phases
    |> Enum.with_index()
    |> Enum.flat_map(fn {phase, idx} ->
      if length(phase) > 10 do
        [
          %{
            category: :parallel_explosion,
            severity: :critical,
            task_id: nil,
            message:
              "Phase #{idx} has #{length(phase)} parallel tasks - risk of context overflow",
            recommendation: "Split into smaller batches or add intermediate synthesis gates"
          }
        ]
      else
        []
      end
    end)
  end

  # Check for flaky operations marked as critical with stop-on-failure
  defp check_optimism_bias(plan) do
    flaky_patterns = ~w(search fetch api web http request query external)

    plan.tasks
    |> Enum.flat_map(fn task ->
      input_lower = String.downcase(to_string(task.input))
      is_flaky = Enum.any?(flaky_patterns, &String.contains?(input_lower, &1))

      if is_flaky and task.critical and task.on_failure == :stop do
        [
          %{
            category: :optimism_bias,
            severity: :warning,
            task_id: task.id,
            message:
              "Task '#{task.id}' looks like a flaky operation but uses critical: true, on_failure: stop",
            recommendation:
              "Set on_failure: :retry with max_retries: 3, or on_failure: :skip if non-critical"
          }
        ]
      else
        []
      end
    end)
  end

  # Check for tasks with dependencies that don't exist
  defp check_missing_dependencies(plan) do
    task_ids = MapSet.new(plan.tasks, & &1.id)

    plan.tasks
    |> Enum.flat_map(fn task ->
      missing = Enum.reject(task.depends_on, &MapSet.member?(task_ids, &1))

      Enum.map(missing, fn dep_id ->
        %{
          category: :missing_dependency,
          severity: :critical,
          task_id: task.id,
          message: "Task '#{task.id}' depends on '#{dep_id}' which doesn't exist",
          recommendation: "Add task '#{dep_id}' or remove it from depends_on"
        }
      end)
    end)
  end

  # Check for tasks that declare dependencies but don't use them in input
  # This catches LLM "hallucinated dependencies" where Task B says it depends on Task A
  # but never actually references {{results.task_a}} in its prompt
  defp check_disconnected_flow(plan) do
    plan.tasks
    |> Enum.flat_map(fn task ->
      # Skip tasks with no dependencies or non-string inputs
      if task.depends_on == [] or not is_binary(task.input) do
        []
      else
        # Find which dependencies are actually referenced in the input
        used_deps =
          task.depends_on
          |> Enum.filter(fn dep_id ->
            # Check for {{results.dep_id}} or {{results.dep_id.field}} patterns
            # Also check for the dep_id mentioned in natural language (weaker signal)
            String.contains?(task.input, "{{results.#{dep_id}") or
              String.contains?(String.downcase(task.input), String.downcase(dep_id))
          end)

        unused_deps = task.depends_on -- used_deps

        # Flag completely disconnected flows (no deps used at all)
        cond do
          unused_deps == task.depends_on and task.depends_on != [] ->
            [
              %{
                category: :disconnected_flow,
                severity: :warning,
                task_id: task.id,
                message:
                  "Task '#{task.id}' depends on #{inspect(task.depends_on)} but doesn't reference any of them in its input",
                recommendation:
                  "Add {{results.#{hd(task.depends_on)}}} to the input, or remove unused dependencies"
              }
            ]

          unused_deps != [] ->
            # Some deps unused - info level (might be intentional for ordering)
            [
              %{
                category: :disconnected_flow,
                severity: :info,
                task_id: task.id,
                message:
                  "Task '#{task.id}' declares dependency on #{inspect(unused_deps)} but doesn't appear to use it",
                recommendation:
                  "Verify the dependency is intentional (for ordering) or add {{results.X}} reference"
              }
            ]

          true ->
            []
        end
      end
    end)
  end

  # Check for tasks that nothing depends on (except final tasks)
  defp check_orphan_tasks(plan) do
    all_dependencies =
      plan.tasks
      |> Enum.flat_map(& &1.depends_on)
      |> MapSet.new()

    # Find tasks that are neither depended upon nor at the end
    final_phase_tasks =
      case Plan.group_by_level(plan.tasks) do
        [] -> MapSet.new()
        phases -> phases |> List.last() |> Enum.map(& &1.id) |> MapSet.new()
      end

    plan.tasks
    |> Enum.flat_map(fn task ->
      is_depended_upon = task.id in all_dependencies
      is_final = task.id in final_phase_tasks

      if not is_depended_upon and not is_final and length(plan.tasks) > 1 do
        [
          %{
            category: :orphan_task,
            severity: :info,
            task_id: task.id,
            message: "Task '#{task.id}' has no downstream dependencies",
            recommendation: "Verify this task's output is used, or connect it to downstream tasks"
          }
        ]
      else
        []
      end
    end)
  end

  # --- LLM Analysis ---

  defp run_llm_analysis(plan, llm, opts) do
    plan_json = format_plan_for_critic(plan)

    prompt = """
    You are a Plan Critic - an adversarial reviewer who finds problems in execution plans.

    ## Plan to Review
    ```json
    #{plan_json}
    ```

    ## Your Task
    Analyze this plan and identify issues in these categories:

    1. **Loose Coupling**: Tasks that depend on data fields that upstream tasks might not provide
    2. **Missing Error Handling**: Tasks that should have retry/skip but don't
    3. **Semantic Issues**: Tasks whose descriptions don't match their apparent purpose
    4. **Data Flow Gaps**: Places where result interpolation (e.g., results.task_id.field references) might fail

    ## Output Format
    Return a JSON array of issues found. Each issue should have:
    - category: one of "loose_coupling", "error_handling", "semantic_issue", "data_flow_gap"
    - severity: "critical", "warning", or "info"
    - task_id: the task id (or null if plan-wide)
    - message: clear description of the problem
    - recommendation: specific fix

    If no issues found, return an empty array: []

    Be thorough but not paranoid. Only flag real problems.
    """

    agent =
      SubAgent.new(
        prompt: prompt,
        signature:
          "[{category :string, severity :string, task_id :string?, message :string, recommendation :string}]",
        max_turns: 1,
        timeout: Keyword.get(opts, :timeout, 30_000),
        output: :json
      )

    case SubAgent.run(agent, llm: llm) do
      {:ok, step} ->
        normalize_llm_issues(step.return)

      {:error, _step} ->
        Logger.warning("LLM analysis failed, using static analysis only")
        []
    end
  end

  defp format_plan_for_critic(plan) do
    %{
      agents: plan.agents,
      tasks:
        Enum.map(plan.tasks, fn t ->
          %{
            id: t.id,
            agent: t.agent,
            input: t.input,
            depends_on: t.depends_on,
            type: t.type,
            on_failure: t.on_failure,
            critical: t.critical
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  defp normalize_llm_issues(issues) when is_list(issues) do
    Enum.map(issues, fn issue ->
      %{
        category: normalize_category(issue["category"]),
        severity: normalize_severity(issue["severity"]),
        task_id: issue["task_id"],
        message: issue["message"] || "No message",
        recommendation: issue["recommendation"] || "No recommendation"
      }
    end)
  end

  defp normalize_llm_issues(_), do: []

  defp normalize_category("loose_coupling"), do: :loose_coupling
  defp normalize_category("error_handling"), do: :error_handling
  defp normalize_category("semantic_issue"), do: :semantic_issue
  defp normalize_category("data_flow_gap"), do: :data_flow_gap
  defp normalize_category("disconnected_flow"), do: :disconnected_flow
  defp normalize_category(_), do: :unknown

  defp normalize_severity("critical"), do: :critical
  defp normalize_severity("warning"), do: :warning
  defp normalize_severity("info"), do: :info
  defp normalize_severity(_), do: :info

  # --- Scoring ---

  defp calculate_score(issues) do
    # Start at 10, deduct for issues
    base_score = 10

    deductions =
      Enum.reduce(issues, 0, fn issue, acc ->
        case issue.severity do
          :critical -> acc + 3
          :warning -> acc + 1
          :info -> acc + 0.5
        end
      end)

    max(1, round(base_score - deductions))
  end

  defp generate_summary([], _score), do: "Plan looks good. No significant issues found."

  defp generate_summary(issues, score) do
    critical_count = Enum.count(issues, &(&1.severity == :critical))
    warning_count = Enum.count(issues, &(&1.severity == :warning))

    cond do
      score <= 3 ->
        "Plan has serious issues. #{critical_count} critical, #{warning_count} warnings. Refinement strongly recommended."

      score <= 6 ->
        "Plan has some issues. #{critical_count} critical, #{warning_count} warnings. Consider refinement."

      score <= 8 ->
        "Plan is acceptable with minor issues. #{warning_count} warnings."

      true ->
        "Plan is good. Minor observations only."
    end
  end

  defp extract_recommendations(issues) do
    issues
    |> Enum.filter(&(&1.severity in [:critical, :warning]))
    |> Enum.map(& &1.recommendation)
    |> Enum.uniq()
  end
end
