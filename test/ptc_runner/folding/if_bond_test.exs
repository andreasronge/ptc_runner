defmodule PtcRunner.Folding.IfBondTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.{Chemistry, Phenotype}

  describe "if bond assembly" do
    test "if bonds with comparison predicate and two branches" do
      # X(if) adjacent to comparison (> 300 500) and two data sources
      grid = %{
        {0, 0} => ?K,
        {1, 0} => ?5,
        {-1, 0} => ?3,
        {0, 1} => ?X,
        {1, 1} => ?S,
        {-1, 1} => ?T
      }

      fragments = Chemistry.assemble(grid)

      assembled =
        Enum.find(fragments, fn
          {:assembled, {:list, [{:symbol, :if} | _]}} -> true
          _ -> false
        end)

      assert assembled != nil
    end

    test "if without enough branches doesn't bond" do
      # X(if) with only one neighbor — can't form if
      grid = %{
        {0, 0} => ?X,
        {1, 0} => ?5
      }

      fragments = Chemistry.assemble(grid)

      if_fragments =
        Enum.filter(fragments, fn
          {:assembled, {:list, [{:symbol, :if} | _]}} -> true
          _ -> false
        end)

      assert if_fragments == []
    end

    test "if bonds with predicate and two value branches" do
      # Manually place: comparison + if + two literals
      grid = %{
        {0, 0} => ?K,
        {1, 0} => ?3,
        {-1, 0} => ?5,
        {0, -1} => ?X,
        {1, -1} => ?S,
        {-1, -1} => ?T
      }

      fragments = Chemistry.assemble(grid)

      has_if =
        Enum.any?(fragments, fn
          {:assembled, {:list, [{:symbol, :if} | _]}} -> true
          _ -> false
        end)

      assert has_if
    end
  end

  describe "if through phenotype pipeline" do
    test "some genotypes produce if expressions" do
      # Try several genotypes containing X(if) — at least one should produce if
      candidates = ["XK53ST", "3KX5ST", "XS5T3K", "5XK3ST", "SX3T5K", "XG7MAJ"]

      if_count =
        Enum.count(candidates, fn g ->
          case Phenotype.develop(g) do
            {:ok, source} -> String.contains?(source, "if")
            {:error, _} -> false
          end
        end)

      assert if_count > 0, "None of the candidate genotypes produced an if expression"
    end
  end

  describe "if with match tool integration" do
    test "if branching on match result executes correctly" do
      alias PtcRunner.Folding.MatchTool

      match_fn = fn args ->
        pattern = Map.get(args, "pattern", "")
        {:ok, MatchTool.matches?("(count data/products)", pattern)}
      end

      # Program: if match succeeds, return 42, else 99
      {:ok, step} =
        PtcRunner.Lisp.run(
          "(if (tool/match {:pattern \"(count *)\"}) 42 99)",
          tools: %{"match" => match_fn}
        )

      assert step.return == 42

      # Swap peer source to a filter — match should fail
      match_fn2 = fn args ->
        pattern = Map.get(args, "pattern", "")
        {:ok, MatchTool.matches?("(filter (fn [x] true) data/products)", pattern)}
      end

      {:ok, step2} =
        PtcRunner.Lisp.run(
          "(if (tool/match {:pattern \"(count *)\"}) 42 99)",
          tools: %{"match" => match_fn2}
        )

      assert step2.return == 99
    end

    test "nested if with multiple match patterns" do
      alias PtcRunner.Folding.MatchTool

      match_fn = fn args ->
        pattern = Map.get(args, "pattern", "")
        {:ok, MatchTool.matches?("(filter (fn [x] true) data/products)", pattern)}
      end

      program = """
      (if (tool/match {:pattern "(count *)"})
        100
        (if (tool/match {:pattern "(filter * *)"})
          200
          300))
      """

      {:ok, step} = PtcRunner.Lisp.run(program, tools: %{"match" => match_fn})
      # Source is a filter, not count → first if fails, second matches filter
      assert step.return == 200
    end
  end
end
