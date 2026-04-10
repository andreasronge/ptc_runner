defmodule PtcRunner.Folding.OperatorsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Folding.Operators

  describe "mutate/2" do
    test "point mutation changes one character" do
      {:ok, mutated, :point} = Operators.mutate("ABCDE", operator: :point)
      assert byte_size(mutated) == 5
      # At most one character changed
      diffs = Enum.zip(String.to_charlist("ABCDE"), String.to_charlist(mutated))
      assert Enum.count(diffs, fn {a, b} -> a != b end) <= 1
    end

    test "insertion adds one character" do
      {:ok, mutated, :insert} = Operators.mutate("ABCDE", operator: :insert)
      assert byte_size(mutated) == 6
    end

    test "deletion removes one character" do
      {:ok, mutated, :delete} = Operators.mutate("ABCDE", operator: :delete)
      assert byte_size(mutated) == 4
    end

    test "deletion on single char falls back to point mutation" do
      {:ok, mutated, :point} = Operators.mutate("A", operator: :delete)
      assert byte_size(mutated) == 1
    end

    test "random operator always succeeds on non-empty genotype" do
      for _ <- 1..20 do
        {:ok, _mutated, _op} = Operators.mutate("ABCDE")
      end
    end
  end

  describe "crossover/2" do
    test "produces offspring from two parents" do
      {:ok, offspring} = Operators.crossover("AAAAA", "BBBBB")
      assert is_binary(offspring)
      assert byte_size(offspring) > 0
    end

    test "offspring contains characters from both parents" do
      # With enough trials, crossover should mix characters
      results =
        for _ <- 1..50 do
          {:ok, offspring} = Operators.crossover("AAAAA", "BBBBB")
          offspring
        end

      all_chars = results |> Enum.join() |> String.to_charlist() |> MapSet.new()
      assert MapSet.member?(all_chars, ?A)
      assert MapSet.member?(all_chars, ?B)
    end
  end
end
