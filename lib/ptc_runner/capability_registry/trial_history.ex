defmodule PtcRunner.CapabilityRegistry.TrialHistory do
  @moduledoc """
  Records and analyzes trial outcomes for tools and skills.

  The trial history acts as "immune memory" - tracking what worked and
  what didn't to improve future capability selection.

  ## Recording Outcomes

  After plan execution, call `record_trial/2` with the execution result.
  This updates success rates for all tools and skills used.

  ## Learning

  Trial history enables:

  - Context-specific success rates (tools work better in some contexts)
  - Model-specific skill effectiveness
  - Warning detection for low-performing capabilities
  - Trigger for repairs when consistent failures occur

  """

  alias PtcRunner.CapabilityRegistry.{Registry, Skill, ToolEntry}

  @type trial_outcome :: %{
          tools_used: [String.t()],
          skills_used: [String.t()],
          context_tags: [String.t()],
          model_id: String.t() | nil,
          success: boolean(),
          failure_diagnosis: String.t() | nil
        }

  @type plan_result :: %{
          optional(:outcomes) => %{String.t() => :success | {:error, term()}},
          optional(:tools_used) => [String.t()],
          optional(:skills_used) => [String.t()],
          optional(:context_tags) => [String.t()],
          optional(:model_id) => String.t(),
          optional(:diagnosis) => String.t()
        }

  @doc """
  Records trial outcomes for all tools and skills used in a plan execution.

  Updates success rates and context-specific statistics for each capability.

  ## Example

      result = %{
        outcomes: %{"task1" => :success, "task2" => {:error, "failed"}},
        tools_used: ["search", "parse"],
        skills_used: ["csv_tips"],
        context_tags: ["european", "csv"],
        model_id: "claude-3"
      }

      registry = TrialHistory.record_trial(registry, result)

  """
  @spec record_trial(Registry.t(), plan_result()) :: Registry.t()
  def record_trial(registry, result) do
    tools_used = Map.get(result, :tools_used, [])
    skills_used = Map.get(result, :skills_used, [])
    context_tags = Map.get(result, :context_tags, [])
    model_id = Map.get(result, :model_id)

    # Determine overall success
    success = determine_success(result)

    # Update tool statistics
    registry =
      Enum.reduce(tools_used, registry, fn tool_id, acc ->
        Registry.record_trial(acc, tool_id, context_tags, success)
      end)

    # Update skill statistics
    registry =
      Enum.reduce(skills_used, registry, fn skill_id, acc ->
        Registry.record_skill_trial(acc, skill_id, context_tags, model_id, success)
      end)

    registry
  end

  @doc """
  Updates statistics for a specific tool after a trial.
  """
  @spec update_tool_statistics(Registry.t(), String.t(), trial_outcome()) :: Registry.t()
  def update_tool_statistics(registry, tool_id, outcome) do
    case Registry.get_tool(registry, tool_id) do
      nil ->
        registry

      tool ->
        updated =
          tool
          |> ToolEntry.update_success_rate(outcome.success)
          |> then(fn t ->
            Enum.reduce(outcome.context_tags, t, fn tag, acc ->
              ToolEntry.update_context_success(acc, tag, outcome.success)
            end)
          end)

        %{registry | tools: Map.put(registry.tools, tool_id, updated)}
    end
  end

  @doc """
  Updates statistics for a specific skill after a trial.
  """
  @spec update_skill_statistics(Registry.t(), String.t(), trial_outcome()) :: Registry.t()
  def update_skill_statistics(registry, skill_id, outcome) do
    case Registry.get_skill(registry, skill_id) do
      nil ->
        registry

      skill ->
        updated =
          skill
          |> Skill.update_success_rate(outcome.success)
          |> then(fn s ->
            if outcome.model_id do
              Skill.update_model_success(s, outcome.model_id, outcome.success)
            else
              s
            end
          end)
          |> then(fn s ->
            Enum.reduce(outcome.context_tags, s, fn tag, acc ->
              Skill.update_context_success(acc, tag, outcome.success)
            end)
          end)

        %{registry | skills: Map.put(registry.skills, skill_id, updated)}
    end
  end

  @doc """
  Gets warnings for tools with low success rates in given context.

  Returns tools that have < 30% success rate for any of the context tags.
  """
  @spec get_context_warnings(Registry.t(), [String.t()]) ::
          [%{tool_id: String.t(), tag: String.t(), rate: float()}]
  def get_context_warnings(registry, context_tags) do
    threshold = 0.3

    registry
    |> Registry.list_tools()
    |> Enum.flat_map(fn tool ->
      context_tags
      |> Enum.filter(fn tag ->
        rate = Map.get(tool.context_success, tag, 1.0)
        rate < threshold
      end)
      |> Enum.map(fn tag ->
        %{
          tool_id: tool.id,
          tag: tag,
          rate: Map.get(tool.context_success, tag, 1.0)
        }
      end)
    end)
  end

  @doc """
  Gets tools that may need repair based on consistent failures.

  Returns tools with overall success rate below threshold.
  """
  @spec get_repair_candidates(Registry.t(), keyword()) :: [ToolEntry.t()]
  def get_repair_candidates(registry, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.5)
    min_trials = Keyword.get(opts, :min_trials, 10)

    registry
    |> Registry.list_tools()
    |> Enum.filter(fn tool ->
      # Only consider tools with enough history
      tool.link_count >= min_trials and
        tool.success_rate < threshold
    end)
    |> Enum.sort_by(& &1.success_rate)
  end

  @doc """
  Gets skills that may be ineffective for a specific model.

  Returns skills with low effectiveness for the given model.
  """
  @spec get_model_warnings(Registry.t(), String.t(), keyword()) :: [Skill.t()]
  def get_model_warnings(registry, model_id, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 0.5)

    registry
    |> Registry.list_skills()
    |> Enum.filter(fn skill ->
      effectiveness = Skill.effectiveness_for_model(skill, model_id)
      effectiveness < threshold
    end)
    |> Enum.sort_by(&Skill.effectiveness_for_model(&1, model_id))
  end

  @doc """
  Computes aggregate statistics for the registry.
  """
  @spec aggregate_statistics(Registry.t()) :: %{
          tool_count: non_neg_integer(),
          skill_count: non_neg_integer(),
          avg_tool_success: float(),
          avg_skill_success: float(),
          total_trials: non_neg_integer(),
          healthy_tools: non_neg_integer(),
          unhealthy_tools: non_neg_integer()
        }
  def aggregate_statistics(registry) do
    tools = Registry.list_tools(registry)
    skills = Registry.list_skills(registry)

    tool_success_rates = Enum.map(tools, & &1.success_rate)
    skill_success_rates = Enum.map(skills, & &1.success_rate)

    healthy =
      registry.health
      |> Enum.count(fn {_, status} -> status == :green end)

    unhealthy =
      registry.health
      |> Enum.count(fn {_, status} -> status == :red end)

    %{
      tool_count: length(tools),
      skill_count: length(skills),
      avg_tool_success: safe_average(tool_success_rates),
      avg_skill_success: safe_average(skill_success_rates),
      total_trials: length(registry.history),
      healthy_tools: healthy,
      unhealthy_tools: unhealthy
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp determine_success(%{outcomes: outcomes}) when is_map(outcomes) do
    # Success if all outcomes succeeded
    outcomes
    |> Enum.all?(fn
      {_, :success} -> true
      {_, {:error, _}} -> false
      {_, _} -> true
    end)
  end

  defp determine_success(%{success: success}), do: success
  defp determine_success(_), do: true

  defp safe_average([]), do: 0.0
  defp safe_average(list), do: Enum.sum(list) / length(list)
end
