defmodule PtcRunner.Lisp.Runtime.DescribeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime.Describe

  describe "describe/1 scalars" do
    test "summarizes strings and numeric-looking strings" do
      assert Describe.describe("42") == %{
               type: "string",
               sample: "42",
               types: %{"string" => 1},
               examples: ["42"],
               non_empty: 1,
               range: %{min: 42.0, max: 42.0},
               distinct_count: 1
             }
    end

    test "classifies special float atoms before keywords" do
      assert %{type: "nan", types: %{"nan" => 1}} = Describe.describe(:nan)
      assert %{type: "infinity", types: %{"infinity" => 1}} = Describe.describe(:infinity)
      refute Map.has_key?(Describe.describe([:nan, :infinity]), :range)
    end

    test "does not treat keyword structs as non-empty maps" do
      result = Describe.describe(PtcRunner.Lisp.Keyword.new("a"))

      assert result.type == "keyword"
      refute Map.has_key?(result, :non_empty)
    end

    test "bounds returned scalar samples and examples" do
      value = String.duplicate("x", 200)

      result = Describe.describe(value)

      assert String.length(result.sample) < String.length(value)
      assert result.sample == hd(result.examples)
      assert result.sample =~ "200 chars"
    end

    test "projects container examples instead of returning raw nested values" do
      result = Describe.describe(%{"payload" => [String.duplicate("x", 200)]})

      assert is_binary(result.keys["payload"].examples |> hd())
      assert String.length(result.keys["payload"].examples |> hd()) <= 134
    end
  end

  describe "describe/1 maps" do
    test "summarizes key types and omits degenerate presence for single maps" do
      result = Describe.describe(%{"a" => 1, :b => nil})

      assert result.type == "map"
      assert result.count == 2
      assert result.key_types == %{"keyword" => 1, "string" => 1}
      assert result.keys["a"].types == %{"integer" => 1}
      assert result.keys[":b"].types == %{"nil" => 1}
      refute Map.has_key?(result.keys["a"], :present)
      refute Map.has_key?(result.keys["a"], :pct)
    end

    test "caps large map key summaries" do
      map = Map.new(1..105, &{"k#{&1}", &1})

      result = Describe.describe(map)

      assert map_size(result.keys) == 100
      assert result.truncated == true
      assert "max_keys" in result.caps_hit
    end

    test "caps large map key summaries deterministically" do
      map = Map.new(150..1//-1, &{"k#{String.pad_leading(to_string(&1), 3, "0")}", &1})

      result = Describe.describe(map)

      assert map_size(result.keys) == 100
      assert Map.has_key?(result.keys, "k001")
      assert Map.has_key?(result.keys, "k100")
      refute Map.has_key?(result.keys, "k101")
      assert "max_keys" in result.caps_hit
    end

    test "disambiguates map keys with colliding rendered labels" do
      result = Describe.describe(%{":a" => 1, :a => 2, "1" => 3, 1 => 4})

      assert result.keys["string::a"].examples == [1]
      assert result.keys["keyword::a"].examples == [2]
      assert result.keys["string:1"].examples == [3]
      assert result.keys["integer:1"].examples == [4]
    end

    test "disambiguates long string keys that truncate to the same label" do
      prefix = String.duplicate("a", 130)
      result = Describe.describe(%{(prefix <> "x") => 1, (prefix <> "y") => 2})

      assert map_size(result.keys) == 2
      assert Enum.all?(Map.keys(result.keys), &String.starts_with?(&1, "string:"))
      assert Enum.all?(Map.keys(result.keys), &String.contains?(&1, "#"))
    end
  end

  describe "describe/1 collections" do
    test "reports non_empty: 0 for collection fields that are always empty" do
      rows = [
        %{"limits" => [], "n" => 1},
        %{"limits" => [], "n" => 2}
      ]

      result = Describe.describe(rows)

      assert result.keys["limits"].non_empty == 0
      refute Map.has_key?(result.keys["n"], :non_empty)
    end

    test "caps set scans without materializing the whole set as a list" do
      result = Describe.describe(MapSet.new(1..1001))

      assert result.type == "set"
      assert result.count == 1001
      assert result.scanned == 1000
      assert result.item_types == %{"integer" => 1000}
      assert "max_items" in result.caps_hit
    end

    test "summarizes vector of maps with key coverage" do
      rows = [
        %{"event" => "turn", "fail" => nil},
        %{"event" => "turn", "fail" => %{"reason" => "x"}}
      ]

      result = Describe.describe(rows)

      assert result.type == "vector"
      assert result.count == 2
      assert result.scanned == 2
      assert result.item_types == %{"map" => 2}
      assert result.key_types == %{"string" => 4}
      assert result.keys["event"].present == 2
      assert result.keys["event"].pct == 100.0
      assert result.keys["event"].distinct_count == 1
      assert result.keys["fail"].types == %{"map" => 1, "nil" => 1}
    end

    test "caps distinct counts without tracking every scalar value" do
      rows = Enum.map(1..60, &%{"id" => &1})

      result = Describe.describe(rows)

      assert result.keys["id"].distinct_count == 50
      assert result.keys["id"].distinct_capped == true
    end

    test "summarizes mixed item types" do
      assert %{item_types: %{"integer" => 1, "map" => 1, "string" => 1}} =
               Describe.describe([1, "x", %{"a" => 1}])
    end

    test "caps root item scans" do
      result = Describe.describe(Enum.map(1..1001, &%{"i" => &1}))

      assert result.count == 1000
      assert result.count_capped == true
      assert result.scanned == 1000
      assert result.truncated == true
      assert "max_items" in result.caps_hit
    end

    test "propagates map key caps from collection items" do
      result = Describe.describe([Map.new(1..105, &{"k#{&1}", &1})])

      assert result.truncated == true
      assert "max_keys" in result.caps_hit
    end

    test "caps distinct key summaries across collection items" do
      rows = Enum.map(1..150, &%{"k#{&1}" => &1})

      result = Describe.describe(rows)

      assert map_size(result.keys) == 100
      assert result.truncated == true
      assert "max_keys" in result.caps_hit
    end

    test "keeps colliding long collection keys distinct" do
      prefix = String.duplicate("a", 130)
      rows = [%{(prefix <> "x") => 1}, %{(prefix <> "y") => 2}]

      result = Describe.describe(rows)

      assert map_size(result.keys) == 2
      assert Enum.all?(Map.keys(result.keys), &String.starts_with?(&1, "string:"))
      assert Enum.all?(Map.keys(result.keys), &String.contains?(&1, "#"))
    end

    test "merges cap metadata from root and nested summaries" do
      rows = Enum.map(1..1001, fn _index -> Map.new(1..105, &{"k#{&1}", &1}) end)

      result = Describe.describe(rows)

      assert result.truncated == true
      assert "max_items" in result.caps_hit
      assert "max_keys" in result.caps_hit
    end
  end

  describe "describe/2 with paths" do
    test "summarizes nested paths" do
      rows = [
        %{"data" => %{"tool_calls" => [1], "limits_hit" => []}},
        %{"data" => %{"tool_calls" => [], "limits_hit" => ["x"]}}
      ]

      result = Describe.describe(rows, %{paths: true, depth: 3})

      assert result.paths["data"].present == 2
      assert result.paths["data.tool_calls"].types == %{"vector" => 2}
      assert result.paths["data.tool_calls"].non_empty == 1
      assert result.paths["data.limits_hit"].non_empty == 1
    end

    test "caps path summaries" do
      map = Enum.map(1..305, &%{"k#{&1}" => &1})

      result = Describe.describe(map, %{paths: true, depth: 1})

      assert map_size(result.paths) == 300
      assert result.truncated == true
      assert "max_paths" in result.caps_hit
    end

    test "enforces path cap while collecting unique paths" do
      rows = Enum.map(1..305, &%{"row#{&1}" => %{"value" => &1}})

      result = Describe.describe(rows, %{paths: true, depth: 2})

      assert map_size(result.paths) == 300
      assert "max_paths" in result.caps_hit
      refute Map.has_key?(result.paths, "row305")
    end

    test "counts path presence by root row when nested lists fan out" do
      rows = [
        %{"a" => [%{"b" => 1}, %{"b" => 2}]},
        %{"a" => []}
      ]

      result = Describe.describe(rows, %{paths: true, depth: 2})

      assert result.paths["a.b"].present == 1
      assert result.paths["a.b"].pct == 50.0
      assert result.paths["a.b"].value_count == 2
    end

    test "escapes path separators in map keys" do
      result = Describe.describe(%{"a.b" => 1, "a" => %{"b" => 2}}, %{paths: true, depth: 2})

      assert result.paths["a\\.b"].types == %{"integer" => 1}
      assert result.paths["a.b"].types == %{"integer" => 1}
      assert result.paths["a\\.b"].examples == [1]
      assert result.paths["a.b"].examples == [2]
    end

    test "keeps string and keyword path keys distinct" do
      result = Describe.describe(%{"a" => 1, :a => 2, ":b" => 3, b: 4}, %{paths: true, depth: 1})

      assert result.paths["a"].examples == [1]
      assert result.paths[":a"].examples == [2]
      assert result.paths["string::b"].examples == [3]
      assert result.paths["keyword::b"].examples == [4]
    end

    test "caps total path values from nested list fanout" do
      rows = Enum.map(1..20, fn _ -> %{"items" => Enum.map(1..600, &%{"id" => &1})} end)

      result = Describe.describe(rows, %{paths: true, depth: 2})

      assert result.truncated == true
      assert "max_path_values" in result.caps_hit
      assert result.paths["items.id"].value_count <= 10_000
    end

    test "propagates map key caps from nested paths" do
      result =
        Describe.describe(%{"wide" => Map.new(1..105, &{"k#{&1}", &1})}, %{
          paths: true,
          depth: 2
        })

      assert result.truncated == true
      assert "max_keys" in result.caps_hit
    end

    test "caps nested list traversal under paths" do
      value = %{"a" => [[[[[[%{"b" => 1}]]]]]]}

      result = Describe.describe(value, %{paths: true, depth: 2})

      assert result.truncated == true
      assert "max_depth" in result.caps_hit
      refute Map.has_key?(result.paths, "a.b")
    end
  end
end
