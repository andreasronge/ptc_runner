defmodule PtcRunner.Meta.MetaEvaluator do
  @moduledoc """
  Evaluates a MetaLearner M by running the inner evolution loop with M
  controlling operator selection.

  For each M variant, runs the existing `Evolve.Loop` with a custom
  `operator_selector` callback that delegates to M's PTC-Lisp cond-tree.
  M's fitness is based on solver performance minus LLM token cost.
  """

  alias PtcRunner.Evolve.{Evaluator, Loop}
  alias PtcRunner.Meta.{FailureVector, MetaLearner}

  @type eval_result :: %{
          fitness: float(),
          solve_rate: float(),
          total_llm_tokens: non_neg_integer(),
          per_problem: [map()],
          operator_counts: map(),
          llm_call_count: non_neg_integer(),
          llm_success_count: non_neg_integer(),
          llm_precision: float(),
          hard_solve_rate: float(),
          tokens_per_solve: float(),
          gp_sufficiency: float()
        }

  @type config :: %{
          inner_generations: pos_integer(),
          inner_population_size: pos_integer(),
          problems: [Evaluator.problem()],
          seeds: [String.t()],
          max_ast_nodes: pos_integer(),
          lambda_llm: float(),
          llm_model: String.t() | nil,
          llm_mutation_rate: float()
        }

  @default_config %{
    inner_generations: 8,
    inner_population_size: 12,
    problems: [],
    seeds: [],
    max_ast_nodes: 80,
    lambda_llm: 0.001,
    llm_model: nil,
    llm_mutation_rate: 0.0
  }

  @doc """
  Evaluate a MetaLearner M against a set of problems.

  Runs the inner evolution loop for each problem with M controlling GP operator
  selection. Returns M's fitness and detailed per-problem results.
  """
  @spec evaluate(MetaLearner.t(), keyword()) :: eval_result()
  def evaluate(%MetaLearner{} = m, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    {selector, counter_ref} = build_selector(m, config)

    per_problem =
      Enum.map(config.problems, fn problem ->
        result =
          Loop.run(config.seeds, problem,
            generations: config.inner_generations,
            population_size: config.inner_population_size,
            max_ast_nodes: config.max_ast_nodes,
            operator_selector: selector,
            llm_model: config.llm_model,
            llm_mutation_rate: config.llm_mutation_rate
          )

        best = result.best
        solved = best.fitness != nil and best.fitness > 0.99

        %{
          problem: problem.name,
          solved: solved,
          best_fitness: best.fitness || 0.0,
          llm_tokens: Map.get(result, :total_llm_tokens, 0),
          best_source: best.source
        }
      end)

    operator_counts = get_operator_counts(counter_ref)

    total_problems = length(per_problem)
    solved_count = Enum.count(per_problem, & &1.solved)
    solve_rate = if total_problems > 0, do: solved_count / total_problems, else: 0.0

    total_llm_tokens =
      Enum.reduce(per_problem, 0, fn p, acc -> acc + p.llm_tokens end)

    fitness = solve_rate - config.lambda_llm * total_llm_tokens

    # LLM call metrics
    # llm_call_count: how many times M selected :llm_mutation (operator invocations)
    llm_call_count = Map.get(operator_counts, :llm_mutation, 0)
    # llm_problems_with_tokens: how many problems had LLM tokens spent on them
    llm_problems_with_tokens = Enum.count(per_problem, &(&1.llm_tokens > 0))
    llm_solved = Enum.count(per_problem, &(&1.solved and &1.llm_tokens > 0))

    # Hard problem metrics (cross-dataset problems have "cross" in name or description)
    hard_problems = Enum.filter(per_problem, &hard_problem?/1)
    hard_total = length(hard_problems)
    hard_solved = Enum.count(hard_problems, & &1.solved)
    hard_solve_rate = if hard_total > 0, do: hard_solved / hard_total, else: 0.0

    # Tokens per solve
    tokens_per_solve =
      if solved_count > 0, do: total_llm_tokens / solved_count, else: 0.0

    # GP sufficiency: problems solved without LLM tokens
    gp_solved = Enum.count(per_problem, &(&1.solved and &1.llm_tokens == 0))
    gp_sufficiency = if solved_count > 0, do: gp_solved / solved_count, else: 0.0

    %{
      fitness: fitness,
      solve_rate: solve_rate,
      total_llm_tokens: total_llm_tokens,
      per_problem: per_problem,
      operator_counts: operator_counts,
      llm_call_count: llm_call_count,
      llm_success_count: llm_solved,
      llm_precision:
        if(llm_problems_with_tokens > 0, do: llm_solved / llm_problems_with_tokens, else: 0.0),
      hard_solve_rate: hard_solve_rate,
      tokens_per_solve: tokens_per_solve,
      gp_sufficiency: gp_sufficiency
    }
  end

  @doc """
  Compute the Shannon entropy of operator selection distribution.

  Returns a float in [0, log2(6)] where 0 = always same operator,
  log2(6) ~= 2.58 = perfectly uniform.
  """
  @spec operator_entropy(map()) :: float()
  def operator_entropy(operator_counts) do
    total = Enum.sum(Map.values(operator_counts))

    if total == 0 do
      0.0
    else
      operator_counts
      |> Map.values()
      |> Enum.reject(&(&1 == 0))
      |> Enum.map(fn count ->
        p = count / total
        -p * :math.log2(p)
      end)
      |> Enum.sum()
    end
  end

  defp hard_problem?(%{problem: name}) do
    String.contains?(name, "cross") or String.contains?(name, "grouped")
  end

  defp build_selector(m, config) do
    operators = FailureVector.valid_operators()
    counter_ref = :counters.new(length(operators), [:atomics])

    operator_index =
      operators
      |> Enum.with_index(1)
      |> Map.new()

    max_ast_nodes = config.max_ast_nodes

    selector = fn %PtcRunner.Evolve.Individual{} = individual ->
      fv = FailureVector.from_individual(individual, max_ast_nodes: max_ast_nodes)
      op = MetaLearner.select_operator(m, fv)

      idx = Map.get(operator_index, op, 1)
      :counters.add(counter_ref, idx, 1)

      op
    end

    {selector, counter_ref}
  end

  defp get_operator_counts(counter_ref) do
    FailureVector.valid_operators()
    |> Enum.with_index(1)
    |> Map.new(fn {op, idx} -> {op, :counters.get(counter_ref, idx)} end)
  end
end
