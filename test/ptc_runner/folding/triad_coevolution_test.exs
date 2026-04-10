defmodule PtcRunner.Folding.TriadCoevolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.TriadCoevolution

  @contexts [
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}],
      "employees" => [%{"name" => "A"}],
      "orders" => [%{"amount" => 50}],
      "expenses" => [%{"amount" => 10}]
    },
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}],
      "employees" => [%{"name" => "A"}, %{"name" => "B"}],
      "orders" => [%{"amount" => 50}, %{"amount" => 75}],
      "expenses" => [%{"amount" => 10}, %{"amount" => 20}]
    }
  ]

  describe "run/2" do
    test "runs and returns result" do
      result =
        TriadCoevolution.run(@contexts,
          generations: 3,
          population_size: 10,
          genotype_length: 15,
          triples_per_individual: 5
        )

      assert is_map(result)
      assert result.best.valid?
      assert length(result.population) == 10
      assert length(result.history) == 4
    end

    test "individuals have all three role scores" do
      result =
        TriadCoevolution.run(@contexts,
          generations: 2,
          population_size: 10,
          genotype_length: 15,
          triples_per_individual: 5
        )

      for ind <- result.population do
        assert Map.has_key?(ind.metadata, :solve_score)
        assert Map.has_key?(ind.metadata, :test_score)
        assert Map.has_key?(ind.metadata, :oracle_score)
        assert ind.metadata.solve_score >= 0.0
        assert ind.metadata.test_score >= 0.0
        assert ind.metadata.oracle_score >= 0.0
      end
    end

    test "accepts seed genotypes" do
      result =
        TriadCoevolution.run(@contexts,
          generations: 2,
          population_size: 10,
          genotype_length: 15,
          triples_per_individual: 5,
          seeds: ["BSaaa", "CTabc"]
        )

      assert length(result.population) == 10
    end

    test "maintains some phenotype diversity" do
      result =
        TriadCoevolution.run(@contexts,
          generations: 3,
          population_size: 15,
          genotype_length: 15,
          triples_per_individual: 5
        )

      # Gen 0 should have diversity
      first_gen = hd(result.history)
      assert first_gen.unique_phenotypes >= 2
    end
  end
end
