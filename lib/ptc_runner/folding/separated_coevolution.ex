defmodule PtcRunner.Folding.SeparatedCoevolution do
  @moduledoc """
  Three-population coevolution: solvers, testers, and oracles evolve separately.

  Each population evolves one thing well with unambiguous selection pressure:

  - **Solvers**: produce correct answers on modified contexts.
    Fitness = fraction of (tester, oracle) pairs where solver matches oracle.
  - **Testers**: produce context modifications (list of maps).
    Fitness = frontier_score(solver pass rate under my modification).
    Must produce a valid data transformation or fitness = 0.
  - **Oracles**: produce expected answers on modified contexts.
    Fitness = frontier_score(solver pass rate on my task).
    Must produce non-nil output or fitness = 0.

  ## Arms Race

  - Testers evolve modifications that break solvers
  - Solvers evolve robustness to tester modifications
  - Oracles evolve tasks at the difficulty frontier
  """

  alias PtcRunner.Folding.{Alphabet, Individual, Operators, OutputInterpreter}
  alias PtcRunner.Lisp

  @default_config %{
    generations: 20,
    solver_pop: 20,
    tester_pop: 20,
    oracle_pop: 20,
    genotype_length: 25,
    tester_genotype_length: nil,
    elitism: 2,
    tournament_size: 3,
    crossover_rate: 0.3,
    samples: 10,
    timeout: 1000,
    max_heap: 1_250_000
  }

  @doc """
  Run three-population coevolution.

  Options:
  - `:generations` — number of generations
  - `:solver_pop`, `:tester_pop`, `:oracle_pop` — population sizes
  - `:genotype_length` — default genotype length for all populations
  - `:tester_genotype_length` — override genotype length for testers (default: genotype_length)
  - `:samples` — matchups sampled per individual per generation
  - `:solver_seeds`, `:tester_seeds`, `:oracle_seeds` — seed genotype strings
  """
  @spec run([map()], keyword()) :: map()
  def run(base_contexts, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))

    config =
      if config.tester_genotype_length == nil do
        %{config | tester_genotype_length: config.genotype_length}
      else
        config
      end

    solver_seeds = Keyword.get(opts, :solver_seeds, [])
    tester_seeds = Keyword.get(opts, :tester_seeds, [])
    oracle_seeds = Keyword.get(opts, :oracle_seeds, [])

    solvers = init_population(solver_seeds, config.solver_pop, config.genotype_length)
    testers = init_population(tester_seeds, config.tester_pop, config.tester_genotype_length)
    oracles = init_population(oracle_seeds, config.oracle_pop, config.genotype_length)

    IO.puts("=== Separated Coevolution ===")

    IO.puts(
      "Solvers: #{config.solver_pop}, Testers: #{config.tester_pop}, Oracles: #{config.oracle_pop}"
    )

    IO.puts("Gens: #{config.generations}, Samples: #{config.samples}")

    IO.puts(
      "Genotype length: #{config.genotype_length} (tester: #{config.tester_genotype_length})"
    )

    IO.puts("Contexts: #{length(base_contexts)}")
    IO.puts("")

    {solvers, testers, oracles} =
      evaluate_all(solvers, testers, oracles, base_contexts, config)

    print_generation(0, solvers, testers, oracles)

    # Capture snapshots at gen 0, and at configured intervals
    snapshot_gens =
      MapSet.new(
        [0, config.generations] ++
          Enum.filter([1, 5, 10, 20, 50, 100], &(&1 <= config.generations))
      )

    init_snapshots =
      if MapSet.member?(snapshot_gens, 0) do
        [
          %{
            generation: 0,
            solvers: snapshot_pop(solvers),
            testers: snapshot_pop(testers),
            oracles: snapshot_pop(oracles)
          }
        ]
      else
        []
      end

    {final, history, snapshots} =
      Enum.reduce(
        1..config.generations,
        {{solvers, testers, oracles}, [gen_summary(0, solvers, testers, oracles)],
         init_snapshots},
        fn gen, {{s, t, o}, hist, snaps} ->
          # Produce children for each population independently
          s_children = produce_children(s, config.solver_pop, config.genotype_length, config)

          t_children =
            produce_children(t, config.tester_pop, config.tester_genotype_length, config)

          o_children = produce_children(o, config.oracle_pop, config.genotype_length, config)

          # Merge and evaluate
          all_s = s ++ s_children
          all_t = t ++ t_children
          all_o = o ++ o_children

          {all_s, all_t, all_o} =
            evaluate_all(all_s, all_t, all_o, base_contexts, config)

          # Select survivors independently
          new_s = select(all_s, config.solver_pop, config.elitism)
          new_t = select(all_t, config.tester_pop, config.elitism)
          new_o = select(all_o, config.oracle_pop, config.elitism)

          print_generation(gen, new_s, new_t, new_o)

          new_snaps =
            if MapSet.member?(snapshot_gens, gen) do
              snaps ++
                [
                  %{
                    generation: gen,
                    solvers: snapshot_pop(new_s),
                    testers: snapshot_pop(new_t),
                    oracles: snapshot_pop(new_o)
                  }
                ]
            else
              snaps
            end

          {{new_s, new_t, new_o}, hist ++ [gen_summary(gen, new_s, new_t, new_o)], new_snaps}
        end
      )

    {solvers, testers, oracles} = final

    best_solver = Enum.max_by(solvers, & &1.fitness)
    best_tester = Enum.max_by(testers, & &1.fitness)
    best_oracle = Enum.max_by(oracles, & &1.fitness)

    IO.puts("\n=== Best Solver ===")
    print_best(best_solver)
    IO.puts("\n=== Best Tester ===")
    print_best(best_tester)
    IO.puts("\n=== Best Oracle ===")
    print_best(best_oracle)

    %{
      solvers: solvers,
      testers: testers,
      oracles: oracles,
      best_solver: best_solver,
      best_tester: best_tester,
      best_oracle: best_oracle,
      history: history,
      snapshots: snapshots
    }
  end

  @doc """
  Diagnose the final state: per-tester solver pass rates and per-tester
  modified contexts, so we can tell whether testers are actually discriminating.
  """
  @spec diagnose(map(), [map()], keyword()) :: map()
  def diagnose(result, base_contexts, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))

    valid_testers = Enum.filter(result.testers, &(&1.valid? and &1.fitness > 0.0))
    valid_solvers = Enum.filter(result.solvers, & &1.valid?)
    valid_oracles = Enum.filter(result.oracles, & &1.valid?)

    tester_mods = precompute_tester_contexts(valid_testers, base_contexts, config)

    # For each tester, compute actual solver pass rate across all solvers × all oracles × all contexts
    tester_diagnostics =
      Enum.map(valid_testers, fn tester ->
        my_mods = Map.get(tester_mods, tester.id, %{})

        trials =
          for solver <- valid_solvers,
              oracle <- valid_oracles,
              {base_ctx, ctx_idx} <- Enum.with_index(base_contexts) do
            modified_ctx = get_modified_ctx(tester.id, ctx_idx, base_ctx, tester_mods)
            expected = run_source(oracle.source, modified_ctx, config)
            answer = run_source(solver.source, modified_ctx, config)

            %{valid: expected != nil, passes: expected != nil and answer == expected}
          end

        valid_trials = Enum.filter(trials, & &1.valid)

        pass_rate =
          if valid_trials == [] do
            0.0
          else
            Enum.count(valid_trials, & &1.passes) / length(valid_trials)
          end

        # What contexts does this tester actually produce?
        modifications =
          base_contexts
          |> Enum.with_index()
          |> Enum.map(fn {_base_ctx, idx} ->
            case Map.get(my_mods, idx, :identity) do
              :identity -> {idx, :identity}
              mod_ctx -> {idx, mod_ctx}
            end
          end)

        %{
          source: tester.source,
          fitness: tester.fitness,
          solver_pass_rate: pass_rate,
          modifications: modifications,
          total_trials: length(valid_trials)
        }
      end)

    %{
      tester_diagnostics: tester_diagnostics,
      solver_phenotypes: Enum.map(valid_solvers, & &1.source) |> Enum.frequencies(),
      oracle_phenotypes: Enum.map(valid_oracles, & &1.source) |> Enum.frequencies()
    }
  end

  # === Evaluation ===

  defp evaluate_all(solvers, testers, oracles, base_contexts, config) do
    # Pre-compute tester modifications
    valid_testers = Enum.filter(testers, & &1.valid?)
    tester_mods = precompute_tester_contexts(valid_testers, base_contexts, config)

    # Pre-compute which testers actually modify contexts
    valid_tester_mods =
      Enum.filter(valid_testers, fn t ->
        mods = Map.get(tester_mods, t.id, %{})
        Enum.any?(mods, fn {_k, v} -> v != :identity end)
      end)

    # Pre-compute data-dependence for solvers and oracles.
    # An individual is data-dependent if it produces different outputs on
    # different base contexts. Constants get fitness 0.
    solver_dd = precompute_data_dependence(solvers, base_contexts, config)
    oracle_dd = precompute_data_dependence(oracles, base_contexts, config)

    # Evaluate each population against the others
    scored_solvers =
      evaluate_solvers(
        solvers,
        valid_tester_mods,
        oracles,
        base_contexts,
        tester_mods,
        solver_dd,
        config
      )

    scored_testers =
      evaluate_testers(testers, solvers, oracles, base_contexts, tester_mods, config)

    scored_oracles =
      evaluate_oracles(
        oracles,
        solvers,
        valid_tester_mods,
        base_contexts,
        tester_mods,
        oracle_dd,
        config
      )

    {scored_solvers, scored_testers, scored_oracles}
  end

  defp evaluate_solvers(
         solvers,
         valid_testers,
         oracles,
         base_contexts,
         tester_mods,
         data_dep,
         config
       ) do
    valid_oracles = Enum.filter(oracles, & &1.valid?)

    Enum.map(solvers, fn solver ->
      cond do
        not solver.valid? or valid_testers == [] or valid_oracles == [] ->
          %{solver | fitness: 0.0, metadata: Map.put(solver.metadata, :role_score, 0.0)}

        not Map.get(data_dep, solver.id, false) ->
          # Constant output on all contexts → fitness 0
          %{solver | fitness: 0.0, metadata: Map.put(solver.metadata, :role_score, 0.0)}

        true ->
          trials =
            Enum.map(1..config.samples, fn _ ->
              tester = Enum.random(valid_testers)
              oracle = Enum.random(valid_oracles)
              ctx_idx = :rand.uniform(length(base_contexts)) - 1
              base_ctx = Enum.at(base_contexts, ctx_idx)

              modified_ctx = get_modified_ctx(tester.id, ctx_idx, base_ctx, tester_mods)

              expected = run_source(oracle.source, modified_ctx, config)
              answer = run_source(solver.source, modified_ctx, config)

              %{valid: expected != nil, passes: expected != nil and answer == expected}
            end)

          valid_trials = Enum.filter(trials, & &1.valid)

          score =
            if valid_trials == [] do
              0.0
            else
              Enum.count(valid_trials, & &1.passes) / length(valid_trials)
            end

          %{solver | fitness: score, metadata: Map.put(solver.metadata, :role_score, score)}
      end
    end)
  end

  defp evaluate_testers(testers, solvers, oracles, base_contexts, tester_mods, config) do
    valid_solvers = Enum.filter(solvers, & &1.valid?)
    valid_oracles = Enum.filter(oracles, & &1.valid?)

    Enum.map(testers, fn tester ->
      my_mods = Map.get(tester_mods, tester.id, %{})
      has_modification = tester.valid? and Enum.any?(my_mods, fn {_k, v} -> v != :identity end)

      if not has_modification or valid_solvers == [] or valid_oracles == [] do
        %{tester | fitness: 0.0, metadata: Map.put(tester.metadata, :role_score, 0.0)}
      else
        # Sample (solver, oracle, context) triples using MY modified context
        trials =
          Enum.map(1..config.samples, fn _ ->
            solver = Enum.random(valid_solvers)
            oracle = Enum.random(valid_oracles)
            ctx_idx = :rand.uniform(length(base_contexts)) - 1
            base_ctx = Enum.at(base_contexts, ctx_idx)

            test_ctx = get_modified_ctx(tester.id, ctx_idx, base_ctx, tester_mods)

            expected = run_source(oracle.source, test_ctx, config)
            answer = run_source(solver.source, test_ctx, config)

            %{valid: expected != nil, solver_fails: expected != nil and answer != expected}
          end)

        valid_trials = Enum.filter(trials, & &1.valid)

        score =
          if valid_trials == [] do
            0.0
          else
            fail_rate = Enum.count(valid_trials, & &1.solver_fails) / length(valid_trials)
            frontier_score(fail_rate)
          end

        %{tester | fitness: score, metadata: Map.put(tester.metadata, :role_score, score)}
      end
    end)
  end

  defp evaluate_oracles(
         oracles,
         solvers,
         valid_testers,
         base_contexts,
         tester_mods,
         data_dep,
         config
       ) do
    valid_solvers = Enum.filter(solvers, & &1.valid?)

    Enum.map(oracles, fn oracle ->
      cond do
        not oracle.valid? or valid_solvers == [] or valid_testers == [] ->
          %{oracle | fitness: 0.0, metadata: Map.put(oracle.metadata, :role_score, 0.0)}

        not Map.get(data_dep, oracle.id, false) ->
          # Constant output on all contexts → fitness 0
          %{oracle | fitness: 0.0, metadata: Map.put(oracle.metadata, :role_score, 0.0)}

        true ->
          trials =
            Enum.map(1..config.samples, fn _ ->
              solver = Enum.random(valid_solvers)
              tester = Enum.random(valid_testers)
              ctx_idx = :rand.uniform(length(base_contexts)) - 1
              base_ctx = Enum.at(base_contexts, ctx_idx)

              modified_ctx = get_modified_ctx(tester.id, ctx_idx, base_ctx, tester_mods)

              my_answer = run_source(oracle.source, modified_ctx, config)
              solver_answer = run_source(solver.source, modified_ctx, config)

              %{
                valid: my_answer != nil,
                solver_matches: my_answer != nil and solver_answer == my_answer
              }
            end)

          valid_trials = Enum.filter(trials, & &1.valid)

          score =
            if valid_trials == [] do
              0.0
            else
              pass_rate =
                Enum.count(valid_trials, & &1.solver_matches) / length(valid_trials)

              frontier_score(pass_rate)
            end

          %{oracle | fitness: score, metadata: Map.put(oracle.metadata, :role_score, score)}
      end
    end)
  end

  # === Helpers ===

  defp snapshot_pop(population) do
    Enum.map(population, fn ind ->
      %{source: ind.source, fitness: ind.fitness, valid: ind.valid?}
    end)
  end

  defp get_modified_ctx(tester_id, ctx_idx, base_ctx, tester_mods) do
    mods = Map.get(tester_mods, tester_id, %{})

    case Map.get(mods, ctx_idx, :identity) do
      :identity -> base_ctx
      ctx -> ctx
    end
  end

  # Data-dependence gate: returns %{id => true/false}.
  # An individual is data-dependent if it produces at least 2 distinct
  # non-nil outputs across the base contexts.
  defp precompute_data_dependence(population, base_contexts, config) do
    Map.new(population, fn ind ->
      if ind.valid? do
        outputs =
          Enum.map(base_contexts, fn ctx -> run_source(ind.source, ctx, config) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {ind.id, length(outputs) >= 2}
      else
        {ind.id, false}
      end
    end)
  end

  defp precompute_tester_contexts(valid_testers, base_contexts, config) do
    Map.new(valid_testers, fn tester ->
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

  # === Population Management ===

  defp init_population(seeds, pop_size, genotype_length) do
    seed_individuals =
      Enum.map(seeds, fn g -> Individual.from_genotype(g, generation: 0) end)

    random_count = pop_size - length(seed_individuals)

    random_individuals =
      if random_count > 0 do
        Enum.map(1..random_count, fn _ ->
          Individual.from_genotype(Alphabet.random_genotype(genotype_length))
        end)
      else
        []
      end

    seed_individuals ++ random_individuals
  end

  defp produce_children(population, _pop_size, genotype_length, config) do
    count = length(population)

    Enum.map(1..count, fn _ ->
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

        # If mutation produced a different length, pad or trim to target
        mutated = normalize_length(mutated, genotype_length)

        Individual.from_genotype(mutated,
          parent_ids: [parent.id],
          generation: parent.generation + 1,
          metadata: %{operator: op}
        )
      end
    end)
  end

  defp normalize_length(genotype, target) do
    len = String.length(genotype)

    cond do
      len == target -> genotype
      len < target -> genotype <> Alphabet.random_genotype(target - len)
      len > target -> String.slice(genotype, 0, target)
    end
  end

  defp tournament_select(population, size) do
    population
    |> Enum.take_random(min(size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  defp select(population, pop_size, elitism) do
    sorted = Enum.sort_by(population, & &1.fitness, :desc)
    elites = Enum.take(sorted, elitism)
    rest = Enum.drop(sorted, elitism)
    remaining = pop_size - length(elites)
    elites ++ Enum.take(rest, remaining)
  end

  # === Reporting ===

  defp gen_summary(gen, solvers, testers, oracles) do
    %{
      generation: gen,
      solver_avg: avg_fitness(solvers),
      solver_best: best_fitness(solvers),
      solver_uniq: count_unique(solvers),
      tester_avg: avg_fitness(testers),
      tester_best: best_fitness(testers),
      tester_uniq: count_unique(testers),
      tester_valid: Enum.count(testers, fn t -> (t.fitness || 0.0) > 0.0 end),
      oracle_avg: avg_fitness(oracles),
      oracle_best: best_fitness(oracles),
      oracle_uniq: count_unique(oracles)
    }
  end

  defp avg_fitness(pop) do
    fitnesses = pop |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)
    if fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)
  end

  defp best_fitness(pop) do
    pop |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> 0.0 end)
  end

  defp count_unique(pop), do: pop |> Enum.map(& &1.source) |> Enum.uniq() |> length()

  defp print_generation(gen, solvers, testers, oracles) do
    s = gen_summary(gen, solvers, testers, oracles)

    IO.puts(
      "Gen #{String.pad_leading(to_string(gen), 3)}: " <>
        "S=#{fmt(s.solver_best)}/#{fmt(s.solver_avg)}(#{s.solver_uniq}) " <>
        "T=#{fmt(s.tester_best)}/#{fmt(s.tester_avg)}(#{s.tester_valid}v/#{s.tester_uniq}) " <>
        "O=#{fmt(s.oracle_best)}/#{fmt(s.oracle_avg)}(#{s.oracle_uniq})"
    )
  end

  defp fmt(f), do: Float.round(f, 2)

  defp print_best(ind) do
    IO.puts("Genotype: #{ind.genotype}")
    IO.puts("Phenotype: #{ind.source}")
    IO.puts("Fitness: #{if ind.fitness, do: Float.round(ind.fitness, 4), else: "nil"}")
  end
end
