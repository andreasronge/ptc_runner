defmodule PtcRunner.CapabilityRegistry.Registry do
  @moduledoc """
  Main container for the Capability Registry.

  The Registry stores tools, skills, and capabilities with their metadata,
  enabling intelligent tool selection based on context and history.

  ## Key Features

  - **Context Economy**: Only inject tools/skills needed per mission
  - **Health Tracking**: Monitor tool health states (green/red/flaky)
  - **Trial History**: Learn from execution outcomes
  - **Promotion Candidates**: Track patterns for potential tool/skill creation

  ## Example

      registry = Registry.new()
        |> Registry.register_base_tool(
          "search",
          &MyApp.search/1,
          signature: "(query :string) -> [{title :string}]",
          tags: ["search", "query"]
        )
        |> Registry.register_skill(%Skill{
          id: "search_tips",
          prompt: "When searching, use specific terms...",
          applies_to: ["search"]
        })

  """

  alias PtcRunner.CapabilityRegistry.{Capability, Skill, ToolEntry}

  @type health :: :green | :red | :flaky | :pending

  @type t :: %__MODULE__{
          capabilities: %{String.t() => Capability.t()},
          tools: %{String.t() => ToolEntry.t()},
          skills: %{String.t() => Skill.t()},
          test_suites: %{String.t() => term()},
          history: [trial()],
          health: %{String.t() => health()},
          promotion_candidates: %{String.t() => term()},
          archived: %{String.t() => archived_entry()},
          embeddings: term() | nil
        }

  @type trial :: %{
          tool_id: String.t(),
          context_tags: [String.t()],
          success: boolean(),
          timestamp: DateTime.t()
        }

  @type archived_entry :: %{
          type: :tool | :skill,
          entry: ToolEntry.t() | Skill.t(),
          archived_at: DateTime.t(),
          reason: String.t() | nil
        }

  defstruct capabilities: %{},
            tools: %{},
            skills: %{},
            test_suites: %{},
            history: [],
            health: %{},
            promotion_candidates: %{},
            archived: %{},
            embeddings: nil

  @max_history_size 10_000

  @doc """
  Creates a new empty registry.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  # ============================================================================
  # Tool Registration
  # ============================================================================

  @doc """
  Registers a base tool (Elixir function).

  ## Options

  - `:signature` - Tool signature string
  - `:description` - Tool description
  - `:tags` - List of tags for discovery
  - `:capability_id` - Optional capability to associate with
  - `:examples` - Input/output examples

  ## Examples

      registry = Registry.register_base_tool(
        registry,
        "search",
        &MyApp.search/1,
        signature: "(query :string) -> [{title :string}]",
        tags: ["search", "query"]
      )

  """
  @spec register_base_tool(t(), String.t(), (map() -> term()), keyword()) :: t()
  def register_base_tool(registry, id, function, opts \\ []) do
    entry = ToolEntry.new_base(id, function, opts)
    do_register_tool(registry, entry)
  end

  @doc """
  Registers a composed tool (PTC-Lisp code).

  ## Options

  - `:signature` - Tool signature string
  - `:description` - Tool description
  - `:tags` - List of tags for discovery
  - `:capability_id` - Optional capability to associate with
  - `:dependencies` - List of tool IDs this tool depends on
  - `:source` - `:developer` or `:smithed`

  """
  @spec register_composed_tool(t(), String.t(), String.t(), keyword()) :: t()
  def register_composed_tool(registry, id, code, opts \\ []) do
    entry = ToolEntry.new_composed(id, code, opts)
    do_register_tool(registry, entry)
  end

  @doc """
  Registers a pre-built ToolEntry struct.
  """
  @spec register_tool(t(), ToolEntry.t()) :: t()
  def register_tool(registry, %ToolEntry{} = entry) do
    do_register_tool(registry, entry)
  end

  defp do_register_tool(registry, entry) do
    # Add to tools map
    tools = Map.put(registry.tools, entry.id, entry)

    # Set initial health status
    health = Map.put(registry.health, entry.id, :pending)

    # Update capability if specified
    capabilities =
      if entry.capability_id do
        update_capability_impl(registry.capabilities, entry.capability_id, entry.id)
      else
        registry.capabilities
      end

    %{registry | tools: tools, health: health, capabilities: capabilities}
  end

  defp update_capability_impl(capabilities, capability_id, impl_id) do
    case Map.fetch(capabilities, capability_id) do
      {:ok, capability} ->
        Map.put(capabilities, capability_id, Capability.add_implementation(capability, impl_id))

      :error ->
        # Create new capability
        capability =
          Capability.new(capability_id)
          |> Capability.add_implementation(impl_id)

        Map.put(capabilities, capability_id, capability)
    end
  end

  @doc """
  Unregisters a tool by ID.
  """
  @spec unregister_tool(t(), String.t()) :: t()
  def unregister_tool(registry, tool_id) do
    case Map.fetch(registry.tools, tool_id) do
      {:ok, entry} ->
        %{
          registry
          | tools: Map.delete(registry.tools, tool_id),
            health: Map.delete(registry.health, tool_id),
            test_suites: Map.delete(registry.test_suites, tool_id),
            capabilities: remove_tool_from_capability(registry.capabilities, entry, tool_id)
        }

      :error ->
        registry
    end
  end

  defp remove_tool_from_capability(capabilities, %{capability_id: nil}, _tool_id),
    do: capabilities

  defp remove_tool_from_capability(capabilities, %{capability_id: cap_id}, tool_id) do
    capabilities
    |> Map.update(cap_id, nil, fn
      nil -> nil
      cap -> Capability.remove_implementation(cap, tool_id)
    end)
    |> Map.reject(fn {_, v} -> v == nil end)
  end

  # ============================================================================
  # Skill Registration
  # ============================================================================

  @doc """
  Registers a skill.

  ## Examples

      skill = Skill.new(
        "csv_tips",
        "CSV Handling Tips",
        "When parsing CSV files...",
        applies_to: ["parse_csv"]
      )
      registry = Registry.register_skill(registry, skill)

  """
  @spec register_skill(t(), Skill.t()) :: t()
  def register_skill(registry, %Skill{} = skill) do
    %{registry | skills: Map.put(registry.skills, skill.id, skill)}
  end

  @doc """
  Unregisters a skill by ID.
  """
  @spec unregister_skill(t(), String.t()) :: t()
  def unregister_skill(registry, skill_id) do
    %{registry | skills: Map.delete(registry.skills, skill_id)}
  end

  @doc """
  Updates a skill in the registry.
  """
  @spec update_skill(t(), String.t(), (Skill.t() -> Skill.t())) :: t()
  def update_skill(registry, skill_id, update_fn) do
    case Map.fetch(registry.skills, skill_id) do
      {:ok, skill} ->
        updated = update_fn.(skill)
        %{registry | skills: Map.put(registry.skills, skill_id, updated)}

      :error ->
        registry
    end
  end

  # ============================================================================
  # Capability Registration
  # ============================================================================

  @doc """
  Registers a capability.
  """
  @spec register_capability(t(), Capability.t()) :: t()
  def register_capability(registry, %Capability{} = capability) do
    %{registry | capabilities: Map.put(registry.capabilities, capability.id, capability)}
  end

  # ============================================================================
  # Getters
  # ============================================================================

  @doc """
  Gets a tool by ID.
  """
  @spec get_tool(t(), String.t()) :: ToolEntry.t() | nil
  def get_tool(registry, tool_id) do
    Map.get(registry.tools, tool_id)
  end

  @doc """
  Gets a skill by ID.
  """
  @spec get_skill(t(), String.t()) :: Skill.t() | nil
  def get_skill(registry, skill_id) do
    Map.get(registry.skills, skill_id)
  end

  @doc """
  Gets a capability by ID.
  """
  @spec get_capability(t(), String.t()) :: Capability.t() | nil
  def get_capability(registry, capability_id) do
    Map.get(registry.capabilities, capability_id)
  end

  @doc """
  Gets the health status of a tool.
  """
  @spec get_health(t(), String.t()) :: health() | nil
  def get_health(registry, tool_id) do
    Map.get(registry.health, tool_id)
  end

  @doc """
  Lists all tool IDs.
  """
  @spec list_tool_ids(t()) :: [String.t()]
  def list_tool_ids(registry) do
    Map.keys(registry.tools)
  end

  @doc """
  Lists all skill IDs.
  """
  @spec list_skill_ids(t()) :: [String.t()]
  def list_skill_ids(registry) do
    Map.keys(registry.skills)
  end

  @doc """
  Lists all tools.
  """
  @spec list_tools(t()) :: [ToolEntry.t()]
  def list_tools(registry) do
    Map.values(registry.tools)
  end

  @doc """
  Lists all skills.
  """
  @spec list_skills(t()) :: [Skill.t()]
  def list_skills(registry) do
    Map.values(registry.skills)
  end

  @doc """
  Lists healthy tools (green status).
  """
  @spec list_healthy_tools(t()) :: [ToolEntry.t()]
  def list_healthy_tools(registry) do
    registry.tools
    |> Enum.filter(fn {id, _} -> Map.get(registry.health, id) == :green end)
    |> Enum.map(fn {_, tool} -> tool end)
  end

  @doc """
  Lists skills flagged for review.
  """
  @spec list_skills_for_review(t()) :: [Skill.t()]
  def list_skills_for_review(registry) do
    registry.skills
    |> Map.values()
    |> Enum.filter(&(&1.review_status != nil))
  end

  # ============================================================================
  # Health Management
  # ============================================================================

  @doc """
  Marks a tool as healthy (green).
  """
  @spec mark_healthy(t(), String.t()) :: t()
  def mark_healthy(registry, tool_id) do
    %{registry | health: Map.put(registry.health, tool_id, :green)}
  end

  @doc """
  Marks a tool as unhealthy (red).
  """
  @spec mark_unhealthy(t(), String.t()) :: t()
  def mark_unhealthy(registry, tool_id) do
    %{registry | health: Map.put(registry.health, tool_id, :red)}
  end

  @doc """
  Marks a tool as flaky.
  """
  @spec mark_flaky(t(), String.t()) :: t()
  def mark_flaky(registry, tool_id) do
    %{registry | health: Map.put(registry.health, tool_id, :flaky)}
  end

  # ============================================================================
  # Trial History
  # ============================================================================

  @doc """
  Records a trial outcome for a tool.

  History is bounded to prevent unbounded growth.
  """
  @spec record_trial(t(), String.t(), [String.t()], boolean()) :: t()
  def record_trial(registry, tool_id, context_tags, success?) do
    trial = %{
      tool_id: tool_id,
      context_tags: context_tags,
      success: success?,
      timestamp: DateTime.utc_now()
    }

    history = [trial | registry.history] |> Enum.take(@max_history_size)

    # Update tool statistics
    tools =
      case Map.fetch(registry.tools, tool_id) do
        {:ok, tool} ->
          updated =
            tool
            |> ToolEntry.update_success_rate(success?)
            |> then(fn t ->
              Enum.reduce(context_tags, t, fn tag, acc ->
                ToolEntry.update_context_success(acc, tag, success?)
              end)
            end)

          Map.put(registry.tools, tool_id, updated)

        :error ->
          registry.tools
      end

    %{registry | history: history, tools: tools}
  end

  @doc """
  Records a trial outcome for a skill.
  """
  @spec record_skill_trial(t(), String.t(), [String.t()], String.t() | nil, boolean()) :: t()
  def record_skill_trial(registry, skill_id, context_tags, model_id, success?) do
    skills =
      case Map.fetch(registry.skills, skill_id) do
        {:ok, skill} ->
          updated =
            skill
            |> Skill.update_success_rate(success?)
            |> then(fn s ->
              if model_id, do: Skill.update_model_success(s, model_id, success?), else: s
            end)
            |> then(fn s ->
              Enum.reduce(context_tags, s, fn tag, acc ->
                Skill.update_context_success(acc, tag, success?)
              end)
            end)

          Map.put(registry.skills, skill_id, updated)

        :error ->
          registry.skills
      end

    %{registry | skills: skills}
  end

  # ============================================================================
  # Link Recording
  # ============================================================================

  @doc """
  Records that a tool was linked into a mission.
  """
  @spec record_tool_link(t(), String.t()) :: t()
  def record_tool_link(registry, tool_id) do
    case Map.fetch(registry.tools, tool_id) do
      {:ok, tool} ->
        updated = ToolEntry.record_link(tool)
        %{registry | tools: Map.put(registry.tools, tool_id, updated)}

      :error ->
        registry
    end
  end

  @doc """
  Records that a skill was linked into a mission.
  """
  @spec record_skill_link(t(), String.t()) :: t()
  def record_skill_link(registry, skill_id) do
    case Map.fetch(registry.skills, skill_id) do
      {:ok, skill} ->
        updated = Skill.record_link(skill)
        %{registry | skills: Map.put(registry.skills, skill_id, updated)}

      :error ->
        registry
    end
  end

  # ============================================================================
  # Skill Review Management
  # ============================================================================

  @doc """
  Flags a skill for review.
  """
  @spec flag_skill_for_review(t(), String.t(), String.t()) :: t()
  def flag_skill_for_review(registry, skill_id, reason) do
    update_skill(registry, skill_id, &Skill.flag_for_review(&1, reason))
  end

  @doc """
  Flags all skills that apply to a tool (for use when a tool is repaired).
  """
  @spec flag_skills_for_tool(t(), String.t(), String.t()) :: t()
  def flag_skills_for_tool(registry, tool_id, reason) do
    skills =
      registry.skills
      |> Enum.map(fn {id, skill} ->
        if tool_id in skill.applies_to do
          {id, Skill.flag_for_review(skill, reason)}
        else
          {id, skill}
        end
      end)
      |> Map.new()

    %{registry | skills: skills}
  end

  # ============================================================================
  # Archival
  # ============================================================================

  @doc """
  Archives a tool (moves to cold storage).
  """
  @spec archive_tool(t(), String.t(), String.t() | nil) :: t()
  def archive_tool(registry, tool_id, reason \\ nil) do
    case Map.fetch(registry.tools, tool_id) do
      {:ok, tool} ->
        archived_entry = %{
          type: :tool,
          entry: tool,
          archived_at: DateTime.utc_now(),
          reason: reason
        }

        registry
        |> unregister_tool(tool_id)
        |> then(&%{&1 | archived: Map.put(&1.archived, tool_id, archived_entry)})

      :error ->
        registry
    end
  end

  @doc """
  Archives a skill (moves to cold storage).
  """
  @spec archive_skill(t(), String.t(), String.t() | nil) :: t()
  def archive_skill(registry, skill_id, reason \\ nil) do
    case Map.fetch(registry.skills, skill_id) do
      {:ok, skill} ->
        archived_entry = %{
          type: :skill,
          entry: skill,
          archived_at: DateTime.utc_now(),
          reason: reason
        }

        registry
        |> unregister_skill(skill_id)
        |> then(&%{&1 | archived: Map.put(&1.archived, skill_id, archived_entry)})

      :error ->
        registry
    end
  end

  @doc """
  Restores an archived item.
  """
  @spec restore(t(), String.t()) :: t()
  def restore(registry, id) do
    case Map.fetch(registry.archived, id) do
      {:ok, %{type: :tool, entry: tool}} ->
        registry
        |> then(&%{&1 | archived: Map.delete(&1.archived, id)})
        |> register_tool(tool)

      {:ok, %{type: :skill, entry: skill}} ->
        registry
        |> then(&%{&1 | archived: Map.delete(&1.archived, id)})
        |> register_skill(skill)

      :error ->
        registry
    end
  end

  @doc """
  Lists archived items.
  """
  @spec list_archived(t()) :: [archived_entry()]
  def list_archived(registry) do
    Map.values(registry.archived)
  end

  # ============================================================================
  # Counts
  # ============================================================================

  @doc """
  Returns count statistics for the registry.
  """
  @spec counts(t()) :: %{
          tools: non_neg_integer(),
          skills: non_neg_integer(),
          capabilities: non_neg_integer(),
          archived: non_neg_integer()
        }
  def counts(registry) do
    %{
      tools: map_size(registry.tools),
      skills: map_size(registry.skills),
      capabilities: map_size(registry.capabilities),
      archived: map_size(registry.archived)
    }
  end
end
