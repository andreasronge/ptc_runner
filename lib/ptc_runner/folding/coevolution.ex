defmodule PtcRunner.Folding.Coevolution do
  @moduledoc """
  Single-population coevolution for folded genotypes.

  Every individual plays two roles determined by interaction context:

  - **Solver**: run the phenotype against a test case, produce output
  - **Tester**: the phenotype itself defines a test case — run it against the
    base context to get the expected output, then other individuals must match

  A good tester creates problems that are solvable (its own phenotype produces
  a valid, non-trivial output) and discriminating (not all solvers can match it).
  A good solver handles many different tests. This creates an arms race within
  a single population.

  ## Fitness

      fitness = w_solve * solve_score
             + w_test  * test_effectiveness
             + w_robust * robustness

  - `solve_score`: fraction of peer tests solved correctly
  - `test_effectiveness`: fraction of peers that fail on my test (0 if my test is degenerate)
  - `robustness`: fraction of static baseline problems solved

  See `docs/plans/folding-evolution.md` for design.
  """

  alias PtcRunner.Evolve.Evaluator
  alias PtcRunner.Evolve.Individual, as: EvolveIndividual
  alias PtcRunner.Folding.{Alphabet, Individual, Operators}
  alias PtcRunner.Lisp

  @type config :: %{
          generations: pos_integer(),
          population_size: pos_integer(),
          genotype_length: pos_integer(),
          elitism: pos_integer(),
          tournament_size: pos_integer(),
          crossover_rate: float(),
          w_solve: float(),
          w_test: float(),
          w_robust: float(),
          timeout: pos_integer(),
          max_heap: pos_integer()
        }

  @default_config %{
    generations: 20,
    population_size: 30,
    genotype_length: 20,
    elitism: 3,
    tournament_size: 3,
    crossover_rate: 0.3,
    w_solve: 0.4,
    w_test: 0.3,
    w_robust: 0.3,
    timeout: 1000,
    max_heap: 1_250_000
  }

  @doc """
  Run coevolution.

  Takes a list of context variations — multiple data environments that programs
  are evaluated against. Using multiple contexts prevents collusion: a program
  that hardcodes `500` will always output `500` regardless of context, but
  `(count data/products)` outputs different values for different list sizes.
  Tests discriminate by requiring correct output across ALL contexts.

  Options:
  - `:generations` — number of generations (default 20)
  - `:population_size` — population size (default 30)
  - `:genotype_length` — initial genotype length (default 20)
  - `:seeds` — seed genotype strings (optional)
  - `:static_problems` — baseline problems for robustness scoring
  - `:w_solve` — weight for solver score (default 0.4)
  - `:w_test` — weight for tester effectiveness (default 0.3)
  - `:w_robust` — weight for static problem robustness (default 0.3)
  """
  @spec run([map()], keyword()) :: map()
  def run(contexts, opts \\ []) when is_list(contexts) do
    config = Map.merge(@default_config, Map.new(opts))
    static_problems = Keyword.get(opts, :static_problems, [])
    seeds = Keyword.get(opts, :seeds, [])

    population = init_population(seeds, config)

    IO.puts("=== Folding Coevolution ===")
    IO.puts("Population: #{config.population_size}, Generations: #{config.generations}")
    IO.puts("Contexts: #{length(contexts)}")
    IO.puts("Weights: solve=#{config.w_solve} test=#{config.w_test} robust=#{config.w_robust}")
    IO.puts("")

    # Evaluate initial population
    population = evaluate_coevolution(population, contexts, static_problems, config)
    print_generation(0, population)

    # Evolution loop
    {final_pop, history} =
      Enum.reduce(1..config.generations, {population, [gen_summary(0, population)]}, fn gen,
                                                                                        {pop,
                                                                                         hist} ->
        children =
          1..config.population_size
          |> Enum.map(fn _ -> produce_child(pop, config) end)

        # Evaluate children in context of current population (their tests matter)
        all = pop ++ children
        all = evaluate_coevolution(all, contexts, static_problems, config)

        # (mu+lambda) with elitism
        sorted = Enum.sort_by(all, & &1.fitness, :desc)
        elite = Enum.take(sorted, config.elitism)
        rest = Enum.drop(sorted, config.elitism)
        new_pop = elite ++ Enum.take(rest, config.population_size - config.elitism)

        print_generation(gen, new_pop)
        {new_pop, hist ++ [gen_summary(gen, new_pop)]}
      end)

    best = Enum.max_by(final_pop, & &1.fitness)

    IO.puts("\n=== Best Individual ===")
    IO.puts("Genotype: #{best.genotype}")
    IO.puts("Phenotype: #{best.source}")
    IO.puts("Fitness: #{if best.fitness, do: Float.round(best.fitness, 4), else: "nil"}")
    print_role_scores(best)

    %{
      population: final_pop,
      best: best,
      history: history
    }
  end

  # === Coevolutionary Evaluation ===

  defp evaluate_coevolution(population, contexts, static_problems, config) do
    # Step 1: Compute output profile for each individual across all contexts.
    # An output profile is a list of outputs, one per context.
    # Programs that compute (e.g., count) have varied profiles.
    # Programs that hardcode (e.g., 500) have uniform profiles.
    profiles = compute_output_profiles(population, contexts, config)

    # Step 2: For each tester, count how many peers match on ALL contexts.
    # A solver "passes" a tester's test only if its profile matches exactly.
    {solve_scores, test_scores} = compute_coevolution_scores(population, profiles)

    # Step 3: Evaluate against static problems (robustness)
    robust_scores = evaluate_robustness(population, static_problems, config)

    # Step 4: Combine into final fitness
    Enum.map(population, fn ind ->
      solve = Map.get(solve_scores, ind.id, 0.0)
      test = Map.get(test_scores, ind.id, 0.0)
      robust = Map.get(robust_scores, ind.id, 0.0)

      fitness =
        config.w_solve * solve +
          config.w_test * test +
          config.w_robust * robust

      %{
        ind
        | fitness: fitness,
          metadata:
            Map.merge(ind.metadata, %{
              solve_score: solve,
              test_score: test,
              robust_score: robust
            })
      }
    end)
  end

  # Compute the output of each individual across all context variations.
  # Returns %{individual_id => [output_ctx1, output_ctx2, ...] | :invalid}
  defp compute_output_profiles(population, contexts, config) do
    Map.new(population, fn ind ->
      {ind.id, compute_individual_profile(ind, contexts, config)}
    end)
  end

  defp compute_individual_profile(%{valid?: false}, _contexts, _config), do: :invalid

  defp compute_individual_profile(ind, contexts, config) do
    outputs =
      Enum.map(contexts, fn ctx ->
        case run_phenotype(ind.source, ctx, config) do
          {:ok, output} -> output
          _ -> :error
        end
      end)

    if Enum.any?(outputs, &(&1 == :error)), do: :invalid, else: outputs
  end

  # Compute solve and test scores from output profiles.
  # A solver "passes" a tester if their profiles match exactly (same output on every context).
  # Solve score: fraction of peers whose test I pass.
  # Test score: peaks at ~50% pass rate (difficulty frontier).
  defp compute_coevolution_scores(population, profiles) do
    valid_ids =
      profiles
      |> Enum.reject(fn {_id, profile} -> profile == :invalid end)
      |> Enum.map(fn {id, _} -> id end)
      |> MapSet.new()

    # For each pair (solver, tester), does solver's profile match tester's?
    # Build a match matrix: %{tester_id => MapSet of solver_ids that match}
    match_matrix =
      Map.new(valid_ids, fn tester_id ->
        tester_profile = Map.get(profiles, tester_id)

        matchers =
          valid_ids
          |> Enum.filter(fn solver_id ->
            solver_id != tester_id and Map.get(profiles, solver_id) == tester_profile
          end)
          |> MapSet.new()

        {tester_id, matchers}
      end)

    peer_count = max(MapSet.size(valid_ids) - 1, 1)

    # Solve score: what fraction of peer tests do I pass?
    solve_scores =
      Map.new(population, fn ind ->
        if MapSet.member?(valid_ids, ind.id) do
          my_profile = Map.get(profiles, ind.id)

          tests_passed =
            valid_ids
            |> Enum.count(fn tester_id ->
              tester_id != ind.id and Map.get(profiles, tester_id) == my_profile
            end)

          {ind.id, tests_passed / peer_count}
        else
          {ind.id, 0.0}
        end
      end)

    # Test score: how discriminating is my test?
    # Best at ~50% pass rate. Trivial (everyone passes) or degenerate (no one) = low.
    test_scores =
      Map.new(population, fn ind ->
        if MapSet.member?(valid_ids, ind.id) do
          matchers = Map.get(match_matrix, ind.id, MapSet.new())
          pass_rate = MapSet.size(matchers) / peer_count

          effectiveness =
            cond do
              peer_count == 0 -> 0.0
              pass_rate == 0.0 -> 0.1
              pass_rate == 1.0 -> 0.1
              true -> 1.0 - abs(pass_rate - 0.5) * 2.0
            end

          {ind.id, effectiveness}
        else
          {ind.id, 0.0}
        end
      end)

    {solve_scores, test_scores}
  end

  # Evaluate against static problems for robustness baseline
  defp evaluate_robustness(population, [], _config) do
    Map.new(population, fn ind -> {ind.id, 0.0} end)
  end

  defp evaluate_robustness(population, static_problems, config) do
    Map.new(population, fn ind ->
      {ind.id, individual_robustness(ind, static_problems, config)}
    end)
  end

  defp individual_robustness(%{valid?: false}, _problems, _config), do: 0.0

  defp individual_robustness(ind, problems, config) do
    scores =
      Enum.map(problems, fn problem ->
        case EvolveIndividual.from_source(ind.source) do
          {:ok, eval_ind} ->
            result =
              Evaluator.evaluate(eval_ind, problem, %{
                lambda_llm: 0.0,
                lambda_size: 0.0,
                timeout: config.timeout,
                max_heap: config.max_heap
              })

            Evaluator.partial_score(result, problem)

          {:error, _} ->
            0.0
        end
      end)

    Enum.sum(scores) / max(length(scores), 1)
  end

  # === Helpers ===

  defp run_phenotype(source, context, config) do
    case Lisp.run(source, context: context, timeout: config.timeout, max_heap: config.max_heap) do
      {:ok, step} -> {:ok, step.return}
      {:error, _} -> :error
    end
  end

  # === Population Management ===

  defp init_population(seeds, config) do
    seed_individuals =
      Enum.map(seeds, fn g -> Individual.from_genotype(g, generation: 0) end)

    random_count = config.population_size - length(seed_individuals)

    random_individuals =
      if random_count > 0 do
        Enum.map(1..random_count, fn _ ->
          genotype = Alphabet.random_genotype(config.genotype_length)
          Individual.from_genotype(genotype, generation: 0)
        end)
      else
        []
      end

    seed_individuals ++ random_individuals
  end

  defp produce_child(population, config) do
    roll = :rand.uniform()

    if roll < config.crossover_rate do
      parent_a = tournament_select(population, config.tournament_size)
      parent_b = tournament_select(population, config.tournament_size)
      {:ok, offspring_genotype} = Operators.crossover(parent_a.genotype, parent_b.genotype)

      Individual.from_genotype(offspring_genotype,
        parent_ids: [parent_a.id, parent_b.id],
        generation: parent_a.generation + 1,
        metadata: %{operator: :crossover}
      )
    else
      parent = tournament_select(population, config.tournament_size)
      {:ok, mutated_genotype, op} = Operators.mutate(parent.genotype)

      Individual.from_genotype(mutated_genotype,
        parent_ids: [parent.id],
        generation: parent.generation + 1,
        metadata: %{operator: op}
      )
    end
  end

  defp tournament_select(population, tournament_size) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  # === Reporting ===

  defp gen_summary(gen, population) do
    fitnesses = population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)
    valid_count = Enum.count(population, & &1.valid?)

    solve_scores =
      population
      |> Enum.map(fn i -> Map.get(i.metadata, :solve_score, 0.0) end)

    test_scores =
      population
      |> Enum.map(fn i -> Map.get(i.metadata, :test_score, 0.0) end)

    %{
      generation: gen,
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      valid_count: valid_count,
      population_size: length(population),
      avg_solve: Enum.sum(solve_scores) / max(length(solve_scores), 1),
      avg_test: Enum.sum(test_scores) / max(length(test_scores), 1),
      unique_phenotypes: population |> Enum.map(& &1.source) |> Enum.uniq() |> length()
    }
  end

  defp print_generation(gen, population) do
    s = gen_summary(gen, population)

    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(gen), 3)}: " <>
        "fit=#{Float.round(s.best_fitness, 3)} " <>
        "avg=#{Float.round(s.avg_fitness, 3)} " <>
        "solve=#{Float.round(s.avg_solve, 2)} " <>
        "test=#{Float.round(s.avg_test, 2)} " <>
        "uniq=#{s.unique_phenotypes} " <>
        "valid=#{s.valid_count}/#{s.population_size}"
    )
  end

  defp print_role_scores(ind) do
    solve = Map.get(ind.metadata, :solve_score, 0.0)
    test = Map.get(ind.metadata, :test_score, 0.0)
    robust = Map.get(ind.metadata, :robust_score, 0.0)

    IO.puts(
      "Roles: solve=#{Float.round(solve, 3)} test=#{Float.round(test, 3)} robust=#{Float.round(robust, 3)}"
    )
  end
end
