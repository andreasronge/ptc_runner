defmodule PtcRunner.Folding.SeparatedCoevolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.SeparatedCoevolution

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
    test "runs and returns result with three populations" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 3,
          solver_pop: 10,
          tester_pop: 10,
          oracle_pop: 10,
          genotype_length: 15,
          samples: 5
        )

      assert is_map(result)
      assert length(result.solvers) == 10
      assert length(result.testers) == 10
      assert length(result.oracles) == 10
      assert length(result.history) == 4
      assert result.best_solver.valid?
      assert result.best_oracle.valid?
    end

    test "solver fitness is accuracy based" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 2,
          solver_pop: 10,
          tester_pop: 10,
          oracle_pop: 10,
          genotype_length: 15,
          samples: 5
        )

      for solver <- result.solvers do
        assert solver.fitness >= 0.0
        assert solver.fitness <= 1.0
      end
    end

    test "tester fitness is zero without valid data transformation" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 2,
          solver_pop: 10,
          tester_pop: 10,
          oracle_pop: 10,
          genotype_length: 10,
          samples: 5
        )

      # With short genotypes, some testers won't produce list-of-maps
      zero_testers = Enum.count(result.testers, fn t -> t.fitness == 0.0 end)
      assert zero_testers >= 1
    end

    test "accepts seed genotypes" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 2,
          solver_pop: 10,
          tester_pop: 10,
          oracle_pop: 10,
          genotype_length: 15,
          samples: 5,
          solver_seeds: ["BSaaa"],
          tester_seeds: ["CTabc"]
        )

      assert length(result.solvers) == 10
      assert length(result.testers) == 10
    end

    test "supports different tester genotype length" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 2,
          solver_pop: 8,
          tester_pop: 8,
          oracle_pop: 8,
          genotype_length: 15,
          tester_genotype_length: 50,
          samples: 5
        )

      assert length(result.testers) == 8
      # Tester genotypes should be longer
      avg_tester_len =
        result.testers
        |> Enum.map(fn t -> String.length(t.genotype) end)
        |> Enum.sum()
        |> div(length(result.testers))

      assert avg_tester_len >= 30
    end

    test "returns population snapshots" do
      result =
        SeparatedCoevolution.run(@contexts,
          generations: 5,
          solver_pop: 8,
          tester_pop: 8,
          oracle_pop: 8,
          genotype_length: 15,
          samples: 5
        )

      assert length(result.snapshots) >= 2
      first_snap = hd(result.snapshots)
      assert first_snap.generation == 0
      assert length(first_snap.solvers) == 8
    end
  end
end
