defmodule PtcRunner.Meta.Seeds do
  @moduledoc """
  Seed MetaLearner variants for Phase A.

  Four hand-written M strategies with different operator selection behaviors,
  plus three baselines (random, hand-written, LLM-heavy) implemented as
  fixed M variants that run through the same evaluation pipeline.
  """

  alias PtcRunner.Meta.MetaLearner

  @doc """
  Returns the 4 seed M variants for the initial parent pool.
  """
  @spec seeds() :: [MetaLearner.t()]
  def seeds do
    [
      seed_random(),
      seed_conservative(),
      seed_aggressive(),
      seed_adaptive()
    ]
  end

  @doc """
  Returns the 3 baseline M variants (fixed, non-evolving).
  """
  @spec baselines() :: [MetaLearner.t()]
  def baselines do
    [
      baseline_random(),
      baseline_handwritten(),
      baseline_llm_heavy()
    ]
  end

  # --- Seeds ---

  defp seed_random do
    # Ignores failure vector, picks a random operator via hash of partial_score
    source = """
    (fn [fv]
      (let [score (get fv :partial_score)
            pick (mod (int (* score 1000)) 6)]
        (cond
          (= pick 0) :point_mutation
          (= pick 1) :arg_swap
          (= pick 2) :wrap_form
          (= pick 3) :subtree_delete
          (= pick 4) :subtree_dup
          :else :crossover)))
    """

    {:ok, m} = MetaLearner.from_source(String.trim(source), id: "seed-random", generation: 0)
    m
  end

  defp seed_conservative do
    # Prefers small changes: point_mutation and arg_swap
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error) :point_mutation
        (get fv :timeout)       :subtree_delete
        (get fv :wrong_type)    :point_mutation
        (get fv :size_bloat)    :subtree_delete
        :else                   :arg_swap))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "seed-conservative", generation: 0)

    m
  end

  defp seed_aggressive do
    # Prefers big structural changes: crossover and subtree_dup
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error) :subtree_dup
        (get fv :size_bloat)    :subtree_delete
        (< (get fv :partial_score) 0.5) :crossover
        :else                   :subtree_dup))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "seed-aggressive", generation: 0)

    m
  end

  defp seed_adaptive do
    # Uses partial_score threshold to switch strategies
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error)            :point_mutation
        (get fv :timeout)                  :subtree_delete
        (get fv :size_bloat)               :subtree_delete
        (get fv :wrong_type)               :arg_swap
        (< (get fv :partial_score) 0.3)    :crossover
        (get fv :no_improvement)           :subtree_dup
        :else                              :point_mutation))
    """

    {:ok, m} = MetaLearner.from_source(String.trim(source), id: "seed-adaptive", generation: 0)
    m
  end

  # --- Baselines (fixed, non-evolving) ---

  defp baseline_random do
    # True random: always returns point_mutation (simplest baseline)
    source = "(fn [fv] :point_mutation)"
    {:ok, m} = MetaLearner.from_source(source, id: "baseline-random", generation: 0)
    m
  end

  defp baseline_handwritten do
    # Best hand-tuned strategy from evolve-findings experiments
    source = """
    (fn [fv]
      (cond
        (get fv :compile_error) :point_mutation
        (get fv :timeout)       :subtree_delete
        (get fv :size_bloat)    :subtree_delete
        (< (get fv :partial_score) 0.2) :crossover
        (< (get fv :partial_score) 0.8) :arg_swap
        :else                           :point_mutation))
    """

    {:ok, m} =
      MetaLearner.from_source(String.trim(source), id: "baseline-handwritten", generation: 0)

    m
  end

  defp baseline_llm_heavy do
    # Always returns crossover — forces structural changes, contrasting with
    # baseline_random which always uses point_mutation (minimal changes)
    source = "(fn [fv] :crossover)"
    {:ok, m} = MetaLearner.from_source(source, id: "baseline-llm-heavy", generation: 0)
    m
  end
end
