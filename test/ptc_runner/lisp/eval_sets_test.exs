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

  describe "vec constructor" do
    test "vec from set converts to vector" do
      {:ok, result, _} = run(~S"(vec #{1 2 3})")
      assert is_list(result)
      assert Enum.sort(result) == [1, 2, 3]
    end

    test "vec from vector is identity" do
      {:ok, result, _} = run("(vec [1 2 3])")
      assert result == [1, 2, 3]
    end

    test "vec from string returns graphemes" do
      {:ok, result, _} = run(~S|(vec "abc")|)
      assert result == ["a", "b", "c"]
    end

    test "vec from map returns key-value pairs" do
      {:ok, result, _} = run("(vec {:a 1 :b 2})")
      assert Enum.sort(result) == [[:a, 1], [:b, 2]]
    end

    test "vec from nil returns nil" do
      {:ok, result, _} = run("(vec nil)")
      assert result == nil
    end

    test "vec from empty set returns empty vector" do
      {:ok, result, _} = run(~S"(vec #{})")
      assert result == []
    end

    test "vec from empty string returns empty vector" do
      {:ok, result, _} = run(~S|(vec "")|)
      assert result == []
    end

    test "vec from empty map returns empty vector" do
      {:ok, result, _} = run("(vec {})")
      assert result == []
    end
  end

  describe "vector constructor" do
    test "vector creates vector from args" do
      {:ok, result, _} = run("(vector 1 2 3)")
      assert result == [1, 2, 3]
    end

    test "vector with single arg wraps in vector" do
      {:ok, result, _} = run("(vector 1)")
      assert result == [1]
    end

    test "vector with no args returns empty vector" do
      {:ok, result, _} = run("(vector)")
      assert result == []
    end
  end

  describe "set as predicate" do
    test "set returns element when found" do
      {:ok, result, _} = run(~S"(#{1 2 3} 2)")
      assert result == 2
    end

    test "set returns nil when not found" do
      {:ok, result, _} = run(~S"(#{1 2 3} 4)")
      assert result == nil
    end

    test "set works with filter" do
      {:ok, result, _} = run(~S'(filter #{"a" "b"} ["a" "c" "b" "d"])')
      assert result == ["a", "b"]
    end

    test "set works with some" do
      {:ok, result, _} = run(~S'(some #{"x"} ["a" "x" "b"])')
      assert result == "x"
    end

    test "set with some returns nil when no match" do
      {:ok, result, _} = run(~S'(some #{"z"} ["a" "b"])')
      assert result == nil
    end

    test "empty set always returns nil" do
      {:ok, result, _} = run(~S"(#{} :anything)")
      assert result == nil
    end

    test "set with wrong arity returns error" do
      {:error, %Step{fail: %{reason: :arity_error, message: message}}} = run(~S"(#{1 2} 1 2)")
      assert message =~ "set expects 1 argument, got 2"
    end

    test "set with keywords works as predicate" do
      {:ok, result, _} = run(~S"(#{:a :b :c} :b)")
      assert result == :b
    end

    test "set with single element" do
      {:ok, result, _} = run(~S"(#{:a} :a)")
      assert result == :a
    end

    test "set works with remove" do
      {:ok, result, _} = run(~S'(remove #{"b"} ["a" "b" "c"])')
      assert result == ["a", "c"]
    end

    test "set works with every?" do
      {:ok, result, _} = run(~S'(every? #{1 2 3} [1 2])')
      assert result == true
    end

    test "set works with not-any?" do
      {:ok, result, _} = run(~S'(not-any? #{4 5} [1 2 3])')
      assert result == true
    end

    test "set works with find" do
      {:ok, result, _} = run(~S'(find #{"b" "c"} ["a" "b" "d"])')
      assert result == "b"
    end

    test "set with find returns nil when no match" do
      {:ok, result, _} = run(~S'(find #{"x" "y"} ["a" "b" "c"])')
      assert result == nil
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

  describe "clojure.set operations" do
    test "intersection returns intersection of sets" do
      {:ok, result, _} = run(~S"(clojure.set/intersection #{1 2} #{2 3})")
      assert MapSet.equal?(result, MapSet.new([2]))

      {:ok, result, _} = run(~S"(clojure.set/intersection #{1 2} #{2 3} #{2 4})")
      assert MapSet.equal?(result, MapSet.new([2]))

      {:ok, result, _} = run(~S"(clojure.set/intersection #{1 2})")
      assert MapSet.equal?(result, MapSet.new([1, 2]))
    end

    test "union returns union of sets" do
      {:ok, result, _} = run(~S"(clojure.set/union #{1} #{2})")
      assert MapSet.equal?(result, MapSet.new([1, 2]))

      {:ok, result, _} = run(~S"(clojure.set/union #{1} #{2} #{3})")
      assert MapSet.equal?(result, MapSet.new([1, 2, 3]))

      {:ok, result, _} = run(~S"(clojure.set/union)")
      assert MapSet.equal?(result, MapSet.new([]))
    end

    test "difference returns difference of sets" do
      {:ok, result, _} = run(~S"(clojure.set/difference #{1 2 3} #{2})")
      assert MapSet.equal?(result, MapSet.new([1, 3]))

      {:ok, result, _} = run(~S"(clojure.set/difference #{1 2 3} #{2} #{3})")
      assert MapSet.equal?(result, MapSet.new([1]))

      {:ok, result, _} = run(~S"(clojure.set/difference #{1 2})")
      assert MapSet.equal?(result, MapSet.new([1, 2]))
    end

    test "intersection/difference require at least 1 arg" do
      {:error, %Step{fail: %{reason: :arity_error}}} = run("(clojure.set/intersection)")
      {:error, %Step{fail: %{reason: :arity_error}}} = run("(clojure.set/difference)")
    end

    test "set operations work with set/ alias" do
      {:ok, result, _} = run(~S"(set/intersection #{1 2} #{2 3})")
      assert MapSet.equal?(result, MapSet.new([2]))
    end
  end

  defp run(source) do
    case PtcRunner.Lisp.run(source) do
      {:ok, %Step{return: result}} -> {:ok, result, %{}}
      {:error, %Step{} = step} -> {:error, step}
      {:error, reason} -> {:error, reason}
    end
  end
end
