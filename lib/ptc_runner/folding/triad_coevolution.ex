defmodule PtcRunner.Folding.TriadCoevolution do
  @moduledoc """
  Three-role coevolution: every individual is solver, tester, AND oracle.

  The same phenotype plays all three roles depending on interaction context:

  - **As solver**: run against a tester's modified context, produce output,
    compare to the oracle's output on that same context.
  - **As tester**: run against base context → output list of maps →
    `OutputInterpreter` replaces data source → modified context.
  - **As oracle**: run against the tester's modified context → output IS
    the expected answer that solvers must match.

  No external task definitions needed. The population defines its own tasks.

  ## Evaluation Protocol

  For each sampled triple (solver S, tester T, oracle O):
  1. Run T against base context → T_output
  2. OutputInterpreter(T.source, T_output, base_ctx) → modified_ctx
  3. Run O against modified_ctx → expected_answer
  4. Run S against modified_ctx → solver_answer
  5. Score: S passes if solver_answer == expected_answer

  ## Fitness

      fitness = w_solve * (fraction of oracle tasks passed under tester challenges)
              + w_test  * (fraction of solvers that fail under my challenges)
              + w_oracle * (my tasks hit the difficulty frontier)

  ## Constraints

  - Oracle output must be non-nil to count as a valid task
  - Tester must produce a valid data transformation (list of maps) to count
  - If tester or oracle produces invalid output, the triple is skipped
  """

  alias PtcRunner.Folding.{Alphabet, Individual, Operators, OutputInterpreter}
  alias PtcRunner.Lisp

  @default_config %{
    generations: 20,
    population_size: 30,
    genotype_length: 25,
    elitism: 3,
    tournament_size: 3,
    crossover_rate: 0.3,
    w_solve: 0.4,
    w_test: 0.3,
    w_oracle: 0.3,
    timeout: 1000,
    max_heap: 1_250_000,
    triples_per_individual: 10
  }

  @doc """
  Run three-role coevolution.

  Takes a list of base contexts. No task definitions needed — the population
  defines its own tasks through the oracle role.

  Options:
  - `:generations`, `:population_size`, `:genotype_length` — evolution params
  - `:w_solve`, `:w_test`, `:w_oracle` — fitness weights
  - `:triples_per_individual` — matchups sampled per individual per generation
  - `:seeds` — seed genotype strings
  """
  @spec run([map()], keyword()) :: map()
  def run(base_contexts, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    seeds = Keyword.get(opts, :seeds, [])

    population = init_population(seeds, config)

    IO.puts("=== Triad Coevolution ===")
    IO.puts("Pop: #{config.population_size}, Gens: #{config.generations}")
    IO.puts("Contexts: #{length(base_contexts)}")
    IO.puts("Triples/individual: #{config.triples_per_individual}")
    IO.puts("Weights: solve=#{config.w_solve} test=#{config.w_test} oracle=#{config.w_oracle}")
    IO.puts("")

    population = evaluate_population(population, base_contexts, config)
    print_generation(0, population)

    {final_pop, history} =
      Enum.reduce(1..config.generations, {population, [gen_summary(0, population)]}, fn gen,
                                                                                        {pop,
                                                                                         hist} ->
        children =
          Enum.map(1..config.population_size, fn _ -> produce_child(pop, config) end)

        all = pop ++ children
        all = evaluate_population(all, base_contexts, config)

        new_pop = select_with_role_elitism(all, config.population_size)

        print_generation(gen, new_pop)
        {new_pop, hist ++ [gen_summary(gen, new_pop)]}
      end)

    best = Enum.max_by(final_pop, & &1.fitness)

    IO.puts("\n=== Best Individual ===")
    IO.puts("Genotype: #{best.genotype}")
    IO.puts("Phenotype: #{best.source}")
    IO.puts("Fitness: #{if best.fitness, do: Float.round(best.fitness, 4), else: "nil"}")
    print_role_scores(best)

    %{population: final_pop, best: best, history: history}
  end

  # === Evaluation ===

  defp evaluate_population(population, base_contexts, config) do
    valid_pop = Enum.filter(population, & &1.valid?)

    # Pre-compute tester outputs for all valid individuals on all contexts.
    # tester_contexts: %{ind_id => %{ctx_index => modified_ctx | :identity}}
    tester_contexts = precompute_tester_contexts(valid_pop, base_contexts, config)

    # Pre-compute oracle outputs for all valid individuals on all modified contexts.
    # We compute oracle output for each (oracle, tester, ctx) triple lazily during scoring.

    Enum.map(population, fn ind ->
      if ind.valid? do
        {solve, test, oracle} =
          compute_triad_scores(ind, valid_pop, base_contexts, tester_contexts, config)

        fitness =
          config.w_solve * solve +
            config.w_test * test +
            config.w_oracle * oracle

        %{
          ind
          | fitness: fitness,
            metadata:
              Map.merge(ind.metadata, %{
                solve_score: solve,
                test_score: test,
                oracle_score: oracle
              })
        }
      else
        %{
          ind
          | fitness: 0.0,
            metadata:
              Map.merge(ind.metadata, %{
                solve_score: 0.0,
                test_score: 0.0,
                oracle_score: 0.0
              })
        }
      end
    end)
  end

  # Pre-compute what each individual produces as a tester on each context.
  defp precompute_tester_contexts(valid_pop, base_contexts, config) do
    Map.new(valid_pop, fn tester ->
      ctx_mods =
        base_contexts
        |> Enum.with_index()
        |> Map.new(fn {base_ctx, idx} ->
          tester_output = run_source(tester.source, base_ctx, config)

          modified_ctx = OutputInterpreter.interpret(tester.source, tester_output, base_ctx)

          result = if modified_ctx != base_ctx, do: modified_ctx, else: :identity
          {idx, result}
        end)

      {tester.id, ctx_mods}
    end)
  end

  # Compute solve, test, oracle scores for one individual.
  defp compute_triad_scores(ind, valid_pop, base_contexts, tester_contexts, config) do
    peers = Enum.filter(valid_pop, &(&1.id != ind.id))

    if peers == [] do
      {0.0, 0.0, 0.0}
    else
      n = config.triples_per_individual

      # Sample triples: for each trial, pick a random tester and oracle from peers
      trials =
        Enum.map(1..n, fn _ ->
          tester = Enum.random(peers)
          oracle = Enum.random(peers)
          ctx_idx = :rand.uniform(length(base_contexts)) - 1
          base_ctx = Enum.at(base_contexts, ctx_idx)

          # Get the tester's modified context
          tester_mods = Map.get(tester_contexts, tester.id, %{})

          modified_ctx =
            case Map.get(tester_mods, ctx_idx, :identity) do
              :identity -> base_ctx
              ctx -> ctx
            end

          # Oracle output on modified context = expected answer
          oracle_output = run_source(oracle.source, modified_ctx, config)

          # Solver output on modified context
          solver_output = run_source(ind.source, modified_ctx, config)

          %{
            tester_id: tester.id,
            oracle_id: oracle.id,
            oracle_output: oracle_output,
            solver_output: solver_output,
            ctx_idx: ctx_idx,
            tester_modified: Map.get(tester_mods, ctx_idx) != :identity,
            valid_task: oracle_output != nil
          }
        end)

      # --- Solve score ---
      # Fraction of valid triples where solver matches oracle
      valid_trials = Enum.filter(trials, & &1.valid_task)

      solve =
        if valid_trials == [] do
          0.0
        else
          passes = Enum.count(valid_trials, &(&1.solver_output == &1.oracle_output))
          passes / length(valid_trials)
        end

      # --- Test score ---
      # Strict gating: test_score = 0 unless the individual produces a valid
      # data transformation (list of maps that modifies context). This forces
      # the tester role to be mechanically different from solver/oracle.
      my_tester_mods = Map.get(tester_contexts, ind.id, %{})
      has_any_modification = Enum.any?(my_tester_mods, fn {_k, v} -> v != :identity end)

      test =
        if has_any_modification do
          compute_test_score(peers, my_tester_mods, base_contexts, n, config)
        else
          0.0
        end

      # --- Oracle score ---
      # When I'm the oracle: how discriminating is my task?
      # Sample triples where this individual is the oracle
      oracle_trials =
        Enum.map(1..n, fn _ ->
          tester = Enum.random(peers)
          solver = Enum.random(peers)
          ctx_idx = :rand.uniform(length(base_contexts)) - 1
          base_ctx = Enum.at(base_contexts, ctx_idx)

          tester_mods = Map.get(tester_contexts, tester.id, %{})

          modified_ctx =
            case Map.get(tester_mods, ctx_idx, :identity) do
              :identity -> base_ctx
              ctx -> ctx
            end

          my_answer = run_source(ind.source, modified_ctx, config)
          solver_answer = run_source(solver.source, modified_ctx, config)

          %{
            valid: my_answer != nil,
            solver_matches: my_answer != nil and solver_answer == my_answer
          }
        end)

      valid_oracle_trials = Enum.filter(oracle_trials, & &1.valid)

      oracle =
        if valid_oracle_trials == [] do
          0.0
        else
          pass_rate =
            Enum.count(valid_oracle_trials, & &1.solver_matches) / length(valid_oracle_trials)

          frontier_score(pass_rate)
        end

      {solve, test, oracle}
    end
  end

  defp compute_test_score(peers, my_tester_mods, base_contexts, n, config) do
    test_trials =
      Enum.map(1..n, fn _ ->
        solver = Enum.random(peers)
        oracle = Enum.random(peers)
        ctx_idx = :rand.uniform(length(base_contexts)) - 1
        base_ctx = Enum.at(base_contexts, ctx_idx)

        test_ctx =
          case Map.get(my_tester_mods, ctx_idx, :identity) do
            :identity -> base_ctx
            ctx -> ctx
          end

        oracle_out = run_source(oracle.source, test_ctx, config)
        solver_out = run_source(solver.source, test_ctx, config)

        %{
          valid: oracle_out != nil,
          solver_fails: oracle_out != nil and solver_out != oracle_out
        }
      end)

    valid_test_trials = Enum.filter(test_trials, & &1.valid)

    if valid_test_trials == [] do
      0.0
    else
      fail_rate =
        Enum.count(valid_test_trials, & &1.solver_fails) / length(valid_test_trials)

      frontier_score(fail_rate)
    end
  end

  # Difficulty frontier: peaks at 50% pass rate
  defp frontier_score(rate) do
    cond do
      rate == 0.0 -> 0.1
      rate == 1.0 -> 0.1
      true -> 1.0 - abs(rate - 0.5) * 2.0
    end
  end

  defp run_source(source, context, config) do
    case Lisp.run(source,
           context: context,
           timeout: config.timeout,
           max_heap: config.max_heap,
           filter_context: false
         ) do
      {:ok, step} -> step.return
      {:error, _} -> nil
    end
  end

  # === Selection ===

  # Per-role elitism: guarantee the top individual by each role score
  # survives, even if their overall fitness wouldn't make the cut.
  # This protects rare tester-specialists from being eliminated.
  defp select_with_role_elitism(all, pop_size) do
    sorted = Enum.sort_by(all, & &1.fitness, :desc)

    # Find best individual per role (by that role's score)
    role_elites =
      [:solve_score, :test_score, :oracle_score]
      |> Enum.map(fn role ->
        Enum.max_by(all, fn ind -> Map.get(ind.metadata, role, 0.0) end)
      end)
      |> Enum.uniq_by(& &1.id)

    # Start with role elites, then fill remaining slots from sorted
    elite_ids = MapSet.new(role_elites, & &1.id)
    remaining = Enum.reject(sorted, fn ind -> MapSet.member?(elite_ids, ind.id) end)
    slots_left = pop_size - length(role_elites)

    role_elites ++ Enum.take(remaining, slots_left)
  end

  # === Population Management ===

  defp init_population(seeds, config) do
    seed_individuals =
      Enum.map(seeds, fn g -> Individual.from_genotype(g, generation: 0) end)

    random_count = config.population_size - length(seed_individuals)

    random_individuals =
      if random_count > 0 do
        Enum.map(1..random_count, fn _ ->
          Individual.from_genotype(Alphabet.random_genotype(config.genotype_length))
        end)
      else
        []
      end

    seed_individuals ++ random_individuals
  end

  defp produce_child(population, config) do
    if :rand.uniform() < config.crossover_rate do
      a = tournament_select(population, config.tournament_size)
      b = tournament_select(population, config.tournament_size)
      {:ok, offspring} = Operators.crossover(a.genotype, b.genotype)

      Individual.from_genotype(offspring,
        parent_ids: [a.id, b.id],
        generation: a.generation + 1,
        metadata: %{operator: :crossover}
      )
    else
      parent = tournament_select(population, config.tournament_size)
      {:ok, mutated, op} = Operators.mutate(parent.genotype)

      Individual.from_genotype(mutated,
        parent_ids: [parent.id],
        generation: parent.generation + 1,
        metadata: %{operator: op}
      )
    end
  end

  defp tournament_select(population, size) do
    population
    |> Enum.take_random(min(size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  # === Reporting ===

  defp gen_summary(gen, population) do
    fitnesses = population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)

    %{
      generation: gen,
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      avg_solve: avg_meta(population, :solve_score),
      avg_test: avg_meta(population, :test_score),
      avg_oracle: avg_meta(population, :oracle_score),
      unique_phenotypes: population |> Enum.map(& &1.source) |> Enum.uniq() |> length()
    }
  end

  defp avg_meta(population, key) do
    values = Enum.map(population, fn i -> Map.get(i.metadata, key, 0.0) end)
    Enum.sum(values) / max(length(values), 1)
  end

  defp print_generation(gen, population) do
    s = gen_summary(gen, population)

    IO.puts(
      "Gen #{String.pad_leading(to_string(gen), 3)}: " <>
        "fit=#{Float.round(s.best_fitness, 3)} " <>
        "avg=#{Float.round(s.avg_fitness, 3)} " <>
        "solve=#{Float.round(s.avg_solve, 2)} " <>
        "test=#{Float.round(s.avg_test, 2)} " <>
        "oracle=#{Float.round(s.avg_oracle, 2)} " <>
        "uniq=#{s.unique_phenotypes}"
    )
  end

  defp print_role_scores(ind) do
    solve = Map.get(ind.metadata, :solve_score, 0.0)
    test = Map.get(ind.metadata, :test_score, 0.0)
    oracle = Map.get(ind.metadata, :oracle_score, 0.0)

    IO.puts(
      "Roles: solve=#{Float.round(solve, 3)} test=#{Float.round(test, 3)} oracle=#{Float.round(oracle, 3)}"
    )
  end
end
