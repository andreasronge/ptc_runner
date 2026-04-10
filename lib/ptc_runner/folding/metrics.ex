defmodule PtcRunner.Folding.Metrics do
  @moduledoc """
  Measurement tools for characterizing the folding representation.

  Three categories of measurement:

  1. **Neutral mutation rate** — at three levels:
     - Phenotype: does the PTC-Lisp source string change?
     - Behavioral: does the output profile across contexts change?
     - Ecological: does the individual remain competitive in the population?

  2. **Crossover preservation** — how much does crossover preserve:
     - Behavior (same output profile)
     - Complexity (bond count change)
     - Validity (produces valid PTC-Lisp)

  3. **Complexity distribution** — bond counts, AST depth, phenotype diversity.

  See `docs/plans/folding-evolution.md` for context.
  """

  alias PtcRunner.Folding.{Individual, Operators, Phenotype}
  alias PtcRunner.Lisp

  @doc """
  Measure neutral mutation rate at three levels for a population.

  For each individual, applies `n_mutations` point mutations and measures
  what fraction are neutral at each level:

  - `:phenotype` — same PTC-Lisp source string
  - `:behavioral` — same output profile across all contexts

  Options:
  - `:individual_module` — module with `from_genotype/1` (default: `Individual`)
  - `:n_mutations` — mutations per individual (default: 50)

  Returns a map with per-level rates (averaged across the population).
  """
  @spec neutral_mutation_rate([map()], [map()], keyword()) :: map()
  def neutral_mutation_rate(population, contexts, opts \\ []) do
    n_mutations = Keyword.get(opts, :n_mutations, 50)
    timeout = Keyword.get(opts, :timeout, 1000)
    ind_mod = Keyword.get(opts, :individual_module, Individual)

    valid_pop = Enum.filter(population, & &1.valid?)

    if valid_pop == [] do
      %{phenotype: 0.0, behavioral: 0.0, sample_size: 0}
    else
      results =
        Enum.map(valid_pop, fn ind ->
          original_profile = output_profile(ind.source, contexts, timeout)

          mutation_results =
            1..n_mutations
            |> Enum.map(fn _ ->
              measure_single_mutation(ind, ind_mod, original_profile, contexts, timeout)
            end)

          %{
            phenotype: Enum.count(mutation_results, & &1.phenotype) / n_mutations,
            behavioral: Enum.count(mutation_results, & &1.behavioral) / n_mutations
          }
        end)

      %{
        phenotype: avg(Enum.map(results, & &1.phenotype)),
        behavioral: avg(Enum.map(results, & &1.behavioral)),
        sample_size: length(valid_pop)
      }
    end
  end

  @doc """
  Measure crossover preservation rates for a population.

  Options:
  - `:individual_module` — module with `from_genotype/1` (default: `Individual`)
  - `:n_crossovers` — number of crossover trials (default: 100)
  """
  @spec crossover_preservation([map()], [map()], keyword()) :: map()
  def crossover_preservation(population, contexts, opts \\ []) do
    n_crossovers = Keyword.get(opts, :n_crossovers, 100)
    timeout = Keyword.get(opts, :timeout, 1000)
    ind_mod = Keyword.get(opts, :individual_module, Individual)

    valid_pop = Enum.filter(population, & &1.valid?)

    if length(valid_pop) < 2 do
      %{
        valid_rate: 0.0,
        behavior_preserved: 0.0,
        complexity_change: 0.0,
        complexity_increased: 0.0,
        complexity_decreased: 0.0,
        sample_size: 0
      }
    else
      results =
        1..n_crossovers
        |> Enum.map(fn _ ->
          [parent_a, parent_b] = Enum.take_random(valid_pop, 2)
          {:ok, offspring_genotype} = Operators.crossover(parent_a.genotype, parent_b.genotype)
          offspring = ind_mod.from_genotype(offspring_genotype)

          parent_a_size = parent_a.program_size
          parent_b_size = parent_b.program_size
          offspring_size = offspring.program_size
          max_parent_size = max(parent_a_size, parent_b_size)
          min_parent_size = min(parent_a_size, parent_b_size)

          behavior_preserved =
            if offspring.valid? do
              offspring_profile = output_profile(offspring.source, contexts, timeout)
              parent_a_profile = output_profile(parent_a.source, contexts, timeout)
              parent_b_profile = output_profile(parent_b.source, contexts, timeout)

              offspring_profile == parent_a_profile or offspring_profile == parent_b_profile
            else
              false
            end

          %{
            valid: offspring.valid?,
            behavior_preserved: behavior_preserved,
            complexity_change: offspring_size - (parent_a_size + parent_b_size) / 2,
            complexity_increased: offspring_size > max_parent_size,
            complexity_decreased: offspring_size < min_parent_size
          }
        end)

      %{
        valid_rate: Enum.count(results, & &1.valid) / n_crossovers,
        behavior_preserved: Enum.count(results, & &1.behavior_preserved) / n_crossovers,
        complexity_change: avg(Enum.map(results, & &1.complexity_change)),
        complexity_increased: Enum.count(results, & &1.complexity_increased) / n_crossovers,
        complexity_decreased: Enum.count(results, & &1.complexity_decreased) / n_crossovers,
        sample_size: n_crossovers
      }
    end
  end

  @doc """
  Measure complexity distribution for a population.

  Returns bond count statistics, phenotype diversity, and AST depth distribution.
  """
  @spec complexity_distribution([Individual.t()]) :: map()
  def complexity_distribution(population) do
    valid_pop = Enum.filter(population, & &1.valid?)
    bond_counts = Enum.map(valid_pop, fn ind -> bond_count(ind.genotype) end)
    unique_phenotypes = valid_pop |> Enum.map(& &1.source) |> Enum.uniq()

    %{
      population_size: length(population),
      valid_count: length(valid_pop),
      bond_counts: %{
        min: Enum.min(bond_counts, fn -> 0 end),
        max: Enum.max(bond_counts, fn -> 0 end),
        avg: avg(bond_counts),
        distribution: Enum.frequencies(bond_counts)
      },
      unique_phenotypes: length(unique_phenotypes),
      avg_genotype_length: avg(Enum.map(population, fn i -> byte_size(i.genotype) end)),
      avg_program_size: avg(Enum.map(valid_pop, & &1.program_size))
    }
  end

  @doc """
  Run all measurements on a population.

  Returns a combined report with neutral mutation, crossover preservation,
  and complexity distribution.
  """
  @spec full_report([map()], [map()], keyword()) :: map()
  def full_report(population, contexts, opts \\ []) do
    %{
      neutral_mutation: neutral_mutation_rate(population, contexts, opts),
      crossover: crossover_preservation(population, contexts, opts),
      complexity: complexity_distribution(population)
    }
  end

  @doc """
  Count the number of bonds in a genotype's folded form.

  A bond is a connection between two fragments that forms during chemistry assembly.
  More bonds = more complex phenotype. A bare literal or data source has 0 bonds.
  An `(get x :price)` has 1 bond. `(> (get x :price) 500)` has 2 bonds (get+key, comp+values).
  """
  @spec bond_count(String.t()) :: non_neg_integer()
  def bond_count(genotype) do
    debug = Phenotype.develop_debug(genotype)

    debug.fragments
    |> Enum.map(fn
      {:assembled, ast} -> count_bonds_in_ast(ast)
      _ -> 0
    end)
    |> Enum.sum()
  end

  # Count bonds by counting internal list nodes (each represents a bond/assembly step)
  defp count_bonds_in_ast({:list, items}) do
    1 + Enum.sum(Enum.map(items, &count_bonds_in_ast/1))
  end

  defp count_bonds_in_ast({:vector, items}) do
    Enum.sum(Enum.map(items, &count_bonds_in_ast/1))
  end

  defp count_bonds_in_ast(_), do: 0

  @doc """
  Measure the mutation effect spectrum for a population.

  Categorizes each point mutation into five categories:

  - `:neutral` — same output profile across all contexts
  - `:beneficial` — different output AND matches more static problem outputs than parent
  - `:harmful` — different output on some contexts, errors on none
  - `:catastrophic` — produces errors on one or more contexts
  - `:lethal` — mutant is invalid (no phenotype produced)

  The key question this answers: among non-neutral mutations, what fraction are
  beneficial? If folding's 24% break rate contains 4% beneficial vs direct's 2%
  containing 0.5% beneficial, folding produces 8x more innovations per generation.

  Options:
  - `:individual_module` — module with `from_genotype/1` (default: `Individual`)
  - `:n_mutations` — mutations per individual (default: 50)
  - `:static_problems` — list of `%{context, expected_output}` for beneficial detection
  """
  @spec mutation_spectrum([map()], [map()], keyword()) :: map()
  def mutation_spectrum(population, contexts, opts \\ []) do
    n_mutations = Keyword.get(opts, :n_mutations, 50)
    timeout = Keyword.get(opts, :timeout, 1000)
    ind_mod = Keyword.get(opts, :individual_module, Individual)
    static_problems = Keyword.get(opts, :static_problems, [])

    valid_pop = Enum.filter(population, & &1.valid?)

    if valid_pop == [] do
      %{
        neutral: 0.0,
        beneficial: 0.0,
        harmful: 0.0,
        catastrophic: 0.0,
        lethal: 0.0,
        sample_size: 0
      }
    else
      all_categories =
        Enum.flat_map(valid_pop, fn ind ->
          original_profile = output_profile(ind.source, contexts, timeout)
          original_score = static_score(ind.source, static_problems, timeout)

          Enum.map(1..n_mutations, fn _ ->
            classify_mutation(
              ind,
              ind_mod,
              original_profile,
              original_score,
              contexts,
              static_problems,
              timeout
            )
          end)
        end)

      total = length(all_categories)
      freqs = Enum.frequencies(all_categories)

      %{
        neutral: Map.get(freqs, :neutral, 0) / total,
        beneficial: Map.get(freqs, :beneficial, 0) / total,
        harmful: Map.get(freqs, :harmful, 0) / total,
        catastrophic: Map.get(freqs, :catastrophic, 0) / total,
        lethal: Map.get(freqs, :lethal, 0) / total,
        sample_size: total
      }
    end
  end

  # Score a source against static problems (fraction of correct outputs)
  defp static_score(_source, [], _timeout), do: 0.0

  defp static_score(source, problems, timeout) do
    correct =
      Enum.count(problems, fn problem ->
        case Lisp.run(source,
               context: problem.context,
               timeout: timeout
             ) do
          {:ok, step} -> step.return == problem.expected_output
          _ -> false
        end
      end)

    correct / length(problems)
  end

  defp measure_single_mutation(ind, ind_mod, original_profile, contexts, timeout) do
    {:ok, mutated_genotype, _op} = Operators.mutate(ind.genotype, operator: :point)
    mutant = ind_mod.from_genotype(mutated_genotype)

    phenotype_neutral = mutant.source == ind.source

    behavioral_neutral =
      if mutant.valid? and original_profile != :error do
        mutant_profile = output_profile(mutant.source, contexts, timeout)
        mutant_profile == original_profile
      else
        false
      end

    %{phenotype: phenotype_neutral, behavioral: behavioral_neutral}
  end

  defp classify_mutation(
         ind,
         ind_mod,
         original_profile,
         original_score,
         contexts,
         static_problems,
         timeout
       ) do
    {:ok, mutated_genotype, _op} = Operators.mutate(ind.genotype, operator: :point)
    mutant = ind_mod.from_genotype(mutated_genotype)

    if mutant.valid? do
      mutant_profile = output_profile(mutant.source, contexts, timeout)

      classify_mutant_profile(
        mutant_profile,
        original_profile,
        original_score,
        mutant.source,
        static_problems,
        timeout
      )
    else
      :lethal
    end
  end

  defp classify_mutant_profile(
         mutant_profile,
         original_profile,
         original_score,
         mutant_source,
         static_problems,
         timeout
       ) do
    cond do
      mutant_profile == original_profile ->
        :neutral

      Enum.any?(mutant_profile, &(&1 == :error)) ->
        :catastrophic

      true ->
        mutant_score = static_score(mutant_source, static_problems, timeout)
        if mutant_score > original_score, do: :beneficial, else: :harmful
    end
  end

  # === Helpers ===

  defp output_profile(source, contexts, timeout) do
    Enum.map(contexts, fn ctx ->
      case Lisp.run(source, context: ctx, timeout: timeout) do
        {:ok, step} -> step.return
        {:error, _} -> :error
      end
    end)
  end

  defp avg([]), do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)
end
