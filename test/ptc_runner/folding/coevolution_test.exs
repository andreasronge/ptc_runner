defmodule PtcRunner.Folding.CoevolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Coevolution

  @contexts [
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}],
      "employees" => [%{"name" => "A"}],
      "orders" => [%{"amount" => 50}],
      "expenses" => [%{"amount" => 10}]
    },
    %{
      "products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}],
      "employees" => [%{"name" => "A"}, %{"name" => "B"}, %{"name" => "C"}],
      "orders" => [%{"amount" => 50}, %{"amount" => 75}],
      "expenses" => [%{"amount" => 10}, %{"amount" => 20}]
    }
  ]

  describe "run/2" do
    test "runs coevolution and returns result" do
      result =
        Coevolution.run(@contexts,
          generations: 3,
          population_size: 10,
          genotype_length: 10
        )

      assert is_map(result)
      assert result.best.valid?
      assert length(result.population) == 10
      # history has gen 0 + 3 generations = 4 entries
      assert length(result.history) == 4
    end

    test "individuals have role scores in metadata" do
      result =
        Coevolution.run(@contexts,
          generations: 2,
          population_size: 10,
          genotype_length: 10
        )

      for ind <- result.population do
        assert Map.has_key?(ind.metadata, :solve_score)
        assert Map.has_key?(ind.metadata, :test_score)
        assert Map.has_key?(ind.metadata, :robust_score)
        assert ind.metadata.solve_score >= 0.0
        assert ind.metadata.test_score >= 0.0
      end
    end

    test "tracks unique phenotype count in history" do
      result =
        Coevolution.run(@contexts,
          generations: 3,
          population_size: 15,
          genotype_length: 12
        )

      # Gen 0 should have diversity (random init)
      first_gen = hd(result.history)
      assert first_gen.unique_phenotypes >= 2
    end

    test "works with static problems" do
      static = [
        %{
          name: "count",
          source: "(count data/products)",
          expected_output: 3,
          output_type: :integer,
          context: Enum.at(@contexts, 1)
        }
      ]

      result =
        Coevolution.run(@contexts,
          generations: 3,
          population_size: 10,
          genotype_length: 10,
          static_problems: static
        )

      # At least some individuals should have non-zero robust scores
      robust_scores = Enum.map(result.population, fn i -> i.metadata.robust_score end)
      assert Enum.any?(robust_scores, &(&1 > 0.0))
    end

    test "accepts seed genotypes" do
      result =
        Coevolution.run(@contexts,
          generations: 2,
          population_size: 10,
          genotype_length: 10,
          seeds: ["BSaaa", "BTabc"]
        )

      assert length(result.population) == 10
    end
  end
end
