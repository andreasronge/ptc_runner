defmodule PtcRunner.Meta.MetaLoop do
  @moduledoc """
  Outer evolution loop for MetaLearner M variants.

  Evolves a population of M variants using (mu+lambda) selection.
  Each M variant is evaluated by running an inner evolution loop
  where M controls GP operator selection for solvers.

  Logs generation summaries and distillation metrics to disk.
  """

  alias PtcRunner.Evolve.{Individual, Operators}
  alias PtcRunner.Meta.{MetaEvaluator, MetaLearner, Seeds}

  @type config :: %{
          outer_generations: pos_integer(),
          mu: pos_integer(),
          lambda: pos_integer(),
          tournament_size: pos_integer(),
          elitism: pos_integer(),
          log_dir: String.t() | nil,
          eval_config: keyword()
        }

  @default_config %{
    outer_generations: 8,
    mu: 4,
    lambda: 4,
    tournament_size: 2,
    elitism: 2,
    log_dir: nil,
    eval_config: []
  }

  @doc """
  Run the outer meta-evolution loop.

  Evolves M variants over `outer_generations`, evaluating each by running
  the inner evolution loop with M controlling operator selection.

  Returns the best M variant and generation history.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    log_dir = config.log_dir

    if log_dir, do: File.mkdir_p!(log_dir)

    # Initialize population with seeds
    population = Seeds.seeds()

    IO.puts("=== Meta-Evolution: #{config.outer_generations} outer generations ===")
    IO.puts("Population: mu=#{config.mu}, lambda=#{config.lambda}")
    IO.puts("")

    # Evaluate initial population
    population = evaluate_m_population(population, config)
    initial_summary = gen_summary(0, population)
    log_generation(0, population, log_dir)
    print_summary(initial_summary)

    # Outer evolution loop
    {final_pop, history} =
      Enum.reduce(1..config.outer_generations, {population, [initial_summary]}, fn gen,
                                                                                   {pop, hist} ->
        # Select parents via tournament
        parents =
          Enum.map(1..config.lambda, fn _ ->
            tournament_select(pop, config.tournament_size)
          end)

        # Produce children by GP-mutating M's own AST
        children =
          parents
          |> Enum.map(&mutate_m/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn m -> %{m | generation: gen} end)

        # Evaluate children
        children = evaluate_m_population(children, config)

        # (mu+lambda) selection with elitism
        all = pop ++ children
        sorted = Enum.sort_by(all, fn m -> m.fitness || -999.0 end, :desc)

        elite = Enum.take(sorted, config.elitism)
        rest = Enum.drop(sorted, config.elitism)
        remaining = Enum.take(rest, config.mu - config.elitism)
        new_pop = elite ++ remaining

        summary = gen_summary(gen, new_pop)
        log_generation(gen, new_pop, log_dir)
        print_summary(summary)

        {new_pop, hist ++ [summary]}
      end)

    best = Enum.max_by(final_pop, fn m -> m.fitness || -999.0 end)

    IO.puts("\n=== Best MetaLearner ===")
    IO.puts("ID: #{best.id}")
    IO.puts("Fitness: #{inspect(best.fitness)}")
    IO.puts("Source: #{best.source}")

    # Log final summary
    if log_dir do
      summary = %{
        best_id: best.id,
        best_fitness: best.fitness,
        best_source: best.source,
        history: history
      }

      File.write!(Path.join(log_dir, "summary.json"), Jason.encode!(summary, pretty: true))
    end

    %{
      best: best,
      population: final_pop,
      history: history
    }
  end

  @doc """
  Run baselines through the same evaluation pipeline.

  Returns baseline results for comparison with evolved M variants.
  """
  @spec run_baselines(keyword()) :: [map()]
  def run_baselines(opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    baselines = Seeds.baselines()

    IO.puts("=== Baselines ===")

    Enum.map(baselines, fn m ->
      IO.puts("Evaluating baseline: #{m.id}")
      result = MetaEvaluator.evaluate(m, config.eval_config)

      IO.puts(
        "  solve_rate=#{Float.round(result.solve_rate, 3)} " <>
          "tokens=#{result.total_llm_tokens} " <>
          "fitness=#{Float.round(result.fitness, 4)}"
      )

      %{
        id: m.id,
        source: m.source,
        fitness: result.fitness,
        solve_rate: result.solve_rate,
        total_llm_tokens: result.total_llm_tokens,
        operator_counts: result.operator_counts,
        entropy: MetaEvaluator.operator_entropy(result.operator_counts)
      }
    end)
  end

  # Evaluate all M variants in the population
  defp evaluate_m_population(population, config) do
    Enum.map(population, fn m ->
      result = MetaEvaluator.evaluate(m, config.eval_config)
      %{m | fitness: result.fitness, metadata: Map.put(m.metadata, :eval_result, result)}
    end)
  end

  # Mutate M's AST using GP operators (self-referential!)
  defp mutate_m(%MetaLearner{source: source, id: parent_id}) do
    # Wrap M in an Individual so we can use existing GP operators
    case Individual.from_source(source, parent_ids: [parent_id]) do
      {:ok, ind} ->
        case Operators.mutate(ind) do
          {:ok, mutated_ind} ->
            case MetaLearner.from_source(mutated_ind.source,
                   parent_id: parent_id,
                   metadata: mutated_ind.metadata
                 ) do
              {:ok, new_m} -> new_m
              {:error, _} -> nil
            end

          {:error, _} ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp tournament_select(population, tournament_size) do
    population
    |> Enum.take_random(min(tournament_size, length(population)))
    |> Enum.max_by(fn m -> m.fitness || -999.0 end)
  end

  defp gen_summary(gen, population) do
    fitnesses =
      population
      |> Enum.map(fn m -> m.fitness end)
      |> Enum.reject(&is_nil/1)

    entropies =
      population
      |> Enum.map(fn m ->
        case get_in(m.metadata, [:eval_result, :operator_counts]) do
          nil -> 0.0
          counts -> MetaEvaluator.operator_entropy(counts)
        end
      end)

    %{
      generation: gen,
      best_fitness: if(fitnesses == [], do: 0.0, else: Enum.max(fitnesses)),
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      population_size: length(population),
      avg_entropy: if(entropies == [], do: 0.0, else: Enum.sum(entropies) / length(entropies))
    }
  end

  defp print_summary(summary) do
    IO.puts(
      "Meta Gen #{String.pad_leading(Integer.to_string(summary.generation), 3)}: " <>
        "best=#{Float.round(summary.best_fitness, 4)} " <>
        "avg=#{Float.round(summary.avg_fitness, 4)} " <>
        "entropy=#{Float.round(summary.avg_entropy, 2)}"
    )
  end

  defp log_generation(_gen, _population, nil), do: :ok

  defp log_generation(gen, population, log_dir) do
    gen_dir =
      Path.join(log_dir, "outer-gen-#{String.pad_leading(Integer.to_string(gen), 3, "0")}")

    File.mkdir_p!(gen_dir)

    Enum.each(population, fn m ->
      data = %{
        id: m.id,
        source: m.source,
        generation: m.generation,
        parent_id: m.parent_id,
        fitness: m.fitness,
        eval_result: Map.get(m.metadata, :eval_result)
      }

      file = Path.join(gen_dir, "#{m.id}.json")
      File.write!(file, Jason.encode!(data, pretty: true))
    end)
  end
end
