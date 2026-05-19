defmodule PtcRunner.Lisp.EvalJsonTest do
  @moduledoc """
  End-to-end PTC-Lisp tests for `json/parse-string` and `json/generate-string`.

  Covers OQ-5 dispatch (analyzer routes namespaced calls to their qualified
  env keys), the threaded-pipeline use case, and the analyzer's redirect
  from `cheshire.core/...` (Plans/json-support.md §10.4).
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "json/parse-string in PTC-Lisp programs" do
    test "parses a simple object" do
      assert {:ok, %{return: %{"a" => 1, "b" => [2, 3]}}} =
               Lisp.run(~S|(json/parse-string "{\"a\": 1, \"b\": [2, 3]}")|)
    end

    test "returns nil on garbage input (no raise)" do
      assert {:ok, %{return: nil}} = Lisp.run(~S|(json/parse-string "not json")|)
    end

    test "returns nil on nil input" do
      assert {:ok, %{return: nil}} = Lisp.run("(json/parse-string nil)")
    end

    test "is usable in symbol position (var reference)" do
      # OQ-5 coverage: namespaced builtin must resolve in symbol position too.
      # Pass json/parse-string as a function value into apply.
      source = ~S|(apply json/parse-string ["[1, 2, 3]"])|
      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(source)
    end
  end

  describe "json/generate-string in PTC-Lisp programs" do
    test "encodes a string-keyed map" do
      assert {:ok, %{return: result}} =
               Lisp.run(~S|(json/generate-string {"a" 1, "b" [2 3]})|)

      assert result in [~S|{"a":1,"b":[2,3]}|, ~S|{"b":[2,3],"a":1}|]
    end

    test "returns nil for keyword keys (DIV-24)" do
      assert {:ok, %{return: nil}} = Lisp.run(~S|(json/generate-string {:server "fs"})|)
    end

    test "returns nil for keyword values (DIV-24)" do
      assert {:ok, %{return: nil}} = Lisp.run(~S|(json/generate-string {"server" :fs})|)
    end

    test "encodes after explicit string conversion" do
      assert {:ok, %{return: ~S|{"server":"fs"}|}} =
               Lisp.run(~S|(json/generate-string {"server" (name :fs)})|)
    end

    test "returns nil for special-float carve-out (POSITIVE_INFINITY)" do
      assert {:ok, %{return: nil}} = Lisp.run("(json/generate-string POSITIVE_INFINITY)")
    end

    test "returns nil for NaN" do
      assert {:ok, %{return: nil}} = Lisp.run("(json/generate-string NaN)")
    end
  end

  describe "threaded pipeline using both forms" do
    test "round-trips through ->> with intermediate transforms" do
      # Parse -> transform -> regenerate, exercising both builtins in a
      # threaded pipeline (the §1 motivating use case).
      source = ~S"""
      (->> (json/parse-string "{\"a\": 1, \"b\": 2, \"c\": 3}")
           (filter (fn [[_ v]] (> v 1)))
           (into {})
           (json/generate-string))
      """

      assert {:ok, %{return: result}} = Lisp.run(source)
      assert is_binary(result)

      # Round-trip through parse to make the assertion order-independent.
      decoded = Jason.decode!(result)
      assert decoded == %{"b" => 2, "c" => 3}
    end
  end

  describe "analyzer redirect for cheshire.core/parse-string (§10.4)" do
    test "unknown namespace error points at json/parse-string" do
      source = ~S|(cheshire.core/parse-string "{}")|
      assert {:error, %{fail: %{message: msg}}} = Lisp.run(source)
      assert msg =~ "unknown namespace"
      assert msg =~ "cheshire.core"
      assert msg =~ "json/parse-string"
    end
  end

  describe "analyzer suggestions for unknown json/ members" do
    test "json/foo lists the available json/* members" do
      source = ~S|(json/foo "x")|
      assert {:error, %{fail: %{message: msg}}} = Lisp.run(source)
      assert msg =~ "json/foo is not available"
      assert msg =~ "json/parse-string"
      assert msg =~ "json/generate-string"
    end
  end

  describe "removed MCP helper namespace" do
    test "mcp/text is an unknown namespace instead of an empty known namespace" do
      assert {:error, %{fail: %{message: msg}}} = Lisp.run(~S|(mcp/text {})|)

      assert msg =~ "unknown namespace"
      assert msg =~ "mcp"
      refute msg =~ "MCP functions"
    end
  end
end
