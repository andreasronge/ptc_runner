defmodule GitQuery.StepExecutor do
  @moduledoc """
  Executes pipeline steps using SubAgents.

  Supports single-shot and multi-step execution with dependency checking.

  Return values from steps:
  - `data` - Structured result for subsequent steps
  - `summary` - Human-readable description
  - `done` - True if this fully answers the original question
  - `status` - `:ok` | `:empty` | `:failed`
  """

  alias GitQuery.ContextSelector
  alias PtcRunner.SubAgent

  @doc """
  Execute a single step (no planning).
  """
  @spec execute_single(map(), String.t(), map(), function(), GitQuery.Config.t()) ::
          {:ok, map()} | {:error, any()}
  def execute_single(anchor, goal, tools, llm, config) do
    step = %{id: 1, goal: goal, needs: []}
    execute_step(anchor, step, %{}, tools, llm, config)
  end

  @doc """
  Execute a multi-step plan sequentially.

  Checks dependencies before each step and halts gracefully on empty results.
  """
  @spec execute_plan(map(), list(map()), map(), function(), GitQuery.Config.t()) ::
          {:ok, map()} | {:error, any()}
  def execute_plan(anchor, steps, tools, llm, config) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, results} ->
      context = ContextSelector.select(results, step.needs, config.context_mode)

      # Guard: skip if required dependencies are missing/empty
      case check_dependencies(context, step.needs) do
        :ok ->
          execute_and_continue(anchor, step, context, results, tools, llm, config)

        {:missing, keys} ->
          {:halt, {:ok, %{status: :empty, summary: "Missing data: #{inspect(keys)}"}}}
      end
    end)
  end

  @doc """
  Execute a single step with its context.
  """
  @spec execute_step(map(), map(), map(), map(), function(), GitQuery.Config.t()) ::
          {:ok, map()} | {:error, any()}
  def execute_step(anchor, step, context, tools, llm, config) do
    prompt = build_step_prompt(anchor, step, context)

    agent =
      SubAgent.new(
        prompt: prompt,
        signature:
          "(original_question :string, goal :string, data :any?, constraints :any?) -> {data :any, done :bool, summary :string, status :string?}",
        tools: tools,
        compression: true,
        max_turns: config.max_turns,
        timeout: 45_000
      )

    agent_context =
      anchor
      |> Map.merge(%{goal: step.goal, data: context})

    try do
      case SubAgent.run(agent, llm: llm, context: agent_context) do
        {:ok, result_step} ->
          {:ok, normalize_result(result_step.return)}

        {:error, error_step} ->
          {:error, error_step.fail}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # Check if all declared dependencies are present and non-empty
  defp check_dependencies(context, needs) do
    missing =
      Enum.filter(needs, fn
        {_step_id, key} ->
          value = Map.get(context, key)
          is_nil(value) or value == []

        key ->
          value = Map.get(context, key)
          is_nil(value) or value == []
      end)

    if missing == [], do: :ok, else: {:missing, missing}
  end

  defp execute_and_continue(anchor, step, context, results, tools, llm, config) do
    case execute_step(anchor, step, context, tools, llm, config) do
      {:ok, %{done: true} = result} ->
        {:halt, {:ok, result}}

      {:ok, %{status: :empty} = result} ->
        # Step found no data - halt gracefully
        {:halt, {:ok, result}}

      {:ok, result} ->
        {:cont, {:ok, Map.put(results, step.id, result.data)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp build_step_prompt(anchor, _step, context) do
    constraints_section =
      if anchor[:constraints] do
        """

        CONSTRAINTS TO RESPECT:
        {{constraints}}
        """
      else
        ""
      end

    data_section =
      if context != %{} do
        """

        AVAILABLE DATA FROM PREVIOUS STEPS:
        {{data}}
        """
      else
        ""
      end

    """
    You are a git repository analyst. Execute the goal below using the available tools.

    ORIGINAL QUESTION: {{original_question}}#{constraints_section}

    YOUR GOAL: {{goal}}#{data_section}

    Available tools and when to use them:
    - `get_commits`: Get commit history with filters (author, date, path, message grep)
    - `get_author_stats`: Get commit counts by author (best for "who contributed most")
    - `get_file_stats`: Get most frequently changed files, can filter by author
    - `get_file_history`: Get history for a specific file
    - `get_diff_stats`: Get line change statistics

    Date filters use git's date parsing: "1 month ago", "2 weeks ago", "yesterday", "2024-01-01"

    Instructions:
    - Execute the goal using the appropriate tools
    - Return `data` with structured results that subsequent steps can use
    - Return `summary` with a human-readable description of what you found
    - Set `done: true` ONLY if this fully answers the original question
    - Set `status: "empty"` if no results were found, `status: "ok"` otherwise
    """
  end

  defp normalize_result(result) do
    %{
      data: result["data"],
      done: result["done"] == true,
      summary: result["summary"],
      status: normalize_status(result["status"])
    }
  end

  defp normalize_status("empty"), do: :empty
  defp normalize_status("failed"), do: :failed
  defp normalize_status(_), do: :ok
end
