defmodule Alma.MetaAgent do
  @moduledoc """
  Uses an LLM to generate new memory designs as live PTC-Lisp closures.

  The MetaAgent is a multi-turn PTC-Lisp SubAgent that `defn`s `mem-update` and
  `recall` functions. These closures persist in `step.memory`, eliminating string
  eval entirely.

  Prompt architecture:
  - `system_prompt: %{prefix: system_prefix()}` — stable, domain-blind instructions
    about the meta-agent role, design principles, data access, and tool docs. Cached
    by the LLM across iterations.
  - `prompt: mission_prompt(parents, context_schema)` — dynamic per-iteration content:
    environment schema, parent designs, and lineage.
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.Lisp.CoreToSource

  @doc """
  Generates a new memory design from parent designs using an LLM SubAgent.

  The SubAgent defines `mem-update` and `recall` functions using `defn`, then
  returns them via `(return ...)`. The result is a design map with live closures
  and serialized source strings.

  Returns `{:ok, design}` or `{:error, reason}`.
  """
  def generate(parents, opts \\ []) do
    llm = Keyword.fetch!(opts, :llm)
    context_schema = Keyword.get(opts, :context_schema)
    analyst_critique = Keyword.get(opts, :analyst_critique)

    agent =
      SubAgent.new(
        name: "meta_agent",
        prompt: mission_prompt(parents, context_schema, analyst_critique),
        system_prompt: %{prefix: system_prefix()},
        signature: "(parents [:map]) -> {name :string, description :string}",
        tools: %{},
        max_turns: 4
      )

    parent_summaries =
      Enum.map(parents, fn p ->
        %{
          "name" => Map.get(p.design, :name, "unknown"),
          "description" => Map.get(p.design, :description, ""),
          "score" => p.score,
          "mem_update_source" => Map.get(p.design, :mem_update_source, ""),
          "recall_source" => Map.get(p.design, :recall_source, "")
        }
      end)

    case SubAgent.run(agent, llm: llm, context: %{"parents" => parent_summaries}) do
      {:ok, step} ->
        mem_update = step.memory[:"mem-update"]
        recall = step.memory[:recall]

        if is_tuple(mem_update) and is_tuple(recall) do
          design = %{
            name: extract_name(step),
            description: extract_description(step),
            mem_update: mem_update,
            recall: recall,
            mem_update_source: CoreToSource.serialize_closure(mem_update),
            recall_source: CoreToSource.serialize_closure(recall),
            namespace: step.memory
          }

          {:ok, design}
        else
          {:error, "MetaAgent did not produce valid closures for mem-update and recall"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_name(step) do
    cond do
      is_map(step.return) and is_binary(step.return["name"]) -> step.return["name"]
      is_binary(step.memory[:name]) -> step.memory[:name]
      true -> "gen_#{System.unique_integer([:positive])}"
    end
  end

  defp extract_description(step) do
    cond do
      is_map(step.return) and is_binary(step.return["description"]) ->
        step.return["description"]

      is_binary(step.memory[:description]) ->
        step.memory[:description]

      true ->
        ""
    end
  end

  # -- System prefix: stable, domain-blind, cacheable --

  defp system_prefix do
    """
    <role>
    You are an expert memory designer for autonomous agents. Your job is to create
    a memory system that helps an agent learn from past experiences. You will define
    two PTC-Lisp functions (`mem-update` and `recall`) that store and retrieve
    knowledge across episodes.
    </role>

    <memory_design_task>
    Define two functions using `defn`:

    `mem-update` — called after each episode with episode data in context.
    MUST use the provided tools (tool/store-obs, tool/graph-update) to persist
    knowledge. Do NOT use `defonce` or `def` for persistence — all cross-episode
    state must go through the tool-backed stores (vector store, graph store).
    IMPORTANT: `data/observation_log` contains spatial data (rooms visited,
    exits seen, objects found) regardless of whether the episode succeeded.
    Always extract and store this data — failed episodes reveal the environment
    just as much as successful ones.

    `recall` — called before each new task with task info in context.
    MUST use tool/find-similar and/or tool/graph-path to retrieve stored knowledge.
    Must return a text string with advice for the task agent. Keep advice
    short and action-oriented — include specific room names and object locations
    from memory, not generic exploration suggestions.

    Both functions take no arguments — context is accessed via `data/` prefix.
    Helper functions must be defined before they are used.
    The harness calls your functions — they do not call themselves.
    </memory_design_task>

    <ptc_lisp_reference>
    Environment data (via `data/`) uses atom keys. Access with: `(:key map)`.
    Maps you create in PTC-Lisp use string keys. Access with: `(get map "key")`.

    Nested mixed mode: `data/` fields contain environment maps with atom keys.
    Use `(:goal data/task)` NOT `(get data/task "goal")`.

    Use `let` for local variables within a function. Do NOT use `defonce` or
    `def` to build persistent state — use the provided tool stores instead.

    Guard against empty data: `data/observation_log` may be `[]` if the agent
    failed immediately. Always guard:
    `(if-let [obs (first data/observation_log)] (:field obs) "unknown")`

    Use `(println ...)` to emit debug output in your mem-update and recall functions.
    This output is captured and analyzed after evaluation to identify issues.
    </ptc_lisp_reference>

    <available_tools>
    Your memory design MUST use these tools — they are the ONLY way to persist
    knowledge across episodes. Each tool is available in both `mem-update` and
    `recall`. A good design uses multiple tools together — e.g., a vector store
    for experience retrieval, a graph for spatial reasoning, and LLM analysis
    for pattern extraction.

    <vector_store_tools>
    VECTOR STORE — semantic similarity search over stored observations.
    Use this to remember and retrieve experiences across episodes. You can
    maintain separate collections (namespaces) for different types of knowledge
    (e.g., "spatial" for location data, "strategy" for action patterns).

    `tool/store-obs` — store an observation with auto-generated embedding.
    Parameters:
    - "text" (required, string): the observation text to store and embed
    - "metadata" (optional, map): key-value pairs attached to the entry
    - "collection" (optional, string, default "default"): namespace for the entry
    Returns: "stored:<id>"

    ```clojure
    ;; Store with metadata and collection namespace
    (tool/store-obs {"text" "observed X at location Y"
                     "metadata" {"type" "observation"}
                     "collection" "facts"})

    ;; Store in default collection
    (tool/store-obs {"text" "connection from A to B"})
    ```

    `tool/find-similar` — retrieve top-k entries most similar to a query.
    Parameters:
    - "query" (required, string): the search text
    - "k" (optional, int, default 3): number of results to return
    - "collection" (optional, string): restrict search to one namespace; omit to search all
    - "contains" (optional, string): pre-filter results to texts containing this exact substring. Use to match specific object names before ranking by similarity.
    Returns: list of maps [{"score" float, "text" string, "metadata" map} ...]

    ```clojure
    ;; Search within a specific collection
    (tool/find-similar {"query" "where is the target?" "k" 5 "collection" "facts"})
    ;; → [{"score" 0.85 "text" "observed X at location Y" "metadata" {"type" "observation"}} ...]

    ;; Search with contains pre-filter — only entries mentioning "horn" are considered
    (tool/find-similar {"query" "horn location" "k" 3 "contains" "horn"})

    ;; Search across all collections
    (tool/find-similar {"query" "how to reach destination" "k" 3})
    ```

    Design patterns for vector store:
    - In `mem-update`: store observations from `data/observation_log` regardless
      of success/failure — failed episodes still contain useful data.
    - In `recall`: query with the current goal or task description to retrieve
      relevant past experiences. When looking for a specific object, always use
      `"contains"` with the object name to avoid false matches from semantically
      similar but unrelated entries.
    - Use collections to separate different types of knowledge.
    </vector_store_tools>

    <graph_tools>
    GRAPH STORE — persistent undirected graph for connectivity and pathfinding.
    Use this to build and query spatial maps, relationship graphs, or any
    structure where you need to reason about connections and shortest paths.
    The graph persists across episodes via memory.

    `tool/graph-update` — add undirected edges to the graph.
    Parameters:
    - "edges" (required, list of [string, string] pairs): edges to add (bidirectional)
    Returns: "ok"

    ```clojure
    ;; Build a graph from observed connections
    (tool/graph-update {"edges" [["A" "B"] ["B" "C"]]})
    ```

    `tool/graph-neighbors` — get all nodes directly connected to a node.
    Parameters:
    - "node" (required, string): the node to query
    Returns: sorted list of neighbor strings, or [] if node is unknown

    ```clojure
    (tool/graph-neighbors {"node" "A"})
    ;; → ["B" "D"]
    ```

    `tool/graph-path` — find the shortest path between two nodes (BFS).
    Parameters:
    - "from" (required, string): start node
    - "to" (required, string): end node
    Returns: list of nodes [from ... to], or nil if disconnected

    ```clojure
    (tool/graph-path {"from" "A" "to" "C"})
    ;; → ["A" "B" "C"] or nil
    ```

    Design patterns for graph store:
    - In `mem-update`: extract connections from `data/observation_log` and add
      them with `tool/graph-update`. Do this for ALL episodes — failed episodes
      reveal the environment too.
    - In `recall`: use `tool/graph-path` to compute directions for the task
      agent based on known topology.
    - The graph accumulates across episodes, building an increasingly complete
      map of the environment.
    </graph_tools>

    <llm_tools>
    LLM-POWERED ANALYSIS — use an LLM to extract patterns or structured data
    from text. Each call costs one LLM invocation, so use judiciously.

    `tool/summarize` — condense or synthesize text.
    Parameters:
    - "text" (required, string): the text to process
    - "instruction" (required, string): what to do with the text
    Returns: condensed string

    ```clojure
    (tool/summarize {"text" long-text "instruction" "list the key findings"})
    ```

    `tool/analyze` — extract patterns or structured data from text.
    Parameters:
    - "text" (required, string): the text to analyze
    - "instruction" (required, string): what to extract
    - "format" (optional, "text" or "json", default "text"): output format
    Returns: string (text mode) or parsed map/list (json mode)

    ```clojure
    ;; Text mode — returns analysis as a string
    (tool/analyze {"text" obs-text "instruction" "what patterns do you see?"})

    ;; JSON mode — returns a parsed map you can iterate over
    (tool/analyze {"text" obs-text
                   "instruction" "extract object-location pairs as a list"
                   "format" "json"})
    ;; → [{"item" "X" "location" "Y"} ...]
    ```

    Design patterns for LLM tools:
    - Use `tool/analyze` with "json" format to extract structured data from
      observation logs that would be complex to parse in PTC-Lisp directly.
    - Use `tool/summarize` to condense accumulated experiences into compact
      advice strings for recall.
    </llm_tools>
    </available_tools>

    <output_format>
    Define your functions and return metadata in a single program:

    ```clojure
    (defn mem-update []
      ;; Extract facts from data/observation_log, data/task, data/actions
      ;; Store observations with tool/store-obs
      ;; Build spatial graph with tool/graph-update
      ...)

    (defn recall []
      ;; Query stored knowledge using data/task for context
      ;; Use tool/find-similar and/or tool/graph-path
      ;; Return specific advice — not generic text
      ...)

    (return {"name" "design_name" "description" "what it does"})
    ```

    The closures are extracted from memory automatically — do NOT include them
    in the return map. If your code has an error, the system will show it and
    you can fix it on the next turn.
    </output_format>
    """
  end

  # -- Mission prompt: dynamic, per-iteration content --

  defp mission_prompt(parents, context_schema, analyst_critique) do
    parent_context = format_parent_designs(parents)

    critique_section =
      if analyst_critique && analyst_critique != "" do
        """

        <analyst_feedback>
        #{analyst_critique}
        </analyst_feedback>
        """
      else
        ""
      end

    """
    <environment_schema>
    #{format_function_schemas(context_schema)}
    </environment_schema>

    <parent_designs>
    #{parent_context}
    </parent_designs>
    #{critique_section}
    Create a new memory design that improves on the parent designs. You MUST
    satisfy all mandatory constraints from the analyst's feedback. Your design
    MUST use tool/store-obs and tool/graph-update in mem-update, and
    tool/find-similar and/or tool/graph-path in recall. The recall function
    must return advice containing specific details from stored knowledge —
    not generic exploration text.
    """
  end

  defp format_function_schemas(nil) do
    """
    mem-update context (via `data/` prefix):
    - `data/task` — the task configuration map
    - `data/actions` — list of actions taken during the episode
    - `data/success` — boolean, whether the task succeeded
    - `data/observation_log` — list of observation maps from the episode

    recall context (via `data/` prefix):
    - `data/task` — the upcoming task configuration map
    """
    |> String.trim_trailing()
  end

  defp format_function_schemas(schema) when is_map(schema) do
    format_schema_section(schema, "mem_update", "mem-update") <>
      "\n\n" <>
      format_schema_section(schema, "recall", "recall")
  end

  defp format_schema_section(schema, key, label) do
    case Map.get(schema, key) do
      nil ->
        "#{label} context: see data/ prefix fields"

      data_map ->
        lines =
          data_map
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map_join("\n", fn {data_key, description} ->
            "- `#{data_key}` — #{description}"
          end)

        "#{label} context (via `data/` prefix):\n#{lines}"
    end
  end

  defp format_parent_designs(parents) do
    if Enum.empty?(parents) do
      "No high-scoring parents yet. Create a novel memory strategy."
    else
      parents
      |> Enum.map(fn p ->
        name = Map.get(p.design, :name, "unknown")
        score = p.score
        mem_update_src = Map.get(p.design, :mem_update_source, "")
        recall_src = Map.get(p.design, :recall_source, "")
        errors = Map.get(p, :errors, [])

        error_section =
          if errors != [] do
            error_lines = Enum.map_join(errors, "\n", &"- #{&1}")
            "\n<errors>\n#{error_lines}\n</errors>\n"
          else
            ""
          end

        generation = Map.get(p, :generation)
        parent_ids = Map.get(p, :parent_ids, [])
        lineage = format_lineage(generation, parent_ids, parents)

        analysis_section = format_analysis(p)
        trajectory_section = format_compressed_trajectories(p)

        """
        <design name="#{name}" score="#{Float.round(score * 1.0, 2)}">
        #{Map.get(p.design, :description, "")}#{lineage}
        #{analysis_section}#{trajectory_section}
        mem-update source:
        ```clojure
        #{mem_update_src}
        ```

        recall source:
        ```clojure
        #{recall_src}
        ```
        #{error_section}</design>
        """
      end)
      |> Enum.join("\n")
    end
  end

  defp format_lineage(nil, _, _), do: ""
  defp format_lineage(_, _, nil), do: ""

  defp format_lineage(generation, parent_ids, all_parents)
       when is_list(parent_ids) and parent_ids != [] do
    parent_names =
      parent_ids
      |> Enum.map(fn id ->
        case Enum.find(all_parents, fn p -> Map.get(p, :id) == id end) do
          nil -> "#{id}"
          p -> Map.get(p.design, :name, "#{id}")
        end
      end)
      |> Enum.join(", ")

    "\nGeneration #{generation}, derived from: #{parent_names}\n"
  end

  defp format_lineage(generation, _, _) do
    "\nGeneration #{generation}\n"
  end

  defp format_analysis(%{analysis: analysis}) when analysis != %{} and not is_nil(analysis) do
    success_pct = Float.round((analysis[:success_rate] || 0.0) * 100, 0)
    avg_steps = Float.round((analysis[:avg_steps] || 0.0) * 1.0, 1)
    recall_pct = Float.round((analysis[:recall_provided] || 0.0) * 100, 0)
    avg_recall_len = Float.round((analysis[:avg_recall_length] || 0.0) * 1.0, 0)
    unique_states = Float.round((analysis[:unique_states] || 0.0) * 1.0, 1)
    avg_discoveries = Float.round((analysis[:avg_discoveries] || 0.0) * 1.0, 1)

    """

    Performance analysis:
    - Success rate: #{success_pct}%
    - Avg steps: #{avg_steps}
    - Recall provided: #{recall_pct}% of episodes (avg #{avg_recall_len} chars)
    - Unique states explored: #{unique_states} avg
    - Avg discoveries: #{avg_discoveries} per episode
    """
  end

  defp format_analysis(_), do: ""

  defp format_compressed_trajectories(%{compressed_trajectories: trajs})
       when is_list(trajs) and trajs != [] do
    episodes = Enum.map_join(trajs, "\n\n", &"  #{String.replace(&1, "\n", "\n  ")}")

    """
    Sample episodes:
    #{episodes}
    """
  end

  defp format_compressed_trajectories(_), do: ""
end
