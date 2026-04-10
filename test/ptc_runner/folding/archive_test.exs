defmodule PtcRunner.Folding.ArchiveTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{Archive, Individual}

  defp make_individual(source, solve_score, test_score) do
    ind = Individual.from_genotype("BSaaa", generation: 0)

    %{
      ind
      | source: source,
        valid?: true,
        metadata: %{solve_score: solve_score, test_score: test_score}
    }
  end

  test "new archive is empty" do
    archive = Archive.new()
    assert Archive.solver_archive(archive) == []
    assert Archive.tester_archive(archive) == []
  end

  test "update adds best solver and tester" do
    pop = [
      make_individual("(count data/products)", 0.8, 0.3),
      make_individual("(count data/employees)", 0.3, 0.9)
    ]

    archive = Archive.new() |> Archive.update(pop)
    assert length(Archive.solver_archive(archive)) == 1
    assert length(Archive.tester_archive(archive)) == 1
    assert hd(Archive.solver_archive(archive)).source == "(count data/products)"
    assert hd(Archive.tester_archive(archive)).source == "(count data/employees)"
  end

  test "dedup by phenotype" do
    ind = make_individual("(count data/products)", 0.8, 0.5)
    pop = [ind]

    archive =
      Archive.new()
      |> Archive.update(pop)
      |> Archive.update(pop)

    assert length(Archive.solver_archive(archive)) == 1
  end

  test "respects max_size" do
    individuals =
      for i <- 1..15 do
        make_individual("prog-#{i}", i * 0.05, i * 0.03)
      end

    archive =
      Enum.reduce(individuals, Archive.new(max_size: 3), fn ind, acc ->
        Archive.update(acc, [ind])
      end)

    assert length(Archive.solver_archive(archive)) <= 3
    assert length(Archive.tester_archive(archive)) <= 3
  end

  test "replaces lowest scorer when full" do
    pop1 = [make_individual("prog-1", 0.3, 0.3)]
    pop2 = [make_individual("prog-2", 0.5, 0.5)]
    pop3 = [make_individual("prog-3", 0.9, 0.9)]

    archive =
      Archive.new(max_size: 2)
      |> Archive.update(pop1)
      |> Archive.update(pop2)
      |> Archive.update(pop3)

    solver_sources = Enum.map(Archive.solver_archive(archive), & &1.source)
    # prog-1 (0.3) should have been replaced by prog-3 (0.9)
    refute "prog-1" in solver_sources
    assert "prog-3" in solver_sources
  end
end
