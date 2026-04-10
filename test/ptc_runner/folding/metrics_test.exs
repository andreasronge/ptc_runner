defmodule PtcRunner.Folding.MetricsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{Alphabet, Individual, Metrics}

  @contexts [
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}],
      "employees" => [%{"name" => "A"}]
    },
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}],
      "employees" => [%{"name" => "A"}, %{"name" => "B"}]
    }
  ]

  defp random_population(size, genotype_length) do
    Enum.map(1..size, fn _ ->
      Individual.from_genotype(Alphabet.random_genotype(genotype_length))
    end)
  end

  describe "neutral_mutation_rate/3" do
    test "returns rates between 0 and 1" do
      pop = random_population(5, 15)
      result = Metrics.neutral_mutation_rate(pop, @contexts, n_mutations: 10)

      assert result.phenotype >= 0.0 and result.phenotype <= 1.0
      assert result.behavioral >= 0.0 and result.behavioral <= 1.0
      assert result.sample_size > 0
    end

    test "behavioral neutrality >= phenotype neutrality" do
      # Same phenotype string implies same behavior, but not vice versa.
      # So behavioral neutral rate should be >= phenotype neutral rate.
      pop = random_population(10, 15)
      result = Metrics.neutral_mutation_rate(pop, @contexts, n_mutations: 30)

      assert result.behavioral >= result.phenotype - 0.05
    end

    test "handles empty population" do
      result = Metrics.neutral_mutation_rate([], @contexts)
      assert result.sample_size == 0
    end
  end

  describe "crossover_preservation/3" do
    test "returns valid rates" do
      pop = random_population(10, 15)
      result = Metrics.crossover_preservation(pop, @contexts, n_crossovers: 20)

      assert result.valid_rate >= 0.0 and result.valid_rate <= 1.0
      assert result.behavior_preserved >= 0.0 and result.behavior_preserved <= 1.0
      assert is_float(result.complexity_change)
      assert result.sample_size == 20
    end

    test "validity rate is high" do
      pop = random_population(10, 15)
      result = Metrics.crossover_preservation(pop, @contexts, n_crossovers: 50)

      # Folding crossover should produce valid PTC-Lisp most of the time
      assert result.valid_rate > 0.8
    end

    test "handles small population" do
      pop = random_population(1, 10)
      result = Metrics.crossover_preservation(pop, @contexts)
      assert result.sample_size == 0
    end
  end

  describe "complexity_distribution/1" do
    test "returns bond count statistics" do
      pop = random_population(20, 15)
      result = Metrics.complexity_distribution(pop)

      assert result.population_size == 20
      assert result.valid_count > 0
      assert result.bond_counts.min >= 0
      assert result.bond_counts.max >= result.bond_counts.min
      assert is_float(result.bond_counts.avg)
      assert result.unique_phenotypes > 0
    end
  end

  describe "bond_count/1" do
    test "bare literal has 0 bonds" do
      # A single digit character produces a literal — no bonds
      assert Metrics.bond_count("5") == 0
    end

    test "get+key has 1 bond" do
      # D(get) adjacent to a(:price) should bond
      # Need to find a genotype where D and a are adjacent
      # "Da" — D at (0,0) heading left (uppercase turns left), a at (0,-1) straight
      # Actually D turns left from right → up, so a goes at (0,-1)
      # They ARE adjacent (vertically) — but fold direction matters for placement
      count = Metrics.bond_count("Da")
      assert count >= 1
    end

    test "data source alone has 0 bonds" do
      assert Metrics.bond_count("S") == 0
    end
  end

  describe "full_report/3" do
    test "combines all measurements" do
      pop = random_population(10, 15)
      report = Metrics.full_report(pop, @contexts, n_mutations: 10, n_crossovers: 20)

      assert Map.has_key?(report, :neutral_mutation)
      assert Map.has_key?(report, :crossover)
      assert Map.has_key?(report, :complexity)
      assert report.neutral_mutation.sample_size > 0
      assert report.crossover.sample_size == 20
    end
  end
end
