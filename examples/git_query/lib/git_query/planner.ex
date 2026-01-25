defmodule GitQuery.Planner do
  @moduledoc """
  Decides whether to execute single-shot or create a multi-step plan.

  Planning modes:
  - `:never` - Always single-shot execution
  - `:always` - Always create a multi-step plan
  - `:auto` - LLM decides based on query complexity
  """

  alias PtcRunner.SubAgent

  @doc """
  Decide whether to plan based on configuration.

  ## Parameters

  - `question` - The user's question
  - `tools` - Available tools map
  - `llm` - LLM function
  - `config` - Pipeline configuration

  ## Returns

  - `{:single, goal}` - Execute as single step with this goal
  - `{:planned, steps}` - Execute as multi-step plan
  """
  @spec maybe_plan(String.t(), map(), function(), GitQuery.Config.t()) ::
          {:single, String.t()} | {:planned, list(map())}
  def maybe_plan(question, _tools, _llm, %{planning: :never}) do
    {:single, question}
  end

  def maybe_plan(question, tools, llm, %{planning: :always}) do
    # plan_steps already returns {:planned, steps}
    plan_steps(question, tools, llm, force_multi: true)
  end

  def maybe_plan(question, tools, llm, %{planning: :auto}) do
    plan_steps(question, tools, llm, force_multi: false)
  end

  # Consolidated planning function
  defp plan_steps(question, tools, llm, opts) do
    force_multi = Keyword.get(opts, :force_multi, false)
    tool_names = tools |> Map.keys() |> Enum.join(", ")

    prompt =
      if force_multi do
        """
        Question: {{question}}
        Available tools: {{tool_names}}

        Create a step-by-step plan. For each step:
        - id: sequential number starting at 1
        - goal: what this step accomplishes
        - needs: list of dependencies from previous steps as [step_id, key] pairs

        Keep plans minimal. Most queries need 1-3 steps.
        Use unique key names to avoid ambiguity.

        Example for "most active contributor's commits last week":
        [
          {"id": 1, "goal": "find most active contributor last week", "needs": []},
          {"id": 2, "goal": "get their commits from last week", "needs": [[1, "contributor"]]}
        ]
        """
      else
        """
        Question: {{question}}
        Available tools: {{tool_names}}

        Decide: can this be answered in ONE tool call, or does it need multiple steps?

        Examples of SINGLE queries:
        - "commits from last week" -> single (one get_commits call)
        - "most active contributor" -> single (one get_author_stats call)
        - "files changed by alice" -> single (one get_file_stats call)

        Examples of MULTI queries:
        - "most active contributor's commits" -> multi (need contributor first, then their commits)
        - "interesting commits from the top contributor" -> multi (need to identify who, then get their commits)

        If single, just set mode to "single" and provide the goal.
        If multi, set mode to "multi" and create a plan with steps.
        """
      end

    # Use simplified signature - `:any` for complex nested structures
    signature =
      if force_multi do
        "(question :string, tool_names :string) -> {steps :any}"
      else
        "(question :string, tool_names :string) -> {mode :string, goal :string?, steps :any?}"
      end

    agent =
      SubAgent.new(
        prompt: prompt,
        signature: signature,
        output: :json,
        max_turns: 1,
        timeout: 15_000
      )

    case SubAgent.run(agent, llm: llm, context: %{question: question, tool_names: tool_names}) do
      {:ok, step} ->
        if force_multi do
          {:planned, normalize_steps(step.return["steps"] || [])}
        else
          case step.return["mode"] do
            "single" ->
              {:single, step.return["goal"] || question}

            "multi" ->
              {:planned, normalize_steps(step.return["steps"] || [])}

            _ ->
              # Fallback to single if mode is unexpected
              {:single, question}
          end
        end

      {:error, _step} ->
        # On planning failure, fall back to single-shot
        {:single, question}
    end
  end

  # Normalize steps to have consistent structure
  defp normalize_steps(steps) do
    Enum.map(steps, fn step ->
      %{
        id: step["id"],
        goal: step["goal"],
        needs: normalize_needs(step["needs"] || [])
      }
    end)
  end

  # Convert needs from [[step_id, key], ...] to [{step_id, key}, ...]
  # Keys are kept as strings (not atoms) to avoid atom table exhaustion
  # from LLM-generated content, and to match JSON data keys.
  defp normalize_needs(needs) do
    Enum.map(needs, fn
      [step_id, key] when is_integer(step_id) and is_binary(key) ->
        {step_id, key}

      {step_id, key} ->
        {step_id, key}

      other ->
        other
    end)
  end
end
