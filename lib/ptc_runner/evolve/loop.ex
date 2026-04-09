defmodule PtcRunner.Evolve.Loop do
  @moduledoc """
  Main evolution loop for GP on PTC-Lisp programs.

  Phase 1: per-problem Solver populations with fixed Author problems.
  Uses (mu+lambda) selection with elitism.

  ## Usage

      # Define problems (Author programs with ground truth)
      problems = PtcRunner.Evolve.Loop.default_problems()

      # Seed initial population for problem 1
      seeds = ["(count data/products)", "(count (filter (fn [p] true) data/products))"]

      # Run evolution
      result = PtcRunner.Evolve.Loop.run(seeds, Enum.at(problems, 0),
        generations: 10, population_size: 10)
  """

  alias PtcRunner.Evolve.{Evaluator, Individual, LLMOperators, Operators}

  @type operator_selector :: (Individual.t() -> atom()) | nil

  @type config :: %{
          generations: pos_integer(),
          population_size: pos_integer(),
          elitism: pos_integer(),
          tournament_size: pos_integer(),
          max_ast_nodes: pos_integer(),
          llm_mutation_rate: float(),
          llm_model: String.t() | nil,
          eval_config: Evaluator.config(),
          operator_selector: operator_selector()
        }

  @default_config %{
    generations: 10,
    population_size: 10,
    elitism: 2,
    tournament_size: 3,
    max_ast_nodes: 80,
    llm_mutation_rate: 0.0,
    llm_model: nil,
    operator_selector: nil,
    eval_config: %{
      lambda_llm: 0.01,
      lambda_size: 0.005,
      timeout: 1000,
      max_heap: 1_250_000
    }
  }

  @doc """
  Build a problem from an Author program source and context.

  Runs the source to compute ground truth. Seeds RNG for deterministic data.

      ctx = %{"products" => my_products, ...}
      problem = PtcRunner.Evolve.Loop.make_problem("P1", source, :integer, ctx)
  """
  @spec make_problem(String.t(), String.t(), atom(), map(), keyword()) :: map()
  def make_problem(name, source, output_type, context, opts \\ []) do
    case PtcRunner.Lisp.run(source, context: context) do
      {:ok, step} ->
        %{
          name: name,
          source: source,
          expected_output: step.return,
          output_type: output_type,
          context: context,
          description: Keyword.get(opts, :description, "")
        }

      {:error, step} ->
        raise "Author program failed: #{inspect(step.fail)}"
    end
  end

  @doc """
  Run the evolution loop for a single problem.

  Takes a list of seed program sources, a problem, and config options.
  Returns a map with the final population, best individual, and generation history.
  """
  @spec run([String.t()], Evaluator.problem(), keyword()) :: map()
  def run(seed_sources, problem, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))

    # Build initial population from seeds
    population =
      seed_sources
      |> Enum.map(fn src ->
        case Individual.from_source(src, generation: 0) do
          {:ok, ind} -> ind
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Pad population if seeds are fewer than population_size
    population = pad_population(population, config.population_size)

    IO.puts("=== Evolution: #{problem.name} ===")
    IO.puts("Population: #{length(population)}, Generations: #{config.generations}")
    IO.puts("Expected output: #{inspect(problem.expected_output)}")
    IO.puts("")

    # Evaluate initial population
    population = evaluate_population(population, problem, config.eval_config)
    print_generation_summary(0, population)

    # Evolution loop
    {final_pop, history, total_llm_tokens} =
      Enum.reduce(
        1..config.generations,
        {population, [gen_summary(0, population)], 0},
        fn gen, {pop, hist, tokens_acc} ->
          # Select parents via tournament
          parents =
            Enum.map(1..config.population_size, fn _ ->
              tournament_select(pop, config.tournament_size)
            end)

          # Produce children via mutation, crossover, or LLM mutation
          children =
            parents
            |> Enum.map(fn parent ->
              produce_child(parent, pop, problem, config)
            end)
            |> Enum.filter(fn child -> child.program_size <= config.max_ast_nodes end)

          # Track LLM tokens from mutation (before evaluate_population resets them)
          gen_llm_tokens = Enum.sum(Enum.map(children, & &1.llm_tokens_used))

          # Evaluate children
          children = evaluate_population(children, problem, config.eval_config)

          # (mu+lambda) selection with elitism
          all = pop ++ children
          sorted = Enum.sort_by(all, & &1.fitness, :desc)

          # Elitism: top N pass through unchanged
          elite = Enum.take(sorted, config.elitism)
          rest = Enum.drop(sorted, config.elitism)
          remaining = Enum.take(rest, config.population_size - config.elitism)
          new_pop = elite ++ remaining

          print_generation_summary(gen, new_pop)
          {new_pop, hist ++ [gen_summary(gen, new_pop)], tokens_acc + gen_llm_tokens}
        end
      )

    best = Enum.max_by(final_pop, & &1.fitness)

    IO.puts("\n=== Best Individual ===")
    IO.puts("Fitness: #{Float.round(best.fitness, 4)}")
    IO.puts("Size: #{best.program_size} nodes")
    IO.puts("Source: #{best.source}")
    IO.puts("LLM tokens used (total run): #{total_llm_tokens}")
    IO.puts("")

    # Verify best against problem
    result = Evaluator.evaluate(best, problem, config.eval_config)
    IO.puts("Correct: #{result.correct}")
    IO.puts("Output: #{inspect(result.output)}")

    %{
      population: final_pop,
      best: best,
      history: history,
      problem: problem.name,
      total_llm_tokens: total_llm_tokens
    }
  end

  defp evaluate_population(population, problem, eval_config) do
    Enum.map(population, fn ind ->
      result = Evaluator.evaluate(ind, problem, eval_config)
      fitness = Evaluator.fitness(ind, result, problem, eval_config)
      # Preserve LLM mutation tokens (set by produce_child), add any runtime tokens
      total_tokens = ind.llm_tokens_used + result.llm_tokens
      %{ind | fitness: fitness, llm_tokens_used: total_tokens}
    end)
  end

  defp produce_child(parent, pop, problem, config) do
    # If operator_selector is set, let M control the mutation strategy entirely
    case config.operator_selector do
      selector when is_function(selector) ->
        selected_op = selector.(parent)
        produce_child_with_op(selected_op, parent, pop, problem, config)

      nil ->
        produce_child_default(parent, pop, problem, config)
    end
  end

  # M selected :llm_mutation — force LLM path
  defp produce_child_with_op(:llm_mutation, parent, pop, problem, config) do
    if config.llm_model != nil do
      llm_mutate(parent, pop, problem, config)
    else
      # LLM not configured, fall back to random GP
      gp_mutate(parent, pop, config)
    end
  end

  # M selected a GP operator — use it directly
  defp produce_child_with_op(op, parent, pop, _problem, config) do
    case Operators.mutate(parent, operator: op) do
      {:ok, child} -> child
      {:error, _} -> gp_mutate(parent, pop, config)
    end
  end

  # Default path when no operator_selector (backward compat)
  defp produce_child_default(parent, pop, problem, config) do
    roll = :rand.uniform()

    cond do
      config.llm_model != nil and roll < config.llm_mutation_rate ->
        llm_mutate(parent, pop, problem, config)

      roll < config.llm_mutation_rate + 0.2 ->
        other = Enum.random(pop)

        case Operators.crossover(parent, other) do
          {:ok, child} -> child
          {:error, _} -> gp_mutate(parent, pop, config)
        end

      true ->
        gp_mutate(parent, pop, config)
    end
  end

  defp llm_mutate(parent, pop, problem, config) do
    result = Evaluator.evaluate(parent, problem, config.eval_config)

    case LLMOperators.improve(
           parent,
           result.output,
           problem.expected_output,
           problem.output_type,
           config.llm_model,
           Map.get(problem, :description, "")
         ) do
      {:ok, child, _tokens} ->
        IO.write("*")
        child

      {:error, _reason} ->
        IO.write("x")
        gp_mutate(parent, pop, config)
    end
  end

  defp gp_mutate(parent, _pop, _config) do
    case Operators.mutate(parent) do
      {:ok, child} -> child
      {:error, _} -> parent
    end
  end

  defp tournament_select(population, tournament_size) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  defp pad_population(pop, target_size) when length(pop) >= target_size,
    do: Enum.take(pop, target_size)

  defp pad_population(pop, target_size) do
    # Duplicate and mutate existing individuals to fill the population
    extras =
      Stream.cycle(pop)
      |> Enum.take(target_size - length(pop))
      |> Enum.map(fn ind ->
        case Operators.mutate(ind) do
          {:ok, mutant} -> mutant
          {:error, _} -> ind
        end
      end)

    pop ++ extras
  end

  defp gen_summary(gen, population) do
    fitnesses = Enum.map(population, & &1.fitness) |> Enum.reject(&is_nil/1)

    %{
      generation: gen,
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      correct_count: Enum.count(fitnesses, &(&1 > 0)),
      avg_size: Enum.sum(Enum.map(population, & &1.program_size)) / max(length(population), 1),
      population_size: length(population)
    }
  end

  defp print_generation_summary(gen, population) do
    summary = gen_summary(gen, population)

    IO.puts(
      "Gen #{String.pad_leading(Integer.to_string(gen), 3)}: " <>
        "best=#{Float.round(summary.best_fitness, 4)} " <>
        "avg=#{Float.round(summary.avg_fitness, 4)} " <>
        "correct=#{summary.correct_count}/#{summary.population_size} " <>
        "avg_size=#{Float.round(summary.avg_size, 1)}"
    )
  end
end
