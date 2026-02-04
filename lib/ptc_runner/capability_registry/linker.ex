defmodule PtcRunner.CapabilityRegistry.Linker do
  @moduledoc """
  Resolves and injects both tools and skills into worker agents.

  The Linker is the key component that enables the "Context Economy" -
  only injecting the tools and skills needed for each mission.

  ## Linking Process

  1. Resolve requested tools (with transitive dependencies)
  2. Find skills that `apply_to` selected tools
  3. Find skills that match context tags
  4. Generate PTC-Lisp prelude for composed tools
  5. Generate skill prompt for system message

  ## Link Result

  The `link/4` function returns a `LinkResult` struct containing:

  - `tools` - List of resolved ToolEntry structs
  - `skills` - List of resolved Skill structs
  - `lisp_prelude` - PTC-Lisp definitions for composed tools
  - `skill_prompt` - Formatted prompt text for skills
  - `base_tools` - Map of base tool functions for execution

  """

  alias PtcRunner.CapabilityRegistry.{Discovery, Registry, Skill, ToolEntry}

  # Suppress dialyzer warnings for MapSet opaqueness in recursive dependency resolution
  # and for resolve_skills which dialyzer incorrectly flags as having no return
  @dialyzer {:nowarn_function, [resolve_deps_recursive: 5, resolve_skills: 4]}

  @type link_result :: %{
          tools: [ToolEntry.t()],
          skills: [Skill.t()],
          lisp_prelude: String.t(),
          skill_prompt: String.t(),
          base_tools: %{String.t() => (map() -> term())}
        }

  @type link_opts :: [
          context_tags: [String.t()],
          model_id: String.t(),
          include_skills: boolean()
        ]

  @doc """
  Links tools and skills for a mission.

  Resolves all requested tools (including transitive dependencies),
  finds applicable skills, and generates injection artifacts.

  ## Options

  - `:context_tags` - Tags for context-aware skill matching
  - `:model_id` - Model ID for skill effectiveness filtering
  - `:include_skills` - Whether to include skills (default: true)

  ## Returns

  `{:ok, link_result}` or `{:error, reason}`

  ## Example

      {:ok, result} = Linker.link(registry, ["search", "parse_csv"], context_tags: ["european"])

      # Result contains:
      # - tools: resolved tool entries
      # - skills: matched skills
      # - lisp_prelude: "(defn parse-csv [text] ...)"
      # - skill_prompt: "## CSV Handling\\nWhen parsing European CSVs..."
      # - base_tools: %{"search" => fn, "file_read" => fn, ...}

  """
  @spec link(Registry.t(), [String.t()], link_opts()) :: {:ok, link_result()} | {:error, term()}
  def link(registry, tool_ids, opts \\ []) do
    context_tags = Keyword.get(opts, :context_tags, [])
    model_id = Keyword.get(opts, :model_id)
    include_skills = Keyword.get(opts, :include_skills, true)

    with {:ok, all_tools} <- resolve_dependencies(registry, tool_ids) do
      # Find skills
      skills =
        if include_skills do
          resolved_tool_ids = Enum.map(all_tools, & &1.id)
          resolve_skills(registry, resolved_tool_ids, context_tags, model_id)
        else
          []
        end

      # Generate artifacts
      lisp_prelude = generate_prelude(all_tools)
      skill_prompt = generate_skill_prompt(skills)
      base_tools = extract_base_tools(all_tools)

      # Record link events
      registry_with_links =
        all_tools
        |> Enum.reduce(registry, fn tool, r -> Registry.record_tool_link(r, tool.id) end)

      _registry_with_skill_links =
        skills
        |> Enum.reduce(registry_with_links, fn skill, r ->
          Registry.record_skill_link(r, skill.id)
        end)

      {:ok,
       %{
         tools: all_tools,
         skills: skills,
         lisp_prelude: lisp_prelude,
         skill_prompt: skill_prompt,
         base_tools: base_tools
       }}
    end
  end

  @doc """
  Extracts tool dependencies from PTC-Lisp code.

  Finds all `(tool/name ...)` patterns and returns the tool names.

  ## Example

      deps = extract_dependencies("(-> (tool/read {:path p}) (tool/parse {}))")
      # => ["read", "parse"]

  """
  @spec extract_dependencies(String.t()) :: [String.t()]
  def extract_dependencies(code) when is_binary(code) do
    ~r/\(tool\/([a-z0-9_-]+)/
    |> Regex.scan(code)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
  end

  def extract_dependencies(_), do: []

  @doc """
  Resolves all dependencies for a set of tools (transitive).

  Returns tools in topological order (dependencies before dependents).
  Detects cycles and returns error if found.
  """
  @spec resolve_dependencies(Registry.t(), [String.t()]) ::
          {:ok, [ToolEntry.t()]} | {:error, term()}
  def resolve_dependencies(registry, tool_ids) do
    resolve_deps_recursive(registry, tool_ids, MapSet.new(), [], MapSet.new())
  end

  defp resolve_deps_recursive(_registry, [], _visited, resolved, _in_progress) do
    {:ok, resolved |> Enum.uniq_by(& &1.id)}
  end

  defp resolve_deps_recursive(registry, [id | rest], visited, resolved, in_progress) do
    cond do
      MapSet.member?(visited, id) ->
        # Already processed
        resolve_deps_recursive(registry, rest, visited, resolved, in_progress)

      MapSet.member?(in_progress, id) ->
        # Cycle detected
        {:error, {:dependency_cycle, id}}

      true ->
        case Registry.get_tool(registry, id) do
          nil ->
            {:error, {:tool_not_found, id}}

          tool ->
            # Get dependencies from explicit list or extract from code
            deps =
              case tool.dependencies do
                [] when tool.code != nil -> extract_dependencies(tool.code)
                deps -> deps
              end

            # Mark as in-progress for cycle detection
            in_progress = MapSet.put(in_progress, id)

            # Recursively resolve dependencies first
            case resolve_deps_recursive(registry, deps, visited, resolved, in_progress) do
              {:ok, resolved_deps} ->
                # Add current tool after its dependencies (append for topological order)
                new_visited = MapSet.put(visited, id)
                new_resolved = resolved_deps ++ [tool]
                resolve_deps_recursive(registry, rest, new_visited, new_resolved, in_progress)

              error ->
                error
            end
        end
    end
  end

  @doc """
  Generates PTC-Lisp prelude for composed tools.

  Returns definitions in topological order so dependencies are defined first.
  """
  @spec generate_prelude([ToolEntry.t()]) :: String.t()
  def generate_prelude(tools) do
    tools
    |> Enum.filter(&(&1.layer == :composed and &1.code != nil))
    |> Enum.map_join("\n\n", & &1.code)
  end

  @doc """
  Generates skill prompt text for system message injection.

  Formats skills with headers for easy reading.
  """
  @spec generate_skill_prompt([Skill.t()]) :: String.t()
  def generate_skill_prompt([]), do: ""

  def generate_skill_prompt(skills) do
    """
    ## Expertise

    #{Enum.map_join(skills, "\n\n", &format_skill/1)}
    """
    |> String.trim()
  end

  defp format_skill(skill) do
    """
    ### #{skill.name}

    #{skill.prompt}
    """
    |> String.trim()
  end

  @doc """
  Extracts base tool functions for execution.

  Returns a map of tool_id => function for all base tools.
  """
  @spec extract_base_tools([ToolEntry.t()]) :: %{String.t() => (map() -> term())}
  def extract_base_tools(tools) do
    tools
    |> Enum.filter(&(&1.layer == :base and &1.function != nil))
    |> Map.new(&{&1.id, &1.function})
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp resolve_skills(registry, tool_ids, context_tags, model_id) do
    # Strategy 1: Skills linked via applies_to
    tool_linked =
      Discovery.search_skills(registry, [], tool_ids: tool_ids, model_id: model_id)

    # Strategy 2: Skills matching context tags
    context_matched =
      Discovery.search_skills(registry, context_tags, model_id: model_id)

    # Merge and dedupe
    (tool_linked ++ context_matched)
    |> Enum.uniq_by(& &1.id)
    |> filter_by_model_effectiveness(model_id)
  end

  defp filter_by_model_effectiveness(skills, nil), do: skills

  defp filter_by_model_effectiveness(skills, model_id) do
    skills
    |> Enum.filter(fn skill ->
      Skill.effectiveness_for_model(skill, model_id) >= 0.5
    end)
  end
end
