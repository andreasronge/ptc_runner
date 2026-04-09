defmodule PtcRunner.Meta.Seeds do
  @moduledoc """
  Seed populations for the three-species coevolution system.

  - M variants: PTC-Lisp cond-trees that select operators (including :llm_mutation)
  - Authors: PTC-Lisp programs that generate problems of varying difficulty
  - Baselines: fixed M variants for comparison
  """

  alias PtcRunner.Meta.{Author, MetaLearner}

  # --- M Seeds ---

  @doc """
  Returns the 4 seed M variants for the initial parent pool.
  Updated with :llm_mutation as the 7th operator option.
  """
  @spec seeds() :: [MetaLearner.t()]
  def seeds do
    [
      seed_random(),
      seed_conservative(),
      seed_llm_aware(),
      seed_adaptive()
    ]
  end

  @doc """
  Returns the 3 baseline M variants (fixed, non-evolving).
  """
  @spec baselines() :: [MetaLearner.t()]
  def baselines do
    [
      baseline_gp_only(),
      baseline_llm_always(),
      baseline_handwritten()
    ]
  end

  # --- Author Seeds ---

  @doc """
  Returns 6 seed Authors spanning easy to hard problems.
  """
  @spec author_seeds() :: [Author.t()]
  def author_seeds do
    [
      author_count_all(),
      author_count_filtered(),
      author_avg_filtered(),
      author_compound_filter(),
      author_cross_dataset(),
      author_grouped_count()
    ]
  end

  # --- M Seed Implementations ---

  defp seed_random do
    source = """
    (fn [fv]
      (let [score (get fv :partial_score)
            pick (mod (int (* score 1000)) 7)]
        (cond
          (= pick 0) :point_mutation
          (= pick 1) :arg_swap
          (= pick 2) :wrap_form
          (= pick 3) :subtree_delete
          (= pick 4) :subtree_dup
          (= pick 5) :crossover
          :else :llm_mutation)))
    """

    {:ok, m} = MetaLearner.from_source(String.trim(source), id: "seed-random", generation: 0)
    m
  end

  defp seed_conservative do
    # Prefers cheap GP ops, only calls LLM when completely stuck
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error) :point_mutation
        (get fv :timeout)       :subtree_delete
        (get fv :size_bloat)    :subtree_delete
        (get fv :wrong_type)    :arg_swap
        (get fv :no_improvement) :crossover
        :else                   :point_mutation))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "seed-conservative", generation: 0)

    m
  end

  defp seed_llm_aware do
    # Uses LLM for hard cases (low score, wrong type), GP for easy refinements
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error)            :point_mutation
        (get fv :wrong_type)               :llm_mutation
        (< (get fv :partial_score) 0.2)    :llm_mutation
        (get fv :size_bloat)               :subtree_delete
        (< (get fv :partial_score) 0.7)    :arg_swap
        :else                              :point_mutation))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "seed-llm-aware", generation: 0)

    m
  end

  defp seed_adaptive do
    # Balanced: LLM for structural problems, GP for numeric refinement
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error)            :point_mutation
        (get fv :timeout)                  :subtree_delete
        (get fv :size_bloat)               :subtree_delete
        (get fv :wrong_type)               :llm_mutation
        (< (get fv :partial_score) 0.3)    :llm_mutation
        (get fv :no_improvement)           :crossover
        (< (get fv :partial_score) 0.8)    :arg_swap
        :else                              :point_mutation))
    """

    {:ok, m} = MetaLearner.from_source(String.trim(source), id: "seed-adaptive", generation: 0)
    m
  end

  # --- Baselines ---

  defp baseline_gp_only do
    # Never calls LLM — pure GP baseline
    source = "(fn [fv] :point_mutation)"
    {:ok, m} = MetaLearner.from_source(source, id: "baseline-gp-only", generation: 0)
    m
  end

  defp baseline_llm_always do
    # Always calls LLM — maximum token spend
    source = "(fn [fv] :llm_mutation)"
    {:ok, m} = MetaLearner.from_source(source, id: "baseline-llm-always", generation: 0)
    m
  end

  defp baseline_handwritten do
    # Hand-tuned: LLM for hard cases only
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error) :point_mutation
        (get fv :timeout)       :subtree_delete
        (get fv :size_bloat)    :subtree_delete
        (< (get fv :partial_score) 0.2) :llm_mutation
        (< (get fv :partial_score) 0.8) :arg_swap
        :else                           :point_mutation))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "baseline-handwritten", generation: 0)

    m
  end

  # --- Author Seed Implementations ---

  defp author_count_all do
    {:ok, a} =
      Author.from_source(
        "(count data/products)",
        id: "author-count-all",
        output_type: :integer,
        description: "Count all products"
      )

    a
  end

  defp author_count_filtered do
    {:ok, a} =
      Author.from_source(
        ~s|(count (filter (fn [p] (> (get p "price") 500)) data/products))|,
        id: "author-count-filtered",
        output_type: :integer,
        description: "Count products with price above 500"
      )

    a
  end

  defp author_avg_filtered do
    {:ok, a} =
      Author.from_source(
        ~s|(let [items (filter (fn [o] (= (get o "status") "delivered")) data/orders)] (/ (reduce + 0 (map (fn [o] (get o "total")) items)) (count items)))|,
        id: "author-avg-filtered",
        output_type: :number,
        description: "Average total of delivered orders"
      )

    a
  end

  defp author_compound_filter do
    {:ok, a} =
      Author.from_source(
        ~s|(count (filter (fn [p] (and (> (get p "price") 700) (= (get p "status") "active"))) data/products))|,
        id: "author-compound-filter",
        output_type: :integer,
        description: "Count active products with price above 700"
      )

    a
  end

  defp author_cross_dataset do
    {:ok, a} =
      Author.from_source(
        ~s|(let [eng-ids (set (map (fn [e] (get e "id")) (filter (fn [e] (= (get e "department") "engineering")) data/employees))) eng-expenses (filter (fn [ex] (contains? eng-ids (get ex "employee_id"))) data/expenses)] (count eng-expenses))|,
        id: "author-cross-dataset",
        output_type: :integer,
        description: "Count expenses for engineering department employees"
      )

    a
  end

  defp author_grouped_count do
    {:ok, a} =
      Author.from_source(
        ~s|(let [grouped (group-by (fn [e] (get e "department")) data/employees)] (into {} (map (fn [[k v]] [k (count v)]) grouped)))|,
        id: "author-grouped-count",
        output_type: :map,
        description: "Count employees per department"
      )

    a
  end
end
