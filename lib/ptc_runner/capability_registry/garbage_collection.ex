defmodule PtcRunner.CapabilityRegistry.GarbageCollection do
  @moduledoc """
  Least Recently Linked (LRL) garbage collection strategy.

  Identifies tools and skills that haven't been used and don't provide
  unique value, allowing them to be archived to reduce registry size.

  ## Archive Criteria

  A capability is a candidate for archival if:

  1. Not linked in the last N missions (mission threshold)
  2. Does not have unique test coverage (for tools)
  3. Is not the only implementation of a capability

  ## Archive vs Delete

  Archived items are moved to cold storage, not deleted. They can be
  restored if needed.

  """

  alias PtcRunner.CapabilityRegistry.{Registry, Verification}

  @default_link_age_days 90

  @type archive_candidate :: %{
          id: String.t(),
          type: :tool | :skill,
          reason: String.t(),
          last_linked_at: DateTime.t() | nil,
          link_count: non_neg_integer()
        }

  @doc """
  Finds tools that are candidates for archival.

  ## Options

  - `:mission_threshold` - Minimum missions since last link (default: 1000)
  - `:link_age_days` - Days since last link to consider stale (default: 90)
  - `:check_unique_coverage` - Whether to preserve tools with unique test coverage

  """
  @spec archive_tool_candidates(Registry.t(), keyword()) :: [archive_candidate()]
  def archive_tool_candidates(registry, opts \\ []) do
    link_age_days = Keyword.get(opts, :link_age_days, @default_link_age_days)
    check_unique = Keyword.get(opts, :check_unique_coverage, true)

    cutoff = DateTime.add(DateTime.utc_now(), -link_age_days, :day)

    registry
    |> Registry.list_tools()
    |> Enum.filter(fn tool ->
      stale?(tool, cutoff) and
        not sole_implementation?(registry, tool) and
        (not check_unique or not has_unique_test_coverage?(registry, tool))
    end)
    |> Enum.map(fn tool ->
      %{
        id: tool.id,
        type: :tool,
        reason: archive_reason(tool, cutoff),
        last_linked_at: tool.last_linked_at,
        link_count: tool.link_count
      }
    end)
  end

  @doc """
  Finds skills that are candidates for archival.

  ## Options

  - `:link_age_days` - Days since last link to consider stale (default: 90)
  - `:min_success_rate` - Skills below this rate are candidates (default: 0.3)

  """
  @spec archive_skill_candidates(Registry.t(), keyword()) :: [archive_candidate()]
  def archive_skill_candidates(registry, opts \\ []) do
    link_age_days = Keyword.get(opts, :link_age_days, @default_link_age_days)
    min_success = Keyword.get(opts, :min_success_rate, 0.3)

    cutoff = DateTime.add(DateTime.utc_now(), -link_age_days, :day)

    registry
    |> Registry.list_skills()
    |> Enum.filter(fn skill ->
      stale?(skill, cutoff) or skill.success_rate < min_success
    end)
    |> Enum.map(fn skill ->
      reason =
        cond do
          skill.success_rate < min_success ->
            "Low success rate: #{round(skill.success_rate * 100)}%"

          stale?(skill, cutoff) ->
            archive_reason(skill, cutoff)

          true ->
            "Unknown"
        end

      %{
        id: skill.id,
        type: :skill,
        reason: reason,
        last_linked_at: skill.last_linked_at,
        link_count: skill.link_count
      }
    end)
  end

  @doc """
  Archives all candidates returned by `archive_tool_candidates/2`.

  Returns the updated registry and list of archived IDs.
  """
  @spec archive_stale_tools(Registry.t(), keyword()) :: {Registry.t(), [String.t()]}
  def archive_stale_tools(registry, opts \\ []) do
    candidates = archive_tool_candidates(registry, opts)

    {updated, archived} =
      Enum.reduce(candidates, {registry, []}, fn candidate, {reg, ids} ->
        updated = Registry.archive_tool(reg, candidate.id, candidate.reason)
        {updated, [candidate.id | ids]}
      end)

    {updated, Enum.reverse(archived)}
  end

  @doc """
  Archives all candidates returned by `archive_skill_candidates/2`.

  Returns the updated registry and list of archived IDs.
  """
  @spec archive_stale_skills(Registry.t(), keyword()) :: {Registry.t(), [String.t()]}
  def archive_stale_skills(registry, opts \\ []) do
    candidates = archive_skill_candidates(registry, opts)

    {updated, archived} =
      Enum.reduce(candidates, {registry, []}, fn candidate, {reg, ids} ->
        updated = Registry.archive_skill(reg, candidate.id, candidate.reason)
        {updated, [candidate.id | ids]}
      end)

    {updated, Enum.reverse(archived)}
  end

  @doc """
  Runs full garbage collection cycle.

  Returns the updated registry and summary of what was archived.
  """
  @spec run(Registry.t(), keyword()) ::
          {:ok,
           %{
             registry: Registry.t(),
             archived_tools: [String.t()],
             archived_skills: [String.t()]
           }}
  def run(registry, opts \\ []) do
    {reg1, tools} = archive_stale_tools(registry, opts)
    {reg2, skills} = archive_stale_skills(reg1, opts)

    {:ok,
     %{
       registry: reg2,
       archived_tools: tools,
       archived_skills: skills
     }}
  end

  @doc """
  Gets statistics about potential garbage collection.

  Useful for previewing what would be archived.
  """
  @spec preview(Registry.t(), keyword()) :: %{
          tool_candidates: non_neg_integer(),
          skill_candidates: non_neg_integer(),
          tools: [archive_candidate()],
          skills: [archive_candidate()]
        }
  def preview(registry, opts \\ []) do
    tools = archive_tool_candidates(registry, opts)
    skills = archive_skill_candidates(registry, opts)

    %{
      tool_candidates: length(tools),
      skill_candidates: length(skills),
      tools: tools,
      skills: skills
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp stale?(item, cutoff) do
    case item.last_linked_at do
      nil -> true
      dt -> DateTime.compare(dt, cutoff) == :lt
    end
  end

  defp archive_reason(item, cutoff) do
    case item.last_linked_at do
      nil ->
        "Never linked"

      dt ->
        days_ago = DateTime.diff(DateTime.utc_now(), dt, :day)

        "Not linked in #{days_ago} days (threshold: #{DateTime.diff(DateTime.utc_now(), cutoff, :day)} days)"
    end
  end

  defp sole_implementation?(registry, tool) do
    case tool.capability_id do
      nil ->
        false

      cap_id ->
        case Registry.get_capability(registry, cap_id) do
          nil -> false
          cap -> length(cap.implementations) <= 1
        end
    end
  end

  defp has_unique_test_coverage?(registry, tool) do
    # Check if this tool passes tests that no sibling implementation passes
    suite = Verification.get_suite(registry, tool.id)

    cond do
      suite == nil or suite.cases == [] ->
        false

      tool.capability_id == nil ->
        # No capability, can't have siblings
        false

      true ->
        check_unique_coverage_against_siblings(registry, tool, suite)
    end
  end

  defp check_unique_coverage_against_siblings(registry, tool, suite) do
    case Registry.get_capability(registry, tool.capability_id) do
      nil ->
        false

      cap ->
        siblings = Enum.reject(cap.implementations, &(&1 == tool.id))

        # Only implementation - keep it
        siblings == [] or has_exclusive_test_pass?(registry, tool.id, siblings, suite.cases)
    end
  end

  defp has_exclusive_test_pass?(registry, tool_id, siblings, test_cases) do
    # Check if any test case passes only for this tool
    Enum.any?(test_cases, fn test_case ->
      tool_passes = test_passes?(registry, tool_id, test_case)
      sibling_passes = Enum.any?(siblings, &test_passes?(registry, &1, test_case))
      tool_passes and not sibling_passes
    end)
  end

  defp test_passes?(registry, tool_id, test_case) do
    case Registry.get_tool(registry, tool_id) do
      nil ->
        false

      %{layer: :base, function: function} when not is_nil(function) ->
        try do
          result = function.(test_case.input)

          case test_case.expected do
            :should_not_crash -> true
            expected -> result == expected
          end
        rescue
          _ -> false
        end

      _ ->
        # Can't easily test composed tools here
        false
    end
  end
end
