defmodule PtcRunner.Lisp.ExtractFunctionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "extract" do
    test "extracts group 1 by default" do
      source = ~S|(extract "ID:(\\d+)" "ID:42")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "42"
    end

    test "extracts full match with group 0" do
      source = ~S|(extract "ID:(\\d+)" "ID:42" 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "ID:42"
    end

    test "extracts specific group" do
      source = ~S|(extract "x=(\\d+)\\s+y=(\\d+)" "x=10 y=20" 2)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "20"
    end

    test "returns nil when no match" do
      source = ~S|(extract "ID:(\\d+)" "no match")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "returns nil when group does not exist" do
      source = ~S|(extract "ID:(\\d+)" "ID:42" 5)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "works with compiled regex" do
      source = ~S|
        (let [re (re-pattern "age=(\\d+)")]
          (extract re "age=25"))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "25"
    end

    test "works in pipeline" do
      source = ~S|(->> "Profile ID:99 created" (extract "ID:(\\d+)"))|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "99"
    end
  end

  describe "extract-int" do
    test "extracts and parses integer from group 1" do
      source = ~S|(extract-int "age=(\\d+)" "age=25")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 25
    end

    test "returns nil when no match (2-arity)" do
      source = ~S|(extract-int "age=(\\d+)" "no match")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "returns default when no match (4-arity)" do
      source = ~S|(extract-int "age=(\\d+)" "no match" 1 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 0
    end

    test "extracts from specific group with default" do
      source = ~S|(extract-int "x=(\\d+) y=(\\d+)" "x=10 y=20" 2 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 20
    end

    test "returns default when group does not exist" do
      source = ~S|(extract-int "x=(\\d+)" "x=10" 5 -1)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == -1
    end

    test "returns default when group is not a valid integer" do
      source = ~S|(extract-int "value=(\\w+)" "value=abc" 1 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 0
    end

    test "works with compiled regex" do
      source = ~S|
        (let [re (re-pattern "count=(\\d+)")]
          (extract-int re "count=42"))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 42
    end

    test "typical use case: parsing profile line" do
      source = ~S|
        (let [line "PROFILE 123: status=active"]
          (extract-int "PROFILE (\\d+):" line))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 123
    end

    test "works in map over lines" do
      source = ~S|
        (let [lines ["ID:1" "ID:2" "ID:3"]]
          (map #(extract-int "ID:(\\d+)" %) lines))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end
  end

  describe "parse-int alias" do
    test "parse-int works as alias for parse-long" do
      source = ~S|(parse-int "42")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 42
    end

    test "returns nil for invalid input" do
      source = ~S|(parse-int "abc")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end
  end
end
