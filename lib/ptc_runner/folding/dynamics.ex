defmodule PtcRunner.Folding.Dynamics do
  @moduledoc """
  Evolutionary dynamics experiments comparing folding vs direct encoding.

  The central experiment: train both representations on regime A, shift to
  regime B, and measure adaptation speed. Per-generation instrumentation
  tracks fitness, diversity, burstiness, and niche count.

  This answers: does folding's pleiotropy enable qualitatively different
  adaptive dynamics than direct encoding's conservative locality?
  """

  alias PtcRunner.Folding.{Alphabet, DirectIndividual, Individual, Operators}
  alias PtcRunner.Lisp

  @default_config %{
    population_size: 40,
    genotype_length: 30,
    elitism: 3,
    tournament_size: 3,
    crossover_rate: 0.3,
    timeout: 1000,
    max_heap: 1_250_000
  }

  @doc """
  Build a list of problems from PTC-Lisp source strings and a context.

  Each source is run against the context to compute the expected output.

      problems = Dynamics.make_problems(
        ["(count data/products)", "(first data/products)"],
        %{"products" => [%{"price" => 100}, %{"price" => 200}]}
      )
  """
  @spec make_problems([String.t()], map()) :: [map()]
  def make_problems(sources, context) do
    Enum.map(sources, fn source ->
      case Lisp.run(source, context: context) do
        {:ok, step} ->
          %{context: context, expected_output: step.return, source: source}

        {:error, step} ->
          raise "Problem source failed: #{source} — #{inspect(step.fail)}"
      end
    end)
  end

  @doc """
  Run a regime-shift experiment.

  Each regime is a list of `%{context: map, expected_output: term}` problems.
  Use `make_problems/2` to generate these from PTC-Lisp source strings.

  Phase 1: evolve on `regime_a` problems for `regime_a_gens` generations.
  Phase 2: shift to `regime_b` problems for `regime_b_gens` generations.

  Returns per-generation metrics for both phases, for both encodings.

  Options:
  - `:population_size`, `:genotype_length`, etc. — evolution params
  - `:n_runs` — number of independent runs to average (default: 1)
  """
  @spec regime_shift([map()], [map()], pos_integer(), pos_integer(), keyword()) :: map()
  def regime_shift(regime_a, regime_b, regime_a_gens, regime_b_gens, opts \\ []) do
    config = Map.merge(@default_config, Map.new(opts))
    n_runs = Keyword.get(opts, :n_runs, 1)

    IO.puts("=== Regime Shift Experiment ===")
    IO.puts("Regime A: #{regime_a_gens} gens, Regime B: #{regime_b_gens} gens")
    IO.puts("Population: #{config.population_size}, Length: #{config.genotype_length}")
    IO.puts("Runs: #{n_runs}")
    IO.puts("")

    all_runs =
      Enum.map(1..n_runs, fn run ->
        IO.puts("--- Run #{run}/#{n_runs} ---")

        # Same initial genotypes for both encodings (fair comparison)
        genotypes =
          Enum.map(1..config.population_size, fn _ ->
            Alphabet.random_genotype(config.genotype_length)
          end)

        folding_result =
          run_encoding(
            :folding,
            genotypes,
            regime_a,
            regime_b,
            regime_a_gens,
            regime_b_gens,
            config
          )

        direct_result =
          run_encoding(
            :direct,
            genotypes,
            regime_a,
            regime_b,
            regime_a_gens,
            regime_b_gens,
            config
          )

        %{folding: folding_result, direct: direct_result}
      end)

    # Average across runs
    %{
      folding: average_runs(Enum.map(all_runs, & &1.folding)),
      direct: average_runs(Enum.map(all_runs, & &1.direct)),
      n_runs: n_runs,
      regime_a_gens: regime_a_gens,
      regime_b_gens: regime_b_gens
    }
  end

  @doc """
  Print a summary of regime-shift results.
  """
  def print_summary(result) do
    total_gens = result.regime_a_gens + result.regime_b_gens
    shift_gen = result.regime_a_gens

    IO.puts("\n╔══════════════════════════════════════════════════════════════╗")
    IO.puts("║  Regime Shift Results (#{result.n_runs} run(s))                         ║")
    IO.puts("╠══════════════════════════════════════════════════════════════╣")
    IO.puts("")

    IO.puts("  Gen │ Fold fit │ Dir fit  │ Fold uniq│ Dir uniq │ Phase")
    IO.puts("  ────┼──────────┼──────────┼──────────┼──────────┼──────")

    for gen <- 0..total_gens do
      f = Enum.at(result.folding, gen, %{})
      d = Enum.at(result.direct, gen, %{})
      phase = if gen <= shift_gen, do: "A", else: "B"
      marker = if gen == shift_gen, do: " <<<", else: ""

      ff = Map.get(f, :avg_fitness, 0.0) |> Float.round(3)
      df = Map.get(d, :avg_fitness, 0.0) |> Float.round(3)
      fu = Map.get(f, :unique_phenotypes, 0)
      du = Map.get(d, :unique_phenotypes, 0)

      IO.puts(
        "  #{String.pad_leading(to_string(gen), 3)} │ " <>
          "#{String.pad_leading(to_string(ff), 8)} │ " <>
          "#{String.pad_leading(to_string(df), 8)} │ " <>
          "#{String.pad_leading(to_string(fu), 8)} │ " <>
          "#{String.pad_leading(to_string(du), 8)} │ #{phase}#{marker}"
      )
    end

    # Recovery metrics
    pre_shift_f = Enum.at(result.folding, shift_gen, %{}) |> Map.get(:avg_fitness, 0.0)
    pre_shift_d = Enum.at(result.direct, shift_gen, %{}) |> Map.get(:avg_fitness, 0.0)
    post_shift_f = Enum.at(result.folding, shift_gen + 1, %{}) |> Map.get(:avg_fitness, 0.0)
    post_shift_d = Enum.at(result.direct, shift_gen + 1, %{}) |> Map.get(:avg_fitness, 0.0)
    final_f = List.last(result.folding) |> Map.get(:avg_fitness, 0.0)
    final_d = List.last(result.direct) |> Map.get(:avg_fitness, 0.0)

    IO.puts("")
    IO.puts("  Metric                    Folding    Direct")
    IO.puts("  ─────────────────────────────────────────────")

    IO.puts(
      "  Pre-shift fitness         #{Float.round(pre_shift_f, 3)}      #{Float.round(pre_shift_d, 3)}"
    )

    IO.puts(
      "  Post-shift fitness        #{Float.round(post_shift_f, 3)}      #{Float.round(post_shift_d, 3)}"
    )

    IO.puts(
      "  Drop                      #{Float.round(pre_shift_f - post_shift_f, 3)}      #{Float.round(pre_shift_d - post_shift_d, 3)}"
    )

    IO.puts(
      "  Final fitness             #{Float.round(final_f, 3)}      #{Float.round(final_d, 3)}"
    )

    IO.puts(
      "  Recovery                  #{Float.round(final_f - post_shift_f, 3)}      #{Float.round(final_d - post_shift_d, 3)}"
    )

    # Burstiness — count generation-over-generation fitness jumps > 0.05
    fold_jumps = count_jumps(result.folding, 0.05)
    direct_jumps = count_jumps(result.direct, 0.05)
    IO.puts("  Fitness jumps (>0.05)     #{fold_jumps}          #{direct_jumps}")
    IO.puts("")
  end

  # === Internal ===

  defp run_encoding(encoding, genotypes, regime_a, regime_b, regime_a_gens, regime_b_gens, config) do
    ind_mod = if encoding == :folding, do: Individual, else: DirectIndividual
    label = if encoding == :folding, do: "FOLD", else: "DIR "

    # Initialize population
    population = Enum.map(genotypes, fn g -> ind_mod.from_genotype(g) end)

    # Phase A
    {pop_a, history_a} =
      evolve_phase(population, regime_a, regime_a_gens, ind_mod, config, "#{label} A")

    # Phase B (shift!)
    {_pop_b, history_b} =
      evolve_phase(pop_a, regime_b, regime_b_gens, ind_mod, config, "#{label} B")

    history_a ++ history_b
  end

  defp evolve_phase(population, contexts, generations, ind_mod, config, label) do
    # Evaluate initial
    population = evaluate_pop(population, contexts, config)
    gen0 = gen_metrics(population)

    IO.puts(
      "  #{label} gen 0: fit=#{Float.round(gen0.avg_fitness, 3)} uniq=#{gen0.unique_phenotypes}"
    )

    Enum.reduce(1..generations, {population, [gen0]}, fn gen, {pop, hist} ->
      # Produce children
      children =
        Enum.map(1..config.population_size, fn _ ->
          produce_child(pop, ind_mod, config)
        end)

      # Evaluate all
      all = evaluate_pop(pop ++ children, contexts, config)

      # (mu+lambda) selection
      sorted = Enum.sort_by(all, & &1.fitness, :desc)
      new_pop = Enum.take(sorted, config.population_size)

      metrics = gen_metrics(new_pop)

      if rem(gen, 5) == 0 or gen == generations do
        IO.puts(
          "  #{label} gen #{gen}: fit=#{Float.round(metrics.avg_fitness, 3)} uniq=#{metrics.unique_phenotypes}"
        )
      end

      {new_pop, hist ++ [metrics]}
    end)
  end

  # Each regime is a list of %{context: map, expected_output: term} problems.
  # Fitness = average partial score across problems.
  defp evaluate_pop(population, problems, config) do
    Enum.map(population, fn ind ->
      if ind.valid? do
        scores = score_problems(ind, problems, config)
        %{ind | fitness: Enum.sum(scores) / max(length(scores), 1)}
      else
        %{ind | fitness: 0.0}
      end
    end)
  end

  defp score_problems(ind, problems, config) do
    Enum.map(problems, fn problem ->
      case Lisp.run(ind.source,
             context: problem.context,
             timeout: config.timeout,
             max_heap: config.max_heap
           ) do
        {:ok, step} ->
          if step.return == problem.expected_output,
            do: 1.0,
            else: partial(step.return, problem.expected_output)

        {:error, _} ->
          0.0
      end
    end)
  end

  defp produce_child(population, ind_mod, config) do
    if :rand.uniform() < config.crossover_rate do
      a = tournament_select(population, config.tournament_size)
      b = tournament_select(population, config.tournament_size)
      {:ok, offspring} = Operators.crossover(a.genotype, b.genotype)
      ind_mod.from_genotype(offspring)
    else
      parent = tournament_select(population, config.tournament_size)
      {:ok, mutated, _op} = Operators.mutate(parent.genotype)
      ind_mod.from_genotype(mutated)
    end
  end

  defp tournament_select(population, size) do
    population
    |> Enum.take_random(min(size, length(population)))
    |> Enum.max_by(& &1.fitness)
  end

  defp gen_metrics(population) do
    fitnesses = Enum.map(population, & &1.fitness) |> Enum.reject(&is_nil/1)
    sources = Enum.map(population, & &1.source) |> Enum.reject(&is_nil/1)
    valid_count = Enum.count(population, & &1.valid?)

    %{
      avg_fitness: if(fitnesses == [], do: 0.0, else: Enum.sum(fitnesses) / length(fitnesses)),
      best_fitness: Enum.max(fitnesses, fn -> 0.0 end),
      unique_phenotypes: sources |> Enum.uniq() |> length(),
      valid_count: valid_count,
      avg_genotype_length:
        Enum.sum(Enum.map(population, fn i -> byte_size(i.genotype) end)) /
          max(length(population), 1)
    }
  end

  defp count_jumps(history, threshold) do
    history
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [a, b] ->
      abs(Map.get(b, :avg_fitness, 0) - Map.get(a, :avg_fitness, 0)) > threshold
    end)
  end

  defp average_runs([single]), do: single

  defp average_runs(runs) do
    max_len = runs |> Enum.map(&length/1) |> Enum.max()

    Enum.map(0..(max_len - 1), fn i ->
      gen_data = Enum.map(runs, fn run -> Enum.at(run, i, %{}) end)

      %{
        avg_fitness: avg_field(gen_data, :avg_fitness),
        best_fitness: avg_field(gen_data, :best_fitness),
        unique_phenotypes: avg_field(gen_data, :unique_phenotypes) |> round(),
        valid_count: avg_field(gen_data, :valid_count) |> round()
      }
    end)
  end

  defp avg_field(maps, key) do
    values = Enum.map(maps, fn m -> Map.get(m, key, 0.0) end)
    if values == [], do: 0.0, else: Enum.sum(values) / length(values)
  end

  # Partial credit for near-misses
  defp partial(actual, expected) when is_integer(actual) and is_integer(expected) do
    if expected == 0 do
      if actual == 0, do: 1.0, else: 0.1
    else
      ratio = abs(actual - expected) / max(abs(expected), 1)
      max(0.1, 1.0 - ratio) |> min(0.9)
    end
  end

  defp partial(actual, expected) when is_list(actual) and is_list(expected) do
    if expected == [] do
      if actual == [], do: 1.0, else: 0.1
    else
      len_score = 1.0 - min(abs(length(actual) - length(expected)) / length(expected), 1.0)
      0.1 + 0.8 * len_score
    end
  end

  defp partial(actual, expected) when is_map(actual) and is_map(expected) do
    if map_size(expected) == 0, do: if(map_size(actual) == 0, do: 1.0, else: 0.1), else: 0.1
  end

  defp partial(actual, expected) do
    if actual == expected, do: 1.0, else: 0.05
  end
end
