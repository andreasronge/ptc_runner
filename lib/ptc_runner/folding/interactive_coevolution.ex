defmodule PtcRunner.Folding.InteractiveCoevolution do
  @moduledoc """
  Interactive coevolution for folded genotypes.

  Unlike the static coevolution in `Coevolution`, this module implements an
  interactive protocol where testers generate targeted challenges for solvers:

  1. Tester phenotype runs → raw output
  2. `ChallengeDecoder` maps output to a `ChallengeSpec`
  3. `ChallengeTransform` applies the spec to the base context
  4. Solver phenotype runs against the modified context
  5. External `Oracle` computes the correct answer
  6. Solver scored on correctness; tester scored on inducing failures

  The oracle stays OUTSIDE both evolving populations. The challenge language
  is constrained to prevent degenerate tests.

  ## Staged Information Exposure

  Controlled by `:info_phase`:
  - Phase 1: Tester sees solver output profile + past failures
  - Phase 2: Also sees solver phenotype source
  - Phase 3: Also sees solver genotype string

  ## Archives

  A hall-of-fame archive of strong solvers and testers provides stable
  selection pressure and prevents coevolution cycling.

  See `docs/plans/folding-evolution.md` for full design.
  """

  alias PtcRunner.Folding.{
    Alphabet,
    Archive,
    ChallengeDecoder,
    ChallengeTransform,
    Individual,
    MatchTool,
    Operators,
    Oracle
  }

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
          max_heap: pos_integer(),
          archive_size: pos_integer(),
          info_phase: 1 | 2 | 3,
          sample_size: pos_integer()
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
    max_heap: 1_250_000,
    archive_size: 10,
    info_phase: 1,
    sample_size: 10
  }

  @doc """
  Run interactive coevolution.

  Takes a list of base contexts (multiple data environments) and a list of
  task definitions (oracle expressions). Returns population, best individual,
  archive, and generation history.

  ## Options

  - `:generations` — number of generations (default 20)
  - `:population_size` — population size (default 30)
  - `:genotype_length` — initial genotype length (default 20)
  - `:seeds` — seed genotype strings (optional)
  - `:info_phase` — staged info exposure: 1, 2, or 3 (default 1)
  - `:archive_size` — max archive size per role (default 10)
  - `:sample_size` — solvers sampled per tester evaluation (default 10)
  - `:w_solve`, `:w_test`, `:w_robust` — fitness weights
  """
  @spec run([map()], [Oracle.task_def()], keyword()) :: map()
  def run(base_contexts, task_defs, opts \\ []) when is_list(base_contexts) do
    config = Map.merge(@default_config, Map.new(opts))
    seeds = Keyword.get(opts, :seeds, [])

    population = init_population(seeds, config)
    archive = Archive.new(max_size: config.archive_size)

    IO.puts("=== Interactive Coevolution ===")
    IO.puts("Population: #{config.population_size}, Generations: #{config.generations}")
    IO.puts("Contexts: #{length(base_contexts)}, Tasks: #{length(task_defs)}")
    IO.puts("Info phase: #{config.info_phase}, Archive size: #{config.archive_size}")
    IO.puts("Weights: solve=#{config.w_solve} test=#{config.w_test} robust=#{config.w_robust}")
    IO.puts("")

    # Evaluate initial population
    population = evaluate_population(population, archive, base_contexts, task_defs, config)
    archive = Archive.update(archive, population)
    print_generation(0, population, archive)

    # Evolution loop
    {final_pop, final_archive, history} =
      Enum.reduce(
        1..config.generations,
        {population, archive, [gen_summary(0, population, archive)]},
        fn gen, {pop, arch, hist} ->
          children =
            1..config.population_size
            |> Enum.map(fn _ -> produce_child(pop, config) end)

          all = pop ++ children
          all = evaluate_population(all, arch, base_contexts, task_defs, config)

          # (mu+lambda) with elitism
          sorted = Enum.sort_by(all, & &1.fitness, :desc)
          elite = Enum.take(sorted, config.elitism)
          rest = Enum.drop(sorted, config.elitism)
          new_pop = elite ++ Enum.take(rest, config.population_size - config.elitism)

          new_arch = Archive.update(arch, new_pop)
          print_generation(gen, new_pop, new_arch)

          {new_pop, new_arch, hist ++ [gen_summary(gen, new_pop, new_arch)]}
        end
      )

    best = Enum.max_by(final_pop, & &1.fitness)

    IO.puts("\n=== Best Individual ===")
    IO.puts("Genotype: #{best.genotype}")
    IO.puts("Phenotype: #{best.source}")
    IO.puts("Fitness: #{if best.fitness, do: Float.round(best.fitness, 4), else: "nil"}")
    print_role_scores(best)

    %{
      population: final_pop,
      best: best,
      archive: final_archive,
      history: history
    }
  end

  # === Interactive Evaluation ===

  defp evaluate_population(population, archive, base_contexts, task_defs, config) do
    # Get solver pool: sample from population + archive solvers
    all_solvers = population ++ Archive.solver_archive(archive)

    solver_sample =
      if length(all_solvers) > config.sample_size do
        Enum.take_random(all_solvers, config.sample_size)
      else
        all_solvers
      end

    # Get tester pool: population + archive testers
    all_testers = population ++ Archive.tester_archive(archive)

    # For each tester, generate challenges and evaluate solvers
    # Returns %{tester_id => %{challenge_specs: [...], solver_results: %{solver_id => score}}}
    tester_results =
      Map.new(all_testers, fn tester ->
        {tester.id, evaluate_tester(tester, solver_sample, base_contexts, task_defs, config)}
      end)

    # Compute scores for population individuals
    Enum.map(population, fn ind ->
      solve = compute_solve_score(ind, tester_results, all_testers)
      test = compute_test_score(ind, tester_results, solver_sample)
      robust = compute_robust_score(ind, base_contexts, task_defs, config)

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

  defp evaluate_tester(%{valid?: false} = tester, _solvers, _contexts, _task_defs, _config) do
    %{tester_id: tester.id, challenges: [], solver_scores: %{}}
  end

  defp evaluate_tester(tester, solvers, base_contexts, task_defs, config) do
    # For each context, generate a challenge and evaluate solvers
    # Pick a representative solver source for the tester's match tool
    representative_solver = Enum.find(solvers, & &1.valid?)

    challenges =
      Enum.map(base_contexts, fn base_ctx ->
        # Build tester context with solver info + peer_source for match tool
        tester_ctx = build_tester_context(base_ctx, solvers, config)

        # Run tester with match tool targeting representative solver
        peer_source = if representative_solver, do: representative_solver.source
        match_tools = build_match_tools(peer_source)

        raw_output =
          case Lisp.run(tester.source,
                 context: tester_ctx,
                 tools: match_tools,
                 timeout: config.timeout,
                 max_heap: config.max_heap,
                 filter_context: false
               ) do
            {:ok, step} -> step.return
            {:error, _} -> nil
          end

        # Decode to challenge spec
        challenge = ChallengeDecoder.decode(raw_output)

        # Apply transformation
        modified_ctx = ChallengeTransform.apply_challenge(challenge, base_ctx)

        # Evaluate each solver against the modified context
        # Each solver gets match tool targeting the tester's source
        solver_scores =
          Map.new(solvers, fn solver ->
            score =
              evaluate_solver_on_challenge(solver, modified_ctx, tester.source, task_defs, config)

            {solver.id, score}
          end)

        %{challenge: challenge, solver_scores: solver_scores}
      end)

    # Aggregate across contexts
    all_solver_scores =
      Enum.reduce(challenges, %{}, fn %{solver_scores: scores}, acc ->
        Map.merge(acc, scores, fn _k, v1, v2 -> v1 + v2 end)
      end)

    # Average across contexts
    num_contexts = max(length(base_contexts), 1)

    avg_solver_scores =
      Map.new(all_solver_scores, fn {id, total} -> {id, total / num_contexts} end)

    %{
      tester_id: tester.id,
      challenges: Enum.map(challenges, & &1.challenge),
      solver_scores: avg_solver_scores
    }
  end

  defp evaluate_solver_on_challenge(%{valid?: false}, _ctx, _peer_source, _task_defs, _config),
    do: 0.0

  defp evaluate_solver_on_challenge(solver, modified_ctx, peer_source, task_defs, config) do
    # Run solver against modified context with match tool targeting tester
    match_tools = build_match_tools(peer_source)

    solver_output =
      case Lisp.run(solver.source,
             context: modified_ctx,
             tools: match_tools,
             timeout: config.timeout,
             max_heap: config.max_heap,
             filter_context: false
           ) do
        {:ok, step} -> step.return
        {:error, _} -> nil
      end

    # Score against each task's oracle answer
    task_scores =
      Enum.map(task_defs, fn task_def ->
        case Oracle.evaluate(task_def, modified_ctx, timeout: config.timeout) do
          {:ok, expected} -> Oracle.score(solver_output, expected, task_def.output_type)
          {:error, _} -> 0.0
        end
      end)

    Enum.sum(task_scores) / max(length(task_scores), 1)
  end

  # Build tester context based on info phase
  defp build_tester_context(base_ctx, solvers, config) do
    valid_solvers = Enum.filter(solvers, & &1.valid?)

    solver_info =
      case config.info_phase do
        1 ->
          # Profile only: aggregate stats
          avg_fitness =
            if valid_solvers == [] do
              0.0
            else
              Enum.sum(Enum.map(valid_solvers, fn s -> s.fitness || 0.0 end)) /
                length(valid_solvers)
            end

          %{
            "solver_count" => length(valid_solvers),
            "solver_avg_fitness" => avg_fitness
          }

        2 ->
          # Add phenotype sources
          sources = Enum.map(valid_solvers, & &1.source) |> Enum.take(5)

          %{
            "solver_count" => length(valid_solvers),
            "solver_sources" => sources
          }

        3 ->
          # Add genotypes
          genotypes = Enum.map(valid_solvers, & &1.genotype) |> Enum.take(5)
          sources = Enum.map(valid_solvers, & &1.source) |> Enum.take(5)

          %{
            "solver_count" => length(valid_solvers),
            "solver_sources" => sources,
            "solver_genotypes" => genotypes
          }
      end

    Map.merge(base_ctx, solver_info)
  end

  # Solve score: how well does this individual do as a solver across all testers' challenges?
  defp compute_solve_score(%{valid?: false}, _tester_results, _all_testers), do: 0.0

  defp compute_solve_score(ind, tester_results, all_testers) do
    scores =
      all_testers
      |> Enum.map(fn tester ->
        result = Map.get(tester_results, tester.id, %{solver_scores: %{}})
        Map.get(result.solver_scores, ind.id, 0.0)
      end)
      |> Enum.reject(&is_nil/1)

    if scores == [], do: 0.0, else: Enum.sum(scores) / length(scores)
  end

  # Test score: how effective is this individual as a tester?
  # Peaks at ~50% solver failure rate (difficulty frontier)
  defp compute_test_score(%{valid?: false}, _tester_results, _solver_sample), do: 0.0

  defp compute_test_score(ind, tester_results, _solver_sample) do
    result = Map.get(tester_results, ind.id, %{solver_scores: %{}})
    scores = Map.values(result.solver_scores)

    if scores == [] do
      0.0
    else
      pass_count = Enum.count(scores, &(&1 > 0.5))
      pass_rate = pass_count / max(length(scores), 1)

      cond do
        pass_rate == 0.0 -> 0.1
        pass_rate == 1.0 -> 0.1
        true -> 1.0 - abs(pass_rate - 0.5) * 2.0
      end
    end
  end

  # Robust score: how well does this individual solve tasks on unmodified contexts?
  defp compute_robust_score(%{valid?: false}, _contexts, _task_defs, _config), do: 0.0

  defp compute_robust_score(ind, base_contexts, task_defs, config) do
    match_tools = build_match_tools(nil)

    scores =
      Enum.flat_map(base_contexts, fn ctx ->
        solver_output =
          case Lisp.run(ind.source,
                 context: ctx,
                 tools: match_tools,
                 timeout: config.timeout,
                 max_heap: config.max_heap,
                 filter_context: false
               ) do
            {:ok, step} -> step.return
            {:error, _} -> nil
          end

        Enum.map(task_defs, fn task_def ->
          case Oracle.evaluate(task_def, ctx, timeout: config.timeout) do
            {:ok, expected} -> Oracle.score(solver_output, expected, task_def.output_type)
            {:error, _} -> 0.0
          end
        end)
      end)

    if scores == [], do: 0.0, else: Enum.sum(scores) / length(scores)
  end

  # === Match Tool Integration ===

  # Build a tools map with the match tool configured for a specific peer source.
  # The match tool reads the peer source from the closure, not from the context.
  defp build_match_tools(peer_source) do
    match_fn = fn args ->
      pattern = Map.get(args, "pattern", "")
      source = peer_source || ""
      {:ok, MatchTool.matches?(source, pattern)}
    end

    %{"match" => match_fn}
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
    if :rand.uniform() < config.crossover_rate do
      parent_a = tournament_select(population, config.tournament_size)
      parent_b = tournament_select(population, config.tournament_size)
      {:ok, offspring} = Operators.crossover(parent_a.genotype, parent_b.genotype)

      Individual.from_genotype(offspring,
        parent_ids: [parent_a.id, parent_b.id],
        generation: parent_a.generation + 1,
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

  defp tournament_select(population, tournament_size) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  # === Reporting ===

  defp gen_summary(gen, population, archive) do
    fitnesses = population |> Enum.map(& &1.fitness) |> Enum.reject(&is_nil/1)
    valid_count = Enum.count(population, & &1.valid?)

    %{
      generation: gen,
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      valid_count: valid_count,
      population_size: length(population),
      avg_solve: avg_meta(population, :solve_score),
      avg_test: avg_meta(population, :test_score),
      avg_robust: avg_meta(population, :robust_score),
      unique_phenotypes: population |> Enum.map(& &1.source) |> Enum.uniq() |> length(),
      archive_solvers: length(Archive.solver_archive(archive)),
      archive_testers: length(Archive.tester_archive(archive))
    }
  end

  defp avg_meta(population, key) do
    values = Enum.map(population, fn i -> Map.get(i.metadata, key, 0.0) end)
    Enum.sum(values) / max(length(values), 1)
  end

  defp print_generation(gen, population, archive) do
    s = gen_summary(gen, population, archive)

    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(gen), 3)}: " <>
        "fit=#{Float.round(s.best_fitness, 3)} " <>
        "avg=#{Float.round(s.avg_fitness, 3)} " <>
        "solve=#{Float.round(s.avg_solve, 2)} " <>
        "test=#{Float.round(s.avg_test, 2)} " <>
        "robust=#{Float.round(s.avg_robust, 2)} " <>
        "uniq=#{s.unique_phenotypes} " <>
        "arch=#{s.archive_solvers}s/#{s.archive_testers}t"
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
