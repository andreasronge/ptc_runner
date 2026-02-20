defmodule Alma.Archive do
  @moduledoc """
  Archive of designs with weighted sampling for ALMA's evolutionary loop.

  Entries are scored and sampled based on a combination of performance,
  novelty, and exploration frequency.

  ## Design Shape

  Designs store both live closures (for runtime) and source strings (for persistence/novelty):

      %{
        name: "...",
        description: "...",
        mem_update: closure | nil,        # live closure (runtime only)
        recall: closure | nil,            # live closure (runtime only)
        mem_update_source: "(fn ...)",    # serialized source
        recall_source: "(fn ...)"         # serialized source
      }
  """

  defstruct entries: [], next_id: 1

  @doc """
  Creates a new empty archive.
  """
  def new, do: %__MODULE__{}

  @doc """
  Adds an entry to the archive with auto-incremented id.

  Entry params should include: `:design`, `:score`, `:trajectories`,
  `:parent_ids`, `:generation`.
  """
  def add(%__MODULE__{} = archive, entry_params) do
    entry =
      Map.merge(
        %{
          id: archive.next_id,
          design: %{},
          score: 0.0,
          trajectories: [],
          parent_ids: [],
          generation: 0,
          times_sampled: 0,
          errors: [],
          analysis: %{},
          compressed_trajectories: []
        },
        entry_params
      )
      |> Map.put(:id, archive.next_id)

    %{archive | entries: archive.entries ++ [entry], next_id: archive.next_id + 1}
  end

  @doc """
  Weighted tournament selection returning k entries.

  Weight = 0.5 * score + 0.3 * novelty + 0.2 * (1 / (1 + times_sampled))

  Novelty is computed as normalized edit distance of design source code
  against the nearest neighbor in the archive.
  """
  def sample(%__MODULE__{entries: []}, _k), do: []

  def sample(%__MODULE__{} = archive, k) do
    k = min(k, length(archive.entries))

    weights =
      Enum.map(archive.entries, fn entry ->
        novelty = compute_novelty(entry, archive.entries)
        exploration = 1.0 / (1 + entry.times_sampled)
        0.5 * entry.score + 0.3 * novelty + 0.2 * exploration
      end)

    # Shift weights to be non-negative
    min_weight = Enum.min(weights)

    weights =
      if min_weight < 0 do
        Enum.map(weights, &(&1 - min_weight + 0.01))
      else
        Enum.map(weights, &max(&1, 0.01))
      end

    entries_with_weights = Enum.zip(archive.entries, weights)
    selected = weighted_select(entries_with_weights, k, [])

    # Increment times_sampled for selected entries
    selected_ids = MapSet.new(selected, & &1.id)

    updated_entries =
      Enum.map(archive.entries, fn entry ->
        if MapSet.member?(selected_ids, entry.id) do
          %{entry | times_sampled: entry.times_sampled + 1}
        else
          entry
        end
      end)

    {selected, %{archive | entries: updated_entries}}
  end

  @doc """
  Returns the entry with the highest score.
  """
  def best(%__MODULE__{entries: []}), do: nil
  def best(%__MODULE__{entries: entries}), do: Enum.max_by(entries, & &1.score)

  @doc """
  Returns the final_memory from the most recent archive entry, or `%{}` if empty.
  """
  def latest_memory(%__MODULE__{entries: []}), do: %{}

  def latest_memory(%__MODULE__{entries: entries}) do
    entries
    |> List.last()
    |> Map.get(:final_memory, %{})
  end

  @doc """
  Returns a summary string with archive statistics.
  """
  def summary(%__MODULE__{entries: entries}) do
    count = length(entries)

    if count == 0 do
      "Archive: empty"
    else
      scores = Enum.map(entries, & &1.score)
      avg = Enum.sum(scores) / count
      max_score = Enum.max(scores)

      "Archive: #{count} entries, avg score: #{Float.round(avg, 2)}, best: #{Float.round(max_score, 2)}"
    end
  end

  @doc """
  Seeds the archive with a null baseline design (score 0.0).
  """
  def seed_null(%__MODULE__{} = archive) do
    add(archive, %{
      design: %{
        name: "null",
        description: "No-op baseline with no memory",
        mem_update: nil,
        recall: nil,
        mem_update_source: "",
        recall_source: "",
        namespace: %{}
      },
      score: 0.0,
      trajectories: [],
      parent_ids: [],
      generation: 0
    })
  end

  @doc """
  Seeds the archive with a spatial baseline that uses vector store tools.

  The design stores item locations and room connections via `tool/store-obs`
  and retrieves relevant spatial knowledge via `tool/find-similar` during recall.
  """
  def seed_spatial(%__MODULE__{} = archive) do
    source = spatial_baseline_source()

    case PtcRunner.Lisp.run(source) do
      {:ok, step} ->
        mem_update = step.memory[:"mem-update"]
        recall = step.memory[:recall]

        design = %{
          name: "spatial_baseline",
          description:
            "Builds graph from exits, stores objects by collection, provides pathfinding in recall",
          mem_update: mem_update,
          recall: recall,
          mem_update_source: PtcRunner.Lisp.CoreToSource.serialize_closure(mem_update),
          recall_source: PtcRunner.Lisp.CoreToSource.serialize_closure(recall),
          namespace: step.memory
        }

        add(archive, %{
          design: design,
          score: 0.0,
          trajectories: [],
          parent_ids: [],
          generation: 0
        })

      {:error, _reason} ->
        # Fall back to just null if spatial source fails to compile
        archive
    end
  end

  defp spatial_baseline_source do
    ~S"""
    (do
      (defn mem-update []
        ;; Always extract spatial and object data — failed episodes reveal the map too
        (doseq [obs data/observation_log]
          (let [result (:result obs)
                loc (:location result)
                objects (:objects result)
                exits (:exits result)]
            (when loc
              ;; Build graph from observed room connections
              (when (seq exits)
                (tool/graph-update {"edges" (map (fn [exit] [loc exit]) exits)}))
              ;; Store object sightings in a dedicated collection
              (when (seq objects)
                (doseq [obj objects]
                  (tool/store-obs {"text" (str obj " seen in " loc)
                                   "metadata" {"item" obj "room" loc}
                                   "collection" "objects"})))))))

      (defn recall []
        (let [goal (:goal data/task)
              target (if (map? goal) (:object goal) (str goal))
              dest (if (map? goal) (:destination goal) nil)
              ;; Look up where the target was seen
              hits (tool/find-similar {"query" (str target) "k" 3 "collection" "objects"})
              item-loc (when (seq hits) (get (first hits) "metadata"))
              item-room (when item-loc (get item-loc "room"))
              ;; Compute path to destination if we know it
              start (:agent_location data/task)
              path-to-dest (when (and start dest) (tool/graph-path {"from" start "to" dest}))]
          (str
            (if item-room (str target " was seen in " item-room ". ") "")
            (if (and path-to-dest (> (count path-to-dest) 1))
              (str "Path to " dest ": " (clojure.string/join " -> " path-to-dest))
              (if dest (str "Deliver to " dest ".") "")))))

      (return {"name" "spatial_baseline"
               "description" "Builds graph from exits, stores objects by collection, provides pathfinding in recall"}))
    """
  end

  @doc """
  Saves the archive to a JSON file.

  Source strings are persisted; live closures are dropped.
  """
  def save(%__MODULE__{} = archive, path) do
    data = %{
      entries: Enum.map(archive.entries, &stringify_entry/1),
      next_id: archive.next_id
    }

    File.write!(path, Jason.encode!(data, pretty: true))
  end

  @doc """
  Loads an archive from a JSON file.

  Loaded designs have source strings but nil closures.
  Call `hydrate/1` to reconstruct live closures before evaluation.
  """
  def load(path) do
    data = path |> File.read!() |> Jason.decode!()

    entries =
      Enum.map(data["entries"], fn e ->
        %{
          id: e["id"],
          design: atomize_design(e["design"]),
          score: e["score"],
          trajectories: e["trajectories"] || [],
          parent_ids: e["parent_ids"] || [],
          generation: e["generation"] || 0,
          times_sampled: e["times_sampled"] || 0,
          errors: e["errors"] || [],
          analysis: atomize_analysis(e["analysis"]),
          compressed_trajectories: e["compressed_trajectories"] || []
        }
      end)

    %__MODULE__{entries: entries, next_id: data["next_id"]}
  end

  @doc """
  Re-hydrates loaded designs by running source strings through `Lisp.run`
  to reconstruct live closures.

  Called once after `load/1` before starting the evaluation loop.
  """
  def hydrate(%__MODULE__{} = archive) do
    entries =
      Enum.map(archive.entries, fn entry ->
        %{entry | design: hydrate_design(entry.design)}
      end)

    %{archive | entries: entries}
  end

  defp hydrate_design(design) do
    mem_update = hydrate_closure(Map.get(design, :mem_update_source, ""))
    recall = hydrate_closure(Map.get(design, :recall_source, ""))
    %{design | mem_update: mem_update, recall: recall}
  end

  defp hydrate_closure(""), do: nil
  defp hydrate_closure(nil), do: nil

  defp hydrate_closure(source) do
    case PtcRunner.Lisp.run(source) do
      {:ok, step} -> step.return
      {:error, _} -> nil
    end
  end

  defp stringify_entry(entry) do
    design = entry.design

    # Strip live closures, keep only serializable fields
    serializable_design = %{
      name: Map.get(design, :name),
      description: Map.get(design, :description),
      mem_update_source: Map.get(design, :mem_update_source, ""),
      recall_source: Map.get(design, :recall_source, "")
    }

    %{
      id: entry.id,
      design: serializable_design,
      score: entry.score,
      trajectories: entry.trajectories,
      parent_ids: entry.parent_ids,
      generation: entry.generation,
      times_sampled: entry.times_sampled,
      errors: Map.get(entry, :errors, []),
      analysis: Map.get(entry, :analysis, %{}),
      compressed_trajectories: Map.get(entry, :compressed_trajectories, [])
    }
  end

  defp atomize_analysis(nil), do: %{}

  defp atomize_analysis(analysis) when is_map(analysis) do
    Map.new(analysis, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> %{}
  end

  defp atomize_design(design) when is_map(design) do
    Map.new(design, fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.merge(%{mem_update: nil, recall: nil})
  rescue
    ArgumentError -> design
  end

  defp compute_novelty(entry, all_entries) do
    others = Enum.reject(all_entries, &(&1.id == entry.id))

    if others == [] do
      1.0
    else
      distances =
        Enum.map(others, fn other ->
          ast_novelty(entry.design, other.design)
        end)

      Enum.min(distances)
    end
  end

  defp ast_novelty(design_a, design_b) do
    code_a = design_code_string(design_a)
    code_b = design_code_string(design_b)

    with {:ok, ast_a} <- PtcRunner.Lisp.Parser.parse(code_a),
         {:ok, ast_b} <- PtcRunner.Lisp.Parser.parse(code_b) do
      diffs = ast_diff_count(ast_a, ast_b)
      total = ast_node_count(ast_a) + ast_node_count(ast_b)

      if total == 0, do: 0.0, else: diffs / total
    else
      _ -> normalized_edit_distance(code_a, code_b)
    end
  end

  defp ast_node_count(nodes) when is_list(nodes) do
    1 + Enum.sum(Enum.map(nodes, &ast_node_count/1))
  end

  defp ast_node_count(_leaf), do: 1

  defp ast_diff_count(a, b) when is_list(a) and is_list(b) do
    base = if length(a) == length(b), do: 0, else: abs(length(a) - length(b))
    pairs = Enum.zip(a, b)
    base + Enum.sum(Enum.map(pairs, fn {x, y} -> ast_diff_count(x, y) end))
  end

  defp ast_diff_count(a, a), do: 0
  defp ast_diff_count(_, _), do: 1

  defp design_code_string(design) do
    mem_update = Map.get(design, :mem_update_source, "") || ""
    recall = Map.get(design, :recall_source, "") || ""
    mem_update <> recall
  end

  defp normalized_edit_distance("", ""), do: 0.0

  defp normalized_edit_distance(a, b) do
    if String.length(a) > 200 and String.length(b) > 200 do
      # Use Jaro distance as a fast approximation for long strings
      1.0 - String.jaro_distance(a, b)
    else
      dist = edit_distance(String.graphemes(a), String.graphemes(b))
      max_len = max(String.length(a), String.length(b))
      dist / max_len
    end
  end

  # Iterative two-row DP edit distance — O(m*n) instead of O(3^n)
  defp edit_distance([], b), do: length(b)
  defp edit_distance(a, []), do: length(a)

  defp edit_distance(a, b) do
    n = length(b)
    b_tuple = List.to_tuple(b)

    initial_row = List.to_tuple(Enum.to_list(0..n))

    final_row =
      a
      |> Enum.with_index(1)
      |> Enum.reduce(initial_row, fn {char_a, i}, prev_row ->
        first_cell = i

        {row_list, _} =
          Enum.reduce(0..(n - 1), {[first_cell], first_cell}, fn j, {acc, prev_val} ->
            char_b = elem(b_tuple, j)
            cost = if char_a == char_b, do: 0, else: 1

            val =
              Enum.min([
                prev_val + 1,
                elem(prev_row, j + 1) + 1,
                elem(prev_row, j) + cost
              ])

            {[val | acc], val}
          end)

        row_list |> Enum.reverse() |> List.to_tuple()
      end)

    elem(final_row, n)
  end

  defp weighted_select(_entries_with_weights, 0, acc), do: Enum.reverse(acc)
  defp weighted_select([], _k, acc), do: Enum.reverse(acc)

  defp weighted_select(entries_with_weights, k, acc) do
    total = entries_with_weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    point = :rand.uniform() * total

    {selected, _} = select_by_weight(entries_with_weights, point)
    remaining = Enum.reject(entries_with_weights, fn {e, _} -> e.id == selected.id end)
    weighted_select(remaining, k - 1, [selected | acc])
  end

  defp select_by_weight([{entry, _weight}], _point), do: {entry, 0}

  defp select_by_weight([{entry, weight} | rest], point) do
    if point <= weight do
      {entry, 0}
    else
      select_by_weight(rest, point - weight)
    end
  end
end
