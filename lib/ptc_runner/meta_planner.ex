defmodule PtcRunner.MetaPlanner do
  @moduledoc """
  Generate and repair execution plans for multi-agent workflows.

  The MetaPlanner is responsible for:
  - Generating initial plans from mission descriptions
  - Repairing plans when tasks fail with `:replan` strategy

  ## Initial Planning

  Generate a plan from a natural language mission:

      {:ok, plan} = MetaPlanner.plan("Research AAPL stock price and write a summary",
        llm: my_llm,
        available_tools: %{
          "search" => "Search the web for information",
          "fetch_price" => "Fetch current stock price for a symbol. Returns {price, currency}",
          "summarize" => "Summarize a list of documents into key points"
        }
      )

  ## Replanning (Tail Repair)

  When a task fails verification with `on_verification_failure: :replan`,
  the MetaPlanner generates a "repair plan" that:

  1. Preserves completed task IDs (so PlanRunner skips them)
  2. Redesigns the failed task based on the diagnosis
  3. May restructure downstream tasks

  Example:

      # Original execution failed at task "fetch_prices"
      failure_context = %{
        task_id: "fetch_prices",
        task_output: %{"prices" => []},
        diagnosis: "Expected at least 5 price entries, got 0"
      }

      {:ok, repair_plan} = MetaPlanner.replan(
        "Compare stock prices for AAPL, GOOGL, MSFT",
        %{"fetch_symbols" => ["AAPL", "GOOGL", "MSFT"]},
        failure_context,
        llm: my_llm
      )

      # Execute repair plan with initial_results to skip completed tasks
      PlanRunner.execute(repair_plan,
        llm: my_llm,
        initial_results: %{"fetch_symbols" => ["AAPL", "GOOGL", "MSFT"]}
      )

  """

  alias PtcRunner.Plan
  alias PtcRunner.Prompts
  alias PtcRunner.SubAgent

  require Logger

  @type tool_descriptions :: %{String.t() => String.t()}

  @type failure_context :: %{
          task_id: String.t(),
          task_output: term(),
          diagnosis: String.t()
        }

  # ============================================================================
  # Initial Planning
  # ============================================================================

  @doc """
  Generate an execution plan from a natural language mission.

  Takes a mission description and available tools, then generates a structured
  plan that can be executed by PlanRunner.

  ## Parameters

  - `mission` - Natural language description of what to accomplish
  - `opts` - Options including `:llm` callback (required)

  ## Options

  - `llm` - Required. LLM callback function
  - `available_tools` - Map of tool_name => description (recommended)
  - `timeout` - Timeout for plan generation (default: 30_000)
  - `constraints` - Optional string with additional constraints or guidelines
  - `validation_errors` - Optional. List of validation issues from a previous attempt (for self-correction)

  ## Returns

  - `{:ok, plan}` - Parsed execution plan
  - `{:error, reason}` - Generation or parsing failed

  ## Example

      {:ok, plan} = MetaPlanner.plan("Research AAPL stock and summarize findings",
        llm: my_llm,
        available_tools: %{
          "search" => "Search the web. Input: query string. Output: list of results",
          "fetch_price" => "Get stock price. Input: symbol. Output: {price, change}",
          "summarize" => "Summarize text. Input: text. Output: summary string"
        }
      )

  """
  @spec plan(String.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(mission, opts) do
    llm = Keyword.fetch!(opts, :llm)
    timeout = Keyword.get(opts, :timeout, 30_000)
    available_tools = Keyword.get(opts, :available_tools, %{})
    constraints = Keyword.get(opts, :constraints)
    validation_errors = Keyword.get(opts, :validation_errors)

    prompt = build_plan_prompt(mission, available_tools, constraints, validation_errors)

    agent =
      SubAgent.new(
        prompt: prompt,
        signature: ":map",
        output: :json,
        schema: plan_schema(),
        max_turns: 1,
        retry_turns: 2,
        timeout: timeout,
        system_prompt: %{
          # Disable default PTC-Lisp reference - we're generating JSON, not Lisp programs.
          # The verification predicate syntax is included in the suffix.
          language_spec: "",
          output_format: "",
          prefix:
            "You are a workflow architect. Design execution plans for multi-agent workflows.\n\n",
          suffix:
            "\n\n#{Prompts.signature_guide()}\n\n#{Prompts.verification_guide()}\n\n#{Prompts.planning_examples()}"
        }
      )

    Logger.info("MetaPlanner: Generating plan for mission: #{String.slice(mission, 0, 100)}")

    case SubAgent.run(agent, llm: llm) do
      {:ok, step} ->
        raw_plan = step.return
        Logger.debug("MetaPlanner: Raw plan: #{inspect(raw_plan, limit: 200)}")

        case Plan.parse(raw_plan) do
          {:ok, plan} ->
            Logger.info("MetaPlanner: Plan generated with #{length(plan.tasks)} task(s)")
            {:ok, plan}

          {:error, reason} ->
            Logger.error("MetaPlanner: Failed to parse plan: #{inspect(reason)}")
            {:error, {:parse_error, reason}}
        end

      {:error, step} ->
        Logger.error("MetaPlanner: Failed to generate plan: #{inspect(step.fail)}")
        {:error, {:generation_error, step.fail}}
    end
  end

  defp build_plan_prompt(mission, available_tools, constraints, validation_errors) do
    tools_section = format_available_tools(available_tools)
    constraints_section = format_constraints(constraints)
    validation_section = format_validation_errors(validation_errors)

    """
    ## Mission
    #{mission}
    #{tools_section}#{constraints_section}#{validation_section}
    ## Plan Design Guidelines

    1. **Decompose first** - before creating tasks, work backwards from the desired outcome:
       - What intermediate results must be produced to accomplish this mission?
       - Does the mission require any computations, comparisons, or derived values?
       - For each intermediate result, what specific inputs are needed?
       Then create tasks that produce each required intermediate result.
    2. **Use appropriate tools** - only reference tools from the available list
    3. **Define dependencies** - tasks that need results from other tasks should declare depends_on
    4. **Add verification** - include predicates to validate task outputs (see system prompt for syntax)
    5. **Keep it simple** - prefer fewer, well-defined tasks over many small ones
    6. **Create computation agents when needed** - if the mission requires calculations, derived metrics,
       or data transformations, create a dedicated agent with no tools and a precise signature for that step.
       Don't bury computation inside synthesis — make it an explicit task with typed inputs and outputs.
       IMPORTANT: Set `"output": "ptc_lisp"` on computation tasks. This makes the agent write executable
       PTC-Lisp programs with verified arithmetic instead of computing values mentally. Their prompt should
       instruct them to extract values into `let` bindings and use arithmetic expressions (`/`, `*`, `+`, `-`).
       PTC-Lisp also supports conditionals, string operations, and collection functions (`map`, `filter`,
       `reduce`, `sort-by`) for data transformations.

    ## Task Types

    - **Regular tasks**: Use an agent with tools to accomplish work
    - **Synthesis gates**: Compress/summarize results from multiple upstream tasks (type: "synthesis_gate")
      When designing a synthesis_gate, you MUST specify a `signature` that defines the exact output structure
      (e.g., `"{stocks [{symbol :string, price :float, currency :string}]}"`). This ensures machine-readable results.

    ## Output Format

    Return a JSON plan:
    ```json
    {
      "tasks": [
        {
          "id": "unique_task_id",
          "agent": "agent_name",
          "input": "What this task should accomplish",
          "depends_on": ["ids_of_upstream_tasks"],
          "output": "ptc_lisp or json (optional, auto-detects if omitted)",
          "signature": "{field :type}",
          "verification": "(optional PTC-Lisp predicate)",
          "on_verification_failure": "retry"
        }
      ],
      "agents": {
        "agent_name": {
          "prompt": "You are an agent that...",
          "tools": ["tool_names_from_available_list"]
        }
      }
    }
    ```

    ## Important Rules

    - Task IDs must be unique and descriptive (e.g., "fetch_prices", "compute_ratio", "summarize_research")
    - Only reference tools that are in the available tools list
    - Set `"output": "ptc_lisp"` on computation tasks (arithmetic, ratios, aggregations) so the interpreter
      verifies the math. Omit `output` for tasks with tools (auto-detects to ptc_lisp) or pure Q&A/synthesis
      (auto-detects to json).
    - Computation agents receive upstream task results as context and produce PTC-Lisp programs.
      Always give these agents a precise signature (e.g., `"{ratio :float, interpretation :string}"`).
      Their prompt should instruct them to use `let` bindings and arithmetic expressions for calculations
    - Use `on_verification_failure: "replan"` for critical tasks that may need strategy changes

    Generate the execution plan now:
    """
  end

  defp format_available_tools(tools) when map_size(tools) == 0 do
    """

    ## Available Tools
    No external tools available. Tasks will process data and produce results via LLM.
    """
  end

  defp format_available_tools(tools) do
    tool_list =
      Enum.map_join(tools, "\n", fn {name, description} ->
        "- **#{name}**: #{description}"
      end)

    """

    ## Available Tools
    #{tool_list}
    """
  end

  defp format_constraints(nil), do: ""

  defp format_constraints(constraints) do
    """

    ## Additional Constraints
    #{constraints}
    """
  end

  # JSON Schema for plan structure - helps LLMs generate valid plans
  defp plan_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tasks" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string", "description" => "Unique task identifier"},
              "agent" => %{"type" => "string", "description" => "Agent to execute the task"},
              "input" => %{"type" => "string", "description" => "Task description/instructions"},
              "depends_on" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "IDs of tasks this depends on"
              },
              "verification" => %{
                "type" => "string",
                "description" => "PTC-Lisp predicate to verify output"
              },
              "on_verification_failure" => %{
                "type" => "string",
                "enum" => ["retry", "replan", "fail"],
                "description" => "Action on verification failure"
              },
              "type" => %{
                "type" => "string",
                "description" => "Task type (e.g., synthesis_gate)"
              },
              "output" => %{
                "type" => "string",
                "enum" => ["ptc_lisp", "json"],
                "description" =>
                  "Execution mode: ptc_lisp for computation tasks (verified arithmetic), json for Q&A/synthesis. Default: auto-detect (tools → ptc_lisp, no tools → json)"
              },
              "signature" => %{
                "type" => "string",
                "description" => "Output signature for JSON mode (REQUIRED for synthesis_gate)"
              }
            },
            "required" => ["id", "input"]
          },
          "description" => "List of tasks to execute"
        },
        "agents" => %{
          "type" => "object",
          "additionalProperties" => %{
            "type" => "object",
            "properties" => %{
              "prompt" => %{"type" => "string", "description" => "System prompt for the agent"},
              "tools" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "Tool names available to this agent"
              }
            }
          },
          "description" => "Agent definitions keyed by agent name"
        }
      },
      "required" => ["tasks"]
    }
  end

  # ============================================================================
  # Replanning (Tail Repair)
  # ============================================================================

  @doc """
  Generate a repair plan after a task fails verification.

  The repair plan includes all task IDs (including completed ones) so that
  PlanRunner can use the `initial_results` option to skip already-completed tasks.

  ## Parameters

  - `mission` - Original mission description
  - `completed_results` - Map of task_id => result for successful tasks
  - `failure_context` - Details about the failed task
  - `opts` - Options including `:llm` callback (required)

  ## Options

  - `llm` - Required. LLM callback function
  - `timeout` - Timeout for plan generation (default: 30_000)
  - `original_plan` - Optional. The original plan that failed (for context)
  - `constraints` - Optional. Planning constraints to preserve during replanning
  - `validation_errors` - Optional. List of validation issues from a previous repair attempt

  ## Returns

  - `{:ok, plan}` - Parsed repair plan
  - `{:error, reason}` - Generation or parsing failed

  """
  @spec replan(String.t(), map(), failure_context(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def replan(mission, completed_results, failure_context, opts) do
    llm = Keyword.fetch!(opts, :llm)
    timeout = Keyword.get(opts, :timeout, 30_000)
    original_plan = Keyword.get(opts, :original_plan)
    constraints = Keyword.get(opts, :constraints)
    validation_errors = Keyword.get(opts, :validation_errors)
    trial_history = Keyword.get(opts, :trial_history, [])

    # Build the healer prompt
    prompt =
      build_replan_prompt(
        mission,
        completed_results,
        failure_context,
        original_plan,
        constraints,
        validation_errors,
        trial_history
      )

    # Create a SubAgent to generate the repair plan
    # Use condensed reminder since LLM likely saw full guide in initial plan
    agent =
      SubAgent.new(
        prompt: prompt,
        signature: ":map",
        output: :json,
        schema: plan_schema(),
        max_turns: 1,
        retry_turns: 2,
        timeout: timeout,
        system_prompt: %{
          # Disable default PTC-Lisp reference - we're generating JSON, not Lisp programs
          language_spec: "",
          output_format: "",
          prefix: "You are a workflow repair specialist. Fix failed multi-agent plans.\n\n",
          suffix: "\n\n#{Prompts.signature_guide()}\n\n#{Prompts.verification_reminder()}"
        }
      )

    Logger.info(
      "MetaPlanner: Generating repair plan for failed task '#{failure_context.task_id}'"
    )

    case SubAgent.run(agent, llm: llm) do
      {:ok, step} ->
        raw_plan = step.return
        Logger.debug("MetaPlanner: Raw repair plan: #{inspect(raw_plan, limit: 200)}")

        case Plan.parse(raw_plan) do
          {:ok, plan} ->
            Logger.info("MetaPlanner: Repair plan generated with #{length(plan.tasks)} task(s)")

            {:ok, plan}

          {:error, reason} ->
            Logger.error("MetaPlanner: Failed to parse repair plan: #{inspect(reason)}")
            {:error, {:parse_error, reason}}
        end

      {:error, step} ->
        Logger.error("MetaPlanner: Failed to generate repair plan: #{inspect(step.fail)}")
        {:error, {:generation_error, step.fail}}
    end
  end

  defp build_replan_prompt(
         mission,
         completed_results,
         failure_context,
         original_plan,
         constraints,
         validation_errors,
         trial_history
       ) do
    completed_summary = format_completed_results(completed_results)
    original_plan_section = format_original_plan(original_plan)
    constraints_section = format_constraints(constraints)
    validation_section = format_validation_errors(validation_errors)
    trial_history_section = format_trial_history(trial_history)

    """
    You are a workflow repair specialist. A multi-agent plan has failed and needs to be fixed.

    ## Original Mission
    #{mission}
    #{constraints_section}
    ## What Has Already Succeeded
    The following tasks completed successfully. Keep their exact IDs in your repair plan
    so they can be reused (the executor will skip them automatically):

    #{completed_summary}

    ## What Failed
    Task ID: #{failure_context.task_id}
    Task Output: #{format_value(failure_context.task_output)}
    Failure Diagnosis: "#{failure_context.diagnosis}"
    #{original_plan_section}#{trial_history_section}#{validation_section}
    ## Your Task

    Generate a REPAIR PLAN that:

    1. **Preserves successful work**: Include tasks with the same IDs as the completed tasks above.
       These will be automatically skipped during execution.

    2. **Fixes the failed task**: The task "#{failure_context.task_id}" failed because:
       "#{failure_context.diagnosis}"
       Redesign this task or replace it with a different approach.

    3. **Completes the mission**: Ensure downstream tasks can still accomplish the original goal.

    ## Important Guidelines

    - DO NOT change the IDs of successful tasks (they need to match for skip-if-present)
    - DO change the failed task's approach based on the diagnosis
    - You MAY add new tasks if a different strategy is needed
    - You MAY remove or restructure downstream tasks if they depend on the failed approach
    - Include verification predicates to prevent the same failure (see system prompt for syntax)

    ## Impossible Missions

    If the mission objective is impossible or the failure diagnosis indicates a non-recoverable
    error (e.g., requested resource doesn't exist, invalid credentials, impossible constraints),
    return a plan with a single task:
    ```json
    {
      "tasks": [{"id": "mission_impossible", "input": "Explain why the mission cannot be completed"}],
      "agents": {}
    }
    ```

    ## Output Format

    Return a JSON plan:
    ```json
    {
      "tasks": [
        {
          "id": "task_id",
          "agent": "agent_type",
          "input": "task description",
          "depends_on": ["dependency_ids"],
          "output": "ptc_lisp or json (optional, for computation tasks use ptc_lisp)",
          "signature": "{field :type}",
          "verification": "(optional Lisp predicate)",
          "on_verification_failure": "retry"
        }
      ],
      "agents": {
        "agent_type": {
          "prompt": "agent system prompt",
          "tools": ["tool_names"]
        }
      }
    }
    ```

    Generate the repair plan now:
    """
  end

  defp format_validation_errors(nil), do: ""
  defp format_validation_errors([]), do: ""

  defp format_validation_errors(errors) do
    error_list =
      Enum.map_join(errors, "\n", fn issue ->
        "- [#{issue.category}] #{issue.message}"
      end)

    """

    ## CRITICAL: Previous Plan Had Validation Errors

    Your previous plan was rejected because it had structural problems.
    You MUST fix these issues in your new plan:

    #{error_list}

    Pay close attention to:
    - Circular dependencies (task A depends on B, B depends on A)
    - Missing dependencies (referencing task IDs that don't exist)
    - Missing agents (using agent names not defined in the agents section)
    - Duplicate task IDs

    """
  end

  defp format_completed_results(results) when map_size(results) == 0 do
    "(No tasks completed yet)"
  end

  defp format_completed_results(results) do
    Enum.map_join(results, "\n", fn {task_id, value} ->
      formatted_value = format_value(value)
      "- Task '#{task_id}': #{String.slice(formatted_value, 0, 200)}"
    end)
  end

  defp format_original_plan(nil), do: ""

  defp format_original_plan(%Plan{} = plan) do
    task_summaries =
      Enum.map_join(plan.tasks, "\n", fn task ->
        deps =
          if task.depends_on == [],
            do: "",
            else: " (depends: #{Enum.join(task.depends_on, ", ")})"

        "  - #{task.id}: #{String.slice(to_string(task.input), 0, 50)}#{deps}"
      end)

    """

    ## Original Plan Structure (for reference)
    #{task_summaries}
    """
  end

  defp format_original_plan(_), do: ""

  defp format_value(value) when is_binary(value), do: value

  defp format_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  # ============================================================================
  # Trial History Formatting
  # ============================================================================

  @doc """
  Format trial history for inclusion in the replan prompt.

  Returns an empty string for empty history, otherwise formats each attempt
  with approach, output, and diagnosis details plus a self-reflection section.
  """
  @spec format_trial_history([map()]) :: String.t()
  def format_trial_history([]), do: ""

  def format_trial_history(history) when is_list(history) do
    attempts = Enum.map_join(history, "\n---\n\n", &format_attempt/1)

    """

    ## Trial & Error History

    The following attempts have already been made to complete this mission.
    DO NOT repeat these failed approaches.

    #{attempts}

    ## Self-Reflection Required

    Before generating your repair plan, analyze the trial history above:

    1. **Pattern Recognition**: Are the same errors recurring?
    2. **Root Cause Analysis**: Is it a tool limitation, bad input, or impossible task?
    3. **Strategy Shift**: How should the approach fundamentally change?

    Your repair plan MUST address the root cause, not just retry with minor changes.
    """
  end

  defp format_attempt(%{attempt: attempt, task_id: task_id} = record) do
    approach = Map.get(record, :approach, "(not recorded)")
    output = Map.get(record, :output, "(not recorded)")
    diagnosis = Map.get(record, :diagnosis, "(not recorded)")

    """
    ### Attempt #{attempt} - Task "#{task_id}"
    **Approach:**
    ```
    #{approach}
    ```
    **Output:**
    ```
    #{output}
    ```
    **Failure Diagnosis:** "#{diagnosis}"
    """
  end
end
