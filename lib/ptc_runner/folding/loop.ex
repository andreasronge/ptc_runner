defmodule PtcRunner.Folding.Loop do
  @moduledoc """
  Evolution loop for folded genotypes.

  Single population with (mu+lambda) selection. Each individual is a genotype
  string that folds into a PTC-Lisp phenotype. Genetic operators work on the
  string; the folding creates non-linear phenotypic effects.

  ## Usage

      problems = [PtcRunner.Folding.Loop.make_problem("P1", source, :integer, ctx)]
      result = PtcRunner.Folding.Loop.run(problems, generations: 20, population_size: 30)
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
          mutation_rate: float(),
          eval_config: Evaluator.config()
        }

  @default_config %{
    generations: 20,
    population_size: 30,
    genotype_length: 20,
    elitism: 3,
    tournament_size: 3,
    crossover_rate: 0.3,
    mutation_rate: 0.7,
    eval_config: %{
      lambda_llm: 0.0,
      lambda_size: 0.001,
      timeout: 1000,
      max_heap: 1_250_000
    }
  }

  @doc """
  Build a problem from PTC-Lisp source and context.
  """
  @spec make_problem(String.t(), String.t(), atom(), map()) :: map()
  def make_problem(name, source, output_type, context) do
    case Lisp.run(source, context: context) do
      {:ok, step} ->
        %{
          name: name,
          source: source,
          expected_output: step.return,
          output_type: output_type,
          context: context
        }

      {:error, step} ->
        raise "Problem source failed: #{inspect(step.fail)}"
    end
  end

  @doc """
  Run evolution on folded genotypes against a list of problems.

  Seeds an initial population of random genotype strings, evaluates them
  against all problems, and evolves using tournament selection, crossover,
  and mutation.

  Options:
  - `:generations` — number of generations (default 20)
  - `:population_size` — population size (default 30)
  - `:genotype_length` — initial genotype length (default 20)
  - `:seeds` — list of seed genotype strings (optional)
  - `:elitism` — number of elite individuals preserved (default 3)
  - `:tournament_size` — tournament selection size (default 3)
  - `:crossover_rate` — probability of crossover vs mutation (default 0.3)
  """
  @spec run([Evaluator.problem()], keyword()) :: map()
  def run(problems, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    seed_genotypes = Keyword.get(opts, :seeds, [])

    # Build initial population
    population = init_population(seed_genotypes, config)

    IO.puts("=== Folding Evolution ===")
    IO.puts("Population: #{length(population)}, Generations: #{config.generations}")
    IO.puts("Problems: #{length(problems)}")
    IO.puts("")

    # Evaluate initial population
    population = evaluate_population(population, problems, config)
    print_generation(0, population)

    # Evolution loop
    {final_pop, history} =
      Enum.reduce(1..config.generations, {population, [gen_summary(0, population)]}, fn gen,
                                                                                        {pop,
                                                                                         hist} ->
        children =
          1..config.population_size
          |> Enum.map(fn _ -> produce_child(pop, config) end)

        children = evaluate_population(children, problems, config)

        # (mu+lambda) with elitism
        all = pop ++ children
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
    IO.puts("Valid: #{best.valid?}")

    %{
      population: final_pop,
      best: best,
      history: history,
      problems: Enum.map(problems, & &1.name)
    }
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

  defp evaluate_population(population, problems, config) do
    Enum.map(population, fn ind ->
      fitness = evaluate_individual(ind, problems, config.eval_config)
      %{ind | fitness: fitness}
    end)
  end

  defp evaluate_individual(%Individual{valid?: false}, _problems, _eval_config), do: 0.0

  defp evaluate_individual(%Individual{source: source, program_size: size}, problems, eval_config) do
    # Evaluate against all problems, average the scores
    scores =
      Enum.map(problems, fn problem ->
        # Build a minimal Individual struct for the existing Evaluator
        case EvolveIndividual.from_source(source) do
          {:ok, eval_ind} ->
            result = Evaluator.evaluate(eval_ind, problem, eval_config)
            Evaluator.partial_score(result, problem)

          {:error, _} ->
            0.0
        end
      end)

    avg_score = if scores == [], do: 0.0, else: Enum.sum(scores) / length(scores)
    # Apply size penalty
    avg_score - eval_config.lambda_size * size / 100
  end

  # === Reproduction ===

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

    %{
      generation: gen,
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      valid_count: valid_count,
      population_size: length(population),
      avg_genotype_length:
        Enum.sum(Enum.map(population, fn i -> byte_size(i.genotype) end)) /
          max(length(population), 1)
    }
  end

  defp print_generation(gen, population) do
    s = gen_summary(gen, population)

    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(gen), 3)}: " <>
        "best=#{Float.round(s.best_fitness, 4)} " <>
        "avg=#{Float.round(s.avg_fitness, 4)} " <>
        "valid=#{s.valid_count}/#{s.population_size} " <>
        "avg_len=#{Float.round(s.avg_genotype_length, 1)}"
    )
  end
end
