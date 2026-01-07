defmodule PtcRunner.Lisp.RuntimeCollectionTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime

  describe "into - collecting from maps" do
    test "into [] with empty map returns empty list" do
      result = Runtime.into([], %{})
      assert result == []
    end

    test "into [] with map converts entries to vectors" do
      result = Runtime.into([], %{a: 1, b: 2})
      # Result is a list of [key, value] vectors
      assert length(result) == 2
      assert [:a, 1] in result
      assert [:b, 2] in result
    end

    test "into [] with string-keyed map converts entries to vectors" do
      result = Runtime.into([], %{"x" => 10, "y" => 20})
      assert length(result) == 2
      assert ["x", 10] in result
      assert ["y", 20] in result
    end

    test "into [] with nested map values preserves structure" do
      result = Runtime.into([], %{a: %{b: 1}})
      assert result == [[:a, %{b: 1}]]
    end

    test "into with existing vector preserves existing elements" do
      result = Runtime.into([99], %{a: 1})
      assert 99 in result
      assert [:a, 1] in result
    end
  end

  describe "into - collecting from lists" do
    test "into [] with empty list returns empty list" do
      result = Runtime.into([], [])
      assert result == []
    end

    test "into [] with list keeps elements as-is (no map conversion)" do
      result = Runtime.into([], [1, 2, 3])
      assert result == [1, 2, 3]
    end

    test "into with existing vector appends list elements" do
      result = Runtime.into([99], [1, 2])
      assert result == [99, 1, 2]
    end

    test "into with nil list source returns original list" do
      result = Runtime.into([1, 2], nil)
      assert result == [1, 2]
    end
  end

  describe "into - collecting into MapSets" do
    test "into #{} with list adds elements to set" do
      result = Runtime.into(MapSet.new(), [1, 2, 3])
      assert result == MapSet.new([1, 2, 3])
    end

    test "into #{1} with list adds new elements" do
      result = Runtime.into(MapSet.new([1]), [2, 3])
      assert result == MapSet.new([1, 2, 3])
    end

    test "into #{} with another MapSet unions them" do
      result = Runtime.into(MapSet.new([1]), MapSet.new([2, 3]))
      assert result == MapSet.new([1, 2, 3])
    end

    test "into #{} with map converts to list of entries" do
      result = Runtime.into(MapSet.new(), %{a: 1})
      assert result == MapSet.new([[:a, 1]])
    end

    test "into #{} with nil returns empty set (or original set)" do
      result = Runtime.into(MapSet.new([1]), nil)
      assert result == MapSet.new([1])
    end

    test "into #{} with empty map returns original set" do
      result = Runtime.into(MapSet.new([1]), %{})
      assert result == MapSet.new([1])
    end
  end

  describe "into - collecting into Maps" do
    test "into {} with list of pairs creates map" do
      result = Runtime.into(%{}, [[:a, 1], [:b, 2]])
      assert result == %{a: 1, b: 2}
    end

    test "into {:a 1} with list of pairs merges them" do
      result = Runtime.into(%{a: 1}, [[:b, 2]])
      assert result == %{a: 1, b: 2}
    end

    test "into {} with MapSet of pairs creates map" do
      result = Runtime.into(%{}, MapSet.new([[:a, 1], [:b, 2]]))
      assert result == %{a: 1, b: 2}
    end

    test "into {} with another map merges them" do
      result = Runtime.into(%{a: 1}, %{b: 2})
      assert result == %{a: 1, b: 2}
    end

    test "into {} with nil returns original map" do
      result = Runtime.into(%{a: 1}, nil)
      assert result == %{a: 1}
    end

    test "into {} with empty set returns original map" do
      result = Runtime.into(%{a: 1}, MapSet.new())
      assert result == %{a: 1}
    end

    test "into {:a 1} with list of pairs [[:a 2]] overwrites existing key" do
      result = Runtime.into(%{a: 1}, [[:a, 2]])
      assert result == %{a: 2}
    end

    test "into {} with invalid entries raises type_error" do
      assert_raise RuntimeError, ~r/type_error: into: invalid map entry: 1/, fn ->
        Runtime.into(%{}, [1, 2, 3])
      end

      assert_raise RuntimeError, ~r/type_error: into: invalid map entry: \[:a\]/, fn ->
        Runtime.into(%{}, [[:a]])
      end

      assert_raise RuntimeError, ~r/type_error: into: invalid map entry: \[:a, 1, 2\]/, fn ->
        Runtime.into(%{}, [[:a, 1, 2]])
      end
    end
  end

  describe "filter - seqable map support" do
    test "filter on empty map returns empty list" do
      result = Runtime.filter(fn _entry -> true end, %{})
      assert result == []
    end

    test "filter on map keeps entries where predicate is true, returns list of pairs" do
      map = %{a: 1, b: 2, c: 3}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) > 1 end, map)
      # Returns list of [key, value] pairs, sorted for comparison
      assert Enum.sort(result) == [[:b, 2], [:c, 3]]
    end

    test "filter on map removes entries where predicate is false" do
      map = %{a: 10, b: 5, c: 15}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) > 7 end, map)
      assert Enum.sort(result) == [[:a, 10], [:c, 15]]
    end

    test "filter on map with atom keys works correctly" do
      map = %{x: "hello", y: "world", z: "test"}
      result = Runtime.filter(fn entry -> String.length(Enum.at(entry, 1)) > 4 end, map)
      assert Enum.sort(result) == [[:x, "hello"], [:y, "world"]]
    end

    test "filter on map with string keys works correctly" do
      map = %{"a" => 1, "b" => 2, "c" => 3}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) <= 2 end, map)
      assert Enum.sort(result) == [["a", 1], ["b", 2]]
    end
  end

  describe "remove - seqable map support" do
    test "remove on empty map returns empty list" do
      result = Runtime.remove(fn _entry -> true end, %{})
      assert result == []
    end

    test "remove on map removes entries where predicate is true, returns list of pairs" do
      map = %{a: 1, b: 2, c: 3}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) == 2 end, map)
      assert Enum.sort(result) == [[:a, 1], [:c, 3]]
    end

    test "remove on map keeps entries where predicate is false" do
      map = %{a: 10, b: 5, c: 15}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) > 7 end, map)
      assert result == [[:b, 5]]
    end

    test "remove on map with atom keys works correctly" do
      map = %{x: "hello", y: "world", z: "test"}
      result = Runtime.remove(fn entry -> String.length(Enum.at(entry, 1)) > 4 end, map)
      assert result == [[:z, "test"]]
    end

    test "remove on map with string keys works correctly" do
      map = %{"a" => 1, "b" => 2, "c" => 3}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) <= 2 end, map)
      assert result == [["c", 3]]
    end
  end

  describe "sort_by - seqable map support" do
    test "sort_by on map returns list of pairs in sorted order" do
      map = %{a: 3, b: 1, c: 2}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, map)
      # Returns list of [key, value] pairs in sorted order (preserves order unlike maps)
      assert result == [[:b, 1], [:c, 2], [:a, 3]]
    end

    test "sort_by on empty map with function returns empty list" do
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, %{})
      assert result == []
    end

    test "sort_by on map with comparator sorts entries in order" do
      map = %{a: 1, b: 3, c: 2}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, &>=/2, map)
      assert result == [[:b, 3], [:c, 2], [:a, 1]]
    end

    test "sort_by on map with string values preserves sort order" do
      map = %{x: "cherry", y: "apple", z: "banana"}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, map)
      assert result == [[:y, "apple"], [:z, "banana"], [:x, "cherry"]]
    end

    test "sort_by on map with numeric values descending preserves order" do
      map = %{a: 100, b: 50, c: 75}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, &>=/2, map)
      assert result == [[:a, 100], [:c, 75], [:b, 50]]
    end
  end

  describe "entries function" do
    test "entries on empty map returns empty list" do
      result = Runtime.entries(%{})
      assert result == []
    end

    test "entries on map returns list of [key, value] pairs" do
      result = Runtime.entries(%{a: 1, b: 2})
      assert result == [[:a, 1], [:b, 2]]
    end

    test "entries returns pairs sorted by key" do
      result = Runtime.entries(%{z: 26, a: 1, m: 13})
      assert result == [[:a, 1], [:m, 13], [:z, 26]]
    end

    test "entries with string keys returns sorted pairs" do
      result = Runtime.entries(%{"z" => 26, "a" => 1, "m" => 13})
      assert result == [["a", 1], ["m", 13], ["z", 26]]
    end

    test "entries with mixed string and numeric values" do
      result = Runtime.entries(%{x: "hello", y: 42})
      assert result == [[:x, "hello"], [:y, 42]]
    end
  end

  describe "identity function" do
    test "identity returns its argument unchanged" do
      assert Runtime.identity(42) == 42
      assert Runtime.identity("hello") == "hello"
      assert Runtime.identity([1, 2, 3]) == [1, 2, 3]
      assert Runtime.identity(%{a: 1}) == %{a: 1}
    end

    test "identity with nil returns nil" do
      assert Runtime.identity(nil) == nil
    end
  end

  describe "zip - returns vectors not tuples" do
    test "zip returns list of vectors" do
      result = Runtime.zip([1, 2, 3], [:a, :b, :c])
      assert result == [[1, :a], [2, :b], [3, :c]]
    end

    test "zip with empty lists returns empty list" do
      result = Runtime.zip([], [])
      assert result == []
    end

    test "zip with unequal lengths truncates to shorter" do
      result = Runtime.zip([1, 2], [:a, :b, :c])
      assert result == [[1, :a], [2, :b]]
    end

    test "zip elements are accessible with first/second" do
      result = Runtime.zip([1, 2], [:a, :b])
      first_pair = List.first(result)
      assert Runtime.first(first_pair) == 1
      assert Runtime.second(first_pair) == :a
    end

    test "zip elements are accessible with nth" do
      result = Runtime.zip([1, 2], [:a, :b])
      first_pair = List.first(result)
      assert Runtime.nth(first_pair, 0) == 1
      assert Runtime.nth(first_pair, 1) == :a
    end
  end

  describe "update_vals" do
    # Note: Arguments are (m, f) matching Clojure's (update-vals m f)

    test "applies function to each value" do
      map = %{a: [1, 2], b: [3, 4, 5]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{a: 2, b: 3}
    end

    test "works with empty map" do
      result = Runtime.update_vals(%{}, &length/1)
      assert result == %{}
    end

    test "works with nil map" do
      result = Runtime.update_vals(nil, &length/1)
      assert result == nil
    end

    test "preserves keys (string keys)" do
      map = %{"pending" => [1, 2], "done" => [3]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{"pending" => 2, "done" => 1}
    end

    test "preserves keys (atom keys)" do
      map = %{pending: [1, 2], done: [3]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{pending: 2, done: 1}
    end

    test "works with count function for group-by use case" do
      # Simulates (->> (group-by :status orders) (update-vals count))
      grouped = %{
        "pending" => [%{id: 1}, %{id: 2}],
        "delivered" => [%{id: 3}]
      }

      result = Runtime.update_vals(grouped, &Enum.count/1)
      assert result == %{"pending" => 2, "delivered" => 1}
    end

    test "works with sum aggregation" do
      grouped = %{
        "a" => [%{amount: 10}, %{amount: 20}],
        "b" => [%{amount: 5}]
      }

      sum_amounts = fn items -> Enum.sum(Enum.map(items, & &1.amount)) end
      result = Runtime.update_vals(grouped, sum_amounts)
      assert result == %{"a" => 30, "b" => 5}
    end
  end

  describe "parse_long" do
    test "parses valid integers" do
      assert Runtime.parse_long("42") == 42
      assert Runtime.parse_long("-17") == -17
      assert Runtime.parse_long("0") == 0
    end

    test "returns nil for invalid input" do
      assert Runtime.parse_long("abc") == nil
      assert Runtime.parse_long("3.14") == nil
      assert Runtime.parse_long(" 42") == nil
      assert Runtime.parse_long("42abc") == nil
    end

    test "handles nil and non-strings" do
      assert Runtime.parse_long(nil) == nil
      assert Runtime.parse_long(42) == nil
    end
  end

  describe "parse_double" do
    test "parses valid floats" do
      assert Runtime.parse_double("3.14") == 3.14
      assert Runtime.parse_double("-0.5") == -0.5
      assert Runtime.parse_double("42") == 42.0
      assert Runtime.parse_double("1e10") == 1.0e10
    end

    test "returns nil for invalid input" do
      assert Runtime.parse_double("abc") == nil
      assert Runtime.parse_double(" 3.14") == nil
      assert Runtime.parse_double("3.14abc") == nil
    end

    test "handles nil and non-strings" do
      assert Runtime.parse_double(nil) == nil
      assert Runtime.parse_double(3.14) == nil
    end
  end

  describe "str2" do
    test "concatenates two strings" do
      assert Runtime.str2("hello", " world") == "hello world"
    end

    test "converts non-string values to string" do
      assert Runtime.str2("count: ", 42) == "count: 42"
      assert Runtime.str2("value: ", true) == "value: true"
    end

    test "handles nil by converting to empty string" do
      assert Runtime.str2("x", nil) == "x"
      assert Runtime.str2(nil, "y") == "y"
      assert Runtime.str2(nil, nil) == ""
    end

    test "converts keyword atoms to :keyword format" do
      assert Runtime.str2("keyword: ", :my_key) == "keyword: :my_key"
    end
  end

  describe "subs" do
    test "returns substring from start index" do
      assert Runtime.subs("hello", 1) == "ello"
      assert Runtime.subs("hello", 0) == "hello"
    end

    test "returns substring from start to end index" do
      assert Runtime.subs("hello", 1, 3) == "el"
      assert Runtime.subs("hello", 0, 5) == "hello"
      assert Runtime.subs("hello", 0, 0) == ""
    end

    test "clamps negative indices to 0" do
      assert Runtime.subs("hello", -1) == "hello"
      assert Runtime.subs("hello", -10, 2) == "he"
    end

    test "handles out of bounds indices" do
      assert Runtime.subs("hello", 10) == ""
      assert Runtime.subs("hello", 3, 10) == "lo"
    end
  end

  describe "join" do
    test "joins collection without separator" do
      assert Runtime.join(["a", "b", "c"]) == "abc"
      assert Runtime.join([]) == ""
    end

    test "joins collection with separator" do
      assert Runtime.join(", ", ["a", "b", "c"]) == "a, b, c"
      assert Runtime.join("-", [1, 2, 3]) == "1-2-3"
    end

    test "converts elements to strings" do
      assert Runtime.join(", ", [1, "two", true]) == "1, two, true"
    end

    test "handles empty collection" do
      assert Runtime.join(", ", []) == ""
    end

    test "handles nil in collection" do
      assert Runtime.join(", ", [1, nil, 3]) == "1, , 3"
    end
  end

  describe "split" do
    test "splits string by separator" do
      assert Runtime.split("a,b,c", ",") == ["a", "b", "c"]
      assert Runtime.split("hello world", " ") == ["hello", "world"]
    end

    test "splits string into graphemes when separator is empty" do
      assert Runtime.split("hello", "") == ["h", "e", "l", "l", "o"]
    end

    test "preserves empty strings in split" do
      assert Runtime.split("a,,b", ",") == ["a", "", "b"]
    end
  end

  describe "trim" do
    test "removes leading and trailing whitespace" do
      assert Runtime.trim("  hello  ") == "hello"
      assert Runtime.trim("\n\t text \r\n") == "text"
    end

    test "removes only leading and trailing, not middle" do
      assert Runtime.trim("  hello   world  ") == "hello   world"
    end

    test "handles no whitespace" do
      assert Runtime.trim("hello") == "hello"
    end
  end

  describe "replace" do
    test "replaces all occurrences of pattern" do
      assert Runtime.replace("hello", "l", "L") == "heLLo"
      assert Runtime.replace("aaa", "a", "b") == "bbb"
    end

    test "replaces multiple patterns sequentially" do
      result = Runtime.replace("hello", "l", "1")
      assert result == "he11o"
    end

    test "handles no match" do
      assert Runtime.replace("hello", "x", "y") == "hello"
    end

    test "handles empty replacement" do
      assert Runtime.replace("hello", "l", "") == "heo"
    end
  end

  describe "upcase" do
    test "converts string to uppercase" do
      assert Runtime.upcase("hello") == "HELLO"
      assert Runtime.upcase("Hello World") == "HELLO WORLD"
    end

    test "handles empty string" do
      assert Runtime.upcase("") == ""
    end

    test "handles already uppercase string" do
      assert Runtime.upcase("HELLO") == "HELLO"
    end

    test "handles mixed case" do
      assert Runtime.upcase("HeLLo") == "HELLO"
    end
  end

  describe "downcase" do
    test "converts string to lowercase" do
      assert Runtime.downcase("HELLO") == "hello"
      assert Runtime.downcase("Hello World") == "hello world"
    end

    test "handles empty string" do
      assert Runtime.downcase("") == ""
    end

    test "handles already lowercase string" do
      assert Runtime.downcase("hello") == "hello"
    end

    test "handles mixed case" do
      assert Runtime.downcase("HeLLo") == "hello"
    end
  end

  describe "starts_with?" do
    test "returns true when string starts with prefix" do
      assert Runtime.starts_with?("hello", "he") == true
      assert Runtime.starts_with?("hello world", "hello") == true
    end

    test "returns false when string does not start with prefix" do
      assert Runtime.starts_with?("hello", "x") == false
      assert Runtime.starts_with?("hello", "ello") == false
    end

    test "returns true for empty prefix" do
      assert Runtime.starts_with?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.starts_with?("Hello", "hello") == false
      assert Runtime.starts_with?("Hello", "He") == true
    end
  end

  describe "ends_with?" do
    test "returns true when string ends with suffix" do
      assert Runtime.ends_with?("hello", "lo") == true
      assert Runtime.ends_with?("hello world", "world") == true
    end

    test "returns false when string does not end with suffix" do
      assert Runtime.ends_with?("hello", "x") == false
      assert Runtime.ends_with?("hello", "hell") == false
    end

    test "returns true for empty suffix" do
      assert Runtime.ends_with?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.ends_with?("Hello", "hello") == false
      assert Runtime.ends_with?("Hello", "lo") == true
    end
  end

  describe "includes?" do
    test "returns true when string contains substring" do
      assert Runtime.includes?("hello", "ll") == true
      assert Runtime.includes?("hello world", "o w") == true
    end

    test "returns false when string does not contain substring" do
      assert Runtime.includes?("hello", "x") == false
      assert Runtime.includes?("hello", "xyz") == false
    end

    test "returns true for empty substring" do
      assert Runtime.includes?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.includes?("Hello", "hello") == false
      assert Runtime.includes?("hello", "ell") == true
    end
  end

  describe "filter - set as predicate on string" do
    test "filters string characters using set predicate" do
      result = Runtime.filter(MapSet.new(["r"]), "raspberry")
      assert result == ["r", "r", "r"]
    end

    test "filters string with multiple characters in set" do
      result = Runtime.filter(MapSet.new(["r", "a"]), "raspberry")
      assert result == ["r", "a", "r", "r"]
    end

    test "returns empty list when no characters match" do
      result = Runtime.filter(MapSet.new(["x", "z"]), "raspberry")
      assert result == []
    end
  end

  describe "remove - set as predicate on string" do
    test "removes string characters using set predicate" do
      result = Runtime.remove(MapSet.new(["r"]), "raspberry")
      assert result == ["a", "s", "p", "b", "e", "y"]
    end

    test "removes multiple characters from string" do
      result = Runtime.remove(MapSet.new(["r", "a"]), "raspberry")
      assert result == ["s", "p", "b", "e", "y"]
    end
  end

  describe "range" do
    test "range(end) returns sequence from 0 to end (exclusive)" do
      assert Runtime.range(5) == [0, 1, 2, 3, 4]
      assert Runtime.range(0) == []
      assert Runtime.range(-1) == []
    end

    test "range(start, end) returns sequence from start to end (exclusive)" do
      assert Runtime.range(5, 10) == [5, 6, 7, 8, 9]
      assert Runtime.range(10, 5) == []
      assert Runtime.range(5, 5) == []
    end

    test "range(start, end, step) returns sequence with step" do
      assert Runtime.range(0, 10, 2) == [0, 2, 4, 6, 8]
      assert Runtime.range(0, 10, 3) == [0, 3, 6, 9]
      assert Runtime.range(10, 0, -2) == [10, 8, 6, 4, 2]
      assert Runtime.range(10, 0, -3) == [10, 7, 4, 1]
    end

    test "range(start, end, step) with empty results" do
      assert Runtime.range(0, 10, -1) == []
      assert Runtime.range(10, 0, 1) == []
      assert Runtime.range(0, 1, 0) == []
    end

    test "range handles non-integer numbers (floats)" do
      assert Runtime.range(0, 2.5, 1) == [0, 1, 2]
      assert Runtime.range(0.5, 2.5, 0.5) == [0.5, 1.0, 1.5, 2.0]
    end
  end

  describe "frequencies" do
    test "counts occurrences of each element" do
      assert Runtime.frequencies([1, 2, 1, 3, 2, 1]) == %{1 => 3, 2 => 2, 3 => 1}
    end

    test "handles empty list" do
      assert Runtime.frequencies([]) == %{}
    end

    test "handles strings" do
      assert Runtime.frequencies(["a", "b", "a", "c", "b", "a"]) == %{
               "a" => 3,
               "b" => 2,
               "c" => 1
             }
    end

    test "handles atoms" do
      assert Runtime.frequencies([:pending, :done, :pending]) == %{pending: 2, done: 1}
    end

    test "handles mixed types" do
      assert Runtime.frequencies([1, "1", 1, :one]) == %{1 => 2, "1" => 1, :one => 1}
    end

    test "handles strings as graphemes" do
      assert Runtime.frequencies("hello") == %{"h" => 1, "e" => 1, "l" => 2, "o" => 1}
    end

    test "handles empty string" do
      assert Runtime.frequencies("") == %{}
    end
  end
end
