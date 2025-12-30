defmodule PtcRunner.Lisp.EvalSetsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Step

  describe "set predicates" do
    test "set? returns true for sets" do
      {:ok, result, _} = run(~S"(set? #{1 2})")
      assert result == true
    end

    test "set? returns false for vectors" do
      {:ok, result, _} = run("(set? [1 2])")
      assert result == false
    end

    test "map? returns false for sets" do
      {:ok, result, _} = run(~S"(map? #{1 2})")
      assert result == false
    end
  end

  describe "set constructor" do
    test "set from vector deduplicates" do
      {:ok, result, _} = run("(set [1 1 2])")
      assert MapSet.equal?(result, MapSet.new([1, 2]))
    end
  end

  describe "collection operations on sets" do
    test "map on set returns vector" do
      {:ok, result, _} = run(~S"(map inc #{1 2 3})")
      assert is_list(result)
      assert Enum.sort(result) == [2, 3, 4]
    end

    test "filter on set returns vector" do
      {:ok, result, _} = run(~S"(filter odd? #{1 2 3 4})")
      assert is_list(result)
      assert Enum.sort(result) == [1, 3]
    end

    test "contains? on set checks membership" do
      {:ok, result, _} = run(~S"(contains? #{1 2 3} 2)")
      assert result == true
    end

    test "remove on set filters elements" do
      {:ok, result, _} = run(~S"(remove odd? #{1 2 3 4})")
      assert is_list(result)
      assert Enum.sort(result) == [2, 4]
    end

    test "mapv on set returns vector" do
      {:ok, result, _} = run(~S"(mapv inc #{1 2 3})")
      assert is_list(result)
      assert Enum.sort(result) == [2, 3, 4]
    end

    test "empty? on set returns true or false" do
      {:ok, result_true, _} = run(~S"(empty? #{})")
      assert result_true == true

      {:ok, result_false, _} = run(~S"(empty? #{1 2 3})")
      assert result_false == false
    end

    test "count on set returns size" do
      {:ok, result_zero, _} = run(~S"(count #{})")
      assert result_zero == 0

      {:ok, result_three, _} = run(~S"(count #{1 2 3})")
      assert result_three == 3
    end
  end

  defp run(source) do
    case PtcRunner.Lisp.run(source) do
      {:ok, %Step{return: result}} -> {:ok, result, %{}}
      {:error, %Step{}} = err -> err
    end
  end
end
