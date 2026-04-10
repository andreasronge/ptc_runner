defmodule PtcRunner.Folding.LoopTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Loop

  @ctx %{"products" => [%{"price" => 100}, %{"price" => 200}, %{"price" => 300}]}

  describe "make_problem/4" do
    test "creates a problem with expected output" do
      problem = Loop.make_problem("test", "(count data/products)", :integer, @ctx)
      assert problem.expected_output == 3
      assert problem.output_type == :integer
      assert problem.name == "test"
    end
  end

  describe "run/2" do
    test "evolves population and returns result" do
      problem = Loop.make_problem("count", "(count data/products)", :integer, @ctx)

      result =
        Loop.run([problem],
          generations: 5,
          population_size: 10,
          genotype_length: 10
        )

      assert is_map(result)
      assert result.best.valid?
      assert length(result.population) == 10
      assert length(result.history) == 6
    end

    test "accepts seed genotypes" do
      problem = Loop.make_problem("count", "(count data/products)", :integer, @ctx)

      result =
        Loop.run([problem],
          generations: 3,
          population_size: 10,
          genotype_length: 10,
          seeds: ["BSaaa", "ABCDe"]
        )

      assert length(result.population) == 10
    end
  end
end
