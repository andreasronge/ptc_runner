defmodule PtcRunner.CapabilityRegistry.Promotion do
  @moduledoc """
  Pattern extraction and promotion for tool smithing and skill learning.

  Tracks successful plan patterns and flags them for promotion when they
  occur frequently. This enables the registry to grow organically based
  on actual usage patterns.

  ## Promotion Flow

      Plan Succeeds → Extract Pattern → Track Candidate → Flag for Review → Promote

  ## Promotion Types

  - **Tool Promotion**: Creates a composed tool from a repeated pattern
  - **Skill Promotion**: Creates expertise (prompt) from pattern guidance

  ## Pattern Hashing

  Patterns are normalized to ignore mission-specific details (inputs, paths)
  while preserving structure (agent count, task types, capability usage).

  """

  alias PtcRunner.CapabilityRegistry.{Registry, Skill, ToolEntry}

  @type promotion_candidate :: %{
          pattern_hash: String.t(),
          capability_signature: String.t() | nil,
          occurrences: [occurrence()],
          status: :candidate | :flagged | :promoted | :rejected,
          rejection_reason: String.t() | nil,
          created_at: DateTime.t()
        }

  @type occurrence :: %{
          mission: String.t(),
          result: :success | :failure,
          timestamp: DateTime.t()
        }

  @type plan :: %{
          :agents => map(),
          :tasks => [map()],
          optional(:context_tags) => [String.t()]
        }

  @default_promotion_threshold 3

  @doc """
  Extracts a normalized pattern hash from a plan.

  The hash ignores mission-specific details (inputs, paths) while
  capturing the structure (agent count, task types, capabilities).

  ## Example

      hash = extract_pattern(plan)
      # => "abc123..."

  """
  @spec extract_pattern(plan()) :: String.t()
  def extract_pattern(plan) do
    pattern = %{
      agent_count: map_size(plan.agents || %{}),
      task_count: length(plan.tasks || []),
      task_types: plan.tasks |> Enum.map(&get_task_type/1) |> Enum.sort(),
      dependency_shape: compute_dag_shape(plan),
      capabilities_used: extract_capability_ids(plan) |> Enum.sort()
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(pattern))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  @doc """
  Tracks a pattern occurrence in the registry.

  Increments the occurrence count for matching patterns.
  Creates new candidate if pattern is new.
  """
  @spec track_pattern(Registry.t(), plan(), :success | :failure, keyword()) :: Registry.t()
  def track_pattern(registry, plan, result, opts \\ []) do
    mission = Keyword.get(opts, :mission, "unknown")
    pattern_hash = extract_pattern(plan)

    occurrence = %{
      mission: mission,
      result: result,
      timestamp: DateTime.utc_now()
    }

    candidates =
      Map.update(
        registry.promotion_candidates,
        pattern_hash,
        new_candidate(pattern_hash, plan, occurrence),
        fn candidate ->
          %{candidate | occurrences: candidate.occurrences ++ [occurrence]}
        end
      )

    %{registry | promotion_candidates: candidates}
  end

  @doc """
  Checks if any candidates should be flagged for review.

  Returns list of pattern hashes that have reached the threshold.
  """
  @spec check_promotion_threshold(Registry.t(), keyword()) :: [String.t()]
  def check_promotion_threshold(registry, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_promotion_threshold)

    registry.promotion_candidates
    |> Enum.filter(fn {_hash, candidate} ->
      candidate.status == :candidate and
        success_count(candidate) >= threshold
    end)
    |> Enum.map(fn {hash, _} -> hash end)
  end

  @doc """
  Flags a candidate for review.
  """
  @spec flag_for_review(Registry.t(), String.t()) :: Registry.t()
  def flag_for_review(registry, pattern_hash) do
    update_candidate(registry, pattern_hash, fn candidate ->
      %{candidate | status: :flagged}
    end)
  end

  @doc """
  Promotes a candidate as a new composed tool.

  Creates a ToolEntry from the pattern and registers it.
  """
  @spec promote_as_tool(Registry.t(), String.t(), String.t(), keyword()) ::
          {:ok, Registry.t()} | {:error, term()}
  def promote_as_tool(registry, pattern_hash, name, opts \\ []) do
    case Map.fetch(registry.promotion_candidates, pattern_hash) do
      {:ok, candidate} ->
        code = Keyword.get(opts, :code)
        signature = Keyword.get(opts, :signature)
        tags = Keyword.get(opts, :tags, [])

        if code == nil do
          {:error, :code_required}
        else
          tool =
            ToolEntry.new_composed(name, code,
              signature: signature,
              tags: tags,
              source: :smithed,
              capability_id: candidate.capability_signature
            )

          registry =
            registry
            |> Registry.register_tool(tool)
            |> update_candidate(pattern_hash, fn c -> %{c | status: :promoted} end)

          {:ok, registry}
        end

      :error ->
        {:error, :candidate_not_found}
    end
  end

  @doc """
  Promotes a candidate as a new skill.

  Creates a Skill from the pattern and registers it.
  """
  @spec promote_as_skill(Registry.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Registry.t()} | {:error, term()}
  def promote_as_skill(registry, pattern_hash, name, prompt, opts \\ []) do
    case Map.fetch(registry.promotion_candidates, pattern_hash) do
      {:ok, _candidate} ->
        tags = Keyword.get(opts, :tags, [])
        applies_to = Keyword.get(opts, :applies_to, [])

        skill =
          Skill.new(name, name, prompt,
            tags: tags,
            applies_to: applies_to,
            source: :learned
          )

        registry =
          registry
          |> Registry.register_skill(skill)
          |> update_candidate(pattern_hash, fn c -> %{c | status: :promoted} end)

        {:ok, registry}

      :error ->
        {:error, :candidate_not_found}
    end
  end

  @doc """
  Rejects a promotion candidate with a reason.

  Rejected candidates won't be flagged again.
  """
  @spec reject_promotion(Registry.t(), String.t(), String.t()) :: Registry.t()
  def reject_promotion(registry, pattern_hash, reason) do
    update_candidate(registry, pattern_hash, fn candidate ->
      %{candidate | status: :rejected, rejection_reason: reason}
    end)
  end

  @doc """
  Lists promotion candidates with their status.
  """
  @spec list_candidates(Registry.t()) :: [promotion_candidate()]
  def list_candidates(registry) do
    Map.values(registry.promotion_candidates)
  end

  @doc """
  Lists candidates flagged for review.
  """
  @spec list_flagged(Registry.t()) :: [promotion_candidate()]
  def list_flagged(registry) do
    registry.promotion_candidates
    |> Map.values()
    |> Enum.filter(&(&1.status == :flagged))
  end

  @doc """
  Gets a candidate by pattern hash.
  """
  @spec get_candidate(Registry.t(), String.t()) :: promotion_candidate() | nil
  def get_candidate(registry, pattern_hash) do
    Map.get(registry.promotion_candidates, pattern_hash)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp new_candidate(pattern_hash, plan, first_occurrence) do
    %{
      pattern_hash: pattern_hash,
      capability_signature: synthesize_signature(plan),
      occurrences: [first_occurrence],
      status: :candidate,
      rejection_reason: nil,
      created_at: DateTime.utc_now()
    }
  end

  defp success_count(candidate) do
    Enum.count(candidate.occurrences, &(&1.result == :success))
  end

  defp update_candidate(registry, pattern_hash, update_fn) do
    case Map.fetch(registry.promotion_candidates, pattern_hash) do
      {:ok, candidate} ->
        updated = update_fn.(candidate)

        %{
          registry
          | promotion_candidates: Map.put(registry.promotion_candidates, pattern_hash, updated)
        }

      :error ->
        registry
    end
  end

  defp get_task_type(task) do
    Map.get(task, :type, :task)
  end

  defp compute_dag_shape(plan) do
    # Simple shape: count of tasks at each dependency depth
    tasks = plan.tasks || []

    depths =
      tasks
      |> Enum.map(fn task ->
        deps = Map.get(task, :depends_on, [])
        if deps == [], do: 0, else: 1
      end)
      |> Enum.frequencies()

    depths
  end

  defp extract_capability_ids(plan) do
    agents = plan.agents || %{}

    agents
    |> Enum.flat_map(fn {_id, agent} ->
      Map.get(agent, :tools, [])
    end)
    |> Enum.uniq()
  end

  defp synthesize_signature(plan) do
    # Simple heuristic: use first task's expected output type if available
    case plan.tasks do
      [first | _] -> Map.get(first, :signature)
      _ -> nil
    end
  end
end
