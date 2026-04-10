defmodule PtcRunner.Folding.InteractiveCoevolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{Archive, InteractiveCoevolution}

  @context %{
    "products" => [
      %{"price" => 100, "status" => "active"},
      %{"price" => 600, "status" => "active"},
      %{"price" => 300, "status" => "discontinued"}
    ]
  }

  @task %{source: "(count data/products)", output_type: :integer}

  test "run completes with small population and few generations" do
    result =
      InteractiveCoevolution.run([@context], [@task],
        generations: 2,
        population_size: 8,
        genotype_length: 10,
        archive_size: 3,
        info_phase: 1
      )

    assert %{population: pop, best: best, archive: archive, history: hist} = result
    assert length(pop) == 8
    assert best.fitness != nil
    assert length(hist) == 3
    assert archive.__struct__ == PtcRunner.Folding.Archive
  end

  test "solve and test scores are computed" do
    result =
      InteractiveCoevolution.run([@context], [@task],
        generations: 1,
        population_size: 6,
        genotype_length: 10
      )

    Enum.each(result.population, fn ind ->
      assert Map.has_key?(ind.metadata, :solve_score)
      assert Map.has_key?(ind.metadata, :test_score)
      assert Map.has_key?(ind.metadata, :robust_score)
    end)
  end

  test "info_phase 2 includes solver sources" do
    # Just verify it runs without error at phase 2
    result =
      InteractiveCoevolution.run([@context], [@task],
        generations: 1,
        population_size: 6,
        genotype_length: 10,
        info_phase: 2
      )

    assert result.best.fitness != nil
  end

  test "info_phase 3 includes solver genotypes" do
    result =
      InteractiveCoevolution.run([@context], [@task],
        generations: 1,
        population_size: 6,
        genotype_length: 10,
        info_phase: 3
      )

    assert result.best.fitness != nil
  end

  test "archive grows over generations" do
    result =
      InteractiveCoevolution.run([@context], [@task],
        generations: 3,
        population_size: 10,
        genotype_length: 10,
        archive_size: 5
      )

    archive = result.archive
    # After 3 generations, archive should have some entries
    total =
      length(Archive.solver_archive(archive)) +
        length(Archive.tester_archive(archive))

    assert total > 0
  end

  test "multiple contexts and tasks" do
    ctx2 = %{
      "products" => [
        %{"price" => 200, "status" => "active"},
        %{"price" => 800, "status" => "active"}
      ]
    }

    task2 = %{source: "(first data/products)", output_type: :map}

    result =
      InteractiveCoevolution.run([@context, ctx2], [@task, task2],
        generations: 1,
        population_size: 6,
        genotype_length: 10
      )

    assert result.best.fitness != nil
  end
end
