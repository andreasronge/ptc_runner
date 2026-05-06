defmodule PtcRunner.SubAgent.KeyNormalizerCanonicalTest do
  @moduledoc """
  Edge-case tests for `KeyNormalizer.canonical_cache_key/2`.

  See `Plans/text-mode-ptc-compute-tool.md` "Canonical Cache Key —
  Implementation Rule" for the normative rule list. This file pins each
  rule with a deliberate edge case so future drift is caught.

  Doctests on the module cover the happy-path examples; this file covers
  the corners (empty maps, nested mixed-key types, integer/float boundary
  values, insertion-order independence, tuples).
  """

  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.KeyNormalizer

  describe "tool name + args shape" do
    test "returns a {tool_name, args_map} tuple" do
      assert {"search", %{"q" => "x"}} =
               KeyNormalizer.canonical_cache_key("search", %{"q" => "x"})
    end

    test "empty args produce an empty map" do
      assert {"t", %{}} = KeyNormalizer.canonical_cache_key("t", %{})
    end

    test "single-key maps round-trip" do
      assert {"t", %{"foo" => 1}} =
               KeyNormalizer.canonical_cache_key("t", %{"foo" => 1})
    end
  end

  describe "rule 1 — map keys converted to strings" do
    test "atom keys become strings" do
      assert {"t", %{"foo" => 1, "bar" => 2}} =
               KeyNormalizer.canonical_cache_key("t", %{foo: 1, bar: 2})
    end

    test "atom and string keys converge to equal cache keys" do
      a = KeyNormalizer.canonical_cache_key("t", %{foo: 1, bar: 2})
      b = KeyNormalizer.canonical_cache_key("t", %{"foo" => 1, "bar" => 2})
      assert a == b
    end

    test "mixed-key types within a single map collapse" do
      mixed = %{:a => 1, "b" => 2}
      assert {"t", %{"a" => 1, "b" => 2}} = KeyNormalizer.canonical_cache_key("t", mixed)
    end

    test "atom values stay atoms (only keys are stringified)" do
      assert {"t", %{"flag" => :ok}} =
               KeyNormalizer.canonical_cache_key("t", %{"flag" => :ok})
    end

    test "nil/true/false values pass through unchanged" do
      assert {"t", %{"a" => nil, "b" => true, "c" => false}} =
               KeyNormalizer.canonical_cache_key("t", %{a: nil, b: true, c: false})
    end
  end

  describe "rule 2 — insertion order independence" do
    test "maps with same content but different insertion order produce equal keys" do
      m1 = Map.new() |> Map.put(:a, 1) |> Map.put(:b, 2) |> Map.put(:c, 3)
      m2 = Map.new() |> Map.put(:c, 3) |> Map.put(:a, 1) |> Map.put(:b, 2)

      assert KeyNormalizer.canonical_cache_key("t", m1) ==
               KeyNormalizer.canonical_cache_key("t", m2)
    end

    test "nested maps with different insertion order are equal" do
      inner1 = Map.new() |> Map.put("x", 1) |> Map.put("y", 2)
      inner2 = Map.new() |> Map.put("y", 2) |> Map.put("x", 1)

      a = KeyNormalizer.canonical_cache_key("t", %{"inner" => inner1})
      b = KeyNormalizer.canonical_cache_key("t", %{"inner" => inner2})
      assert a == b
    end
  end

  describe "rule 3 — integer-equal floats collapse" do
    test "1.0 collapses to 1" do
      assert {"t", %{"n" => 1}} = KeyNormalizer.canonical_cache_key("t", %{n: 1.0})
    end

    test "0.0 collapses to 0" do
      assert {"t", %{"n" => 0}} = KeyNormalizer.canonical_cache_key("t", %{n: 0.0})
    end

    test "negative integer-equal float collapses" do
      assert {"t", %{"n" => -3}} = KeyNormalizer.canonical_cache_key("t", %{n: -3.0})
    end

    test "scientific notation that is integer-equal collapses" do
      # 1.0e0 == 1.0; 1.0e3 == 1000.0
      assert {"t", %{"a" => 1, "b" => 1000}} =
               KeyNormalizer.canonical_cache_key("t", %{a: 1.0e0, b: 1.0e3})
    end

    test "non-integer float stays a float" do
      assert {"t", %{"n" => 1.5}} = KeyNormalizer.canonical_cache_key("t", %{n: 1.5})
    end

    test "integer values pass through unchanged" do
      assert {"t", %{"n" => 1}} = KeyNormalizer.canonical_cache_key("t", %{n: 1})
    end

    test "1 and 1.0 produce equal cache keys" do
      a = KeyNormalizer.canonical_cache_key("t", %{n: 1})
      b = KeyNormalizer.canonical_cache_key("t", %{n: 1.0})
      assert a == b
    end

    test "matched representation: collapsed value is an integer, not a float" do
      {"t", %{"n" => n}} = KeyNormalizer.canonical_cache_key("t", %{n: 2.0})
      assert is_integer(n)
      refute is_float(n)
    end

    test "large integer-equal float collapses to integer" do
      # 1.0e15 fits exactly in a float and is integer-equal.
      {"t", %{"n" => n}} = KeyNormalizer.canonical_cache_key("t", %{n: 1.0e15})
      assert is_integer(n)
      assert n == 1_000_000_000_000_000
    end
  end

  describe "rule 4 — lists recurse and preserve order" do
    test "list of integer-equal floats collapses element-wise" do
      assert {"t", %{"xs" => [1, 2, 3]}} =
               KeyNormalizer.canonical_cache_key("t", %{xs: [1.0, 2.0, 3.0]})
    end

    test "list order is preserved" do
      assert {"t", %{"xs" => [3, 1, 2]}} =
               KeyNormalizer.canonical_cache_key("t", %{xs: [3.0, 1.0, 2.0]})
    end

    test "list of nested maps recurses into each element" do
      input = %{xs: [%{a: 1.0}, %{a: 2.0}]}

      assert {"t", %{"xs" => [%{"a" => 1}, %{"a" => 2}]}} =
               KeyNormalizer.canonical_cache_key("t", input)
    end

    test "deeply nested lists recurse fully" do
      input = %{xs: [[[1.0, 2.0], [3.0]], [[4.0]]]}

      assert {"t", %{"xs" => [[[1, 2], [3]], [[4]]]}} =
               KeyNormalizer.canonical_cache_key("t", input)
    end

    test "empty list passes through" do
      assert {"t", %{"xs" => []}} = KeyNormalizer.canonical_cache_key("t", %{xs: []})
    end
  end

  describe "rule 5 — tuples canonicalize to lists (PTC-Lisp parity)" do
    # Tier 3.5 Fix 3c: PTC-Lisp evaluates `[1 2]` (vector) to a list, not a
    # tuple. To share cache identity across layers, tuples canonicalize to
    # lists here. This deliberately diverges from the v1 spec wording
    # ("preserve tuples"); parity with PTC-Lisp wins.
    test "tuple value canonicalizes to a list" do
      assert {"t", %{"pair" => [1, 2]}} =
               KeyNormalizer.canonical_cache_key("t", %{pair: {1.0, 2.0}})
    end

    test "tuple order is preserved when collapsed to list" do
      assert {"t", %{"trip" => [3, 1, 2]}} =
               KeyNormalizer.canonical_cache_key("t", %{trip: {3.0, 1.0, 2.0}})
    end

    test "nested tuple inside list canonicalizes to nested list" do
      assert {"t", %{"xs" => [[1, 2], [3, 4]]}} =
               KeyNormalizer.canonical_cache_key("t", %{xs: [{1.0, 2.0}, {3.0, 4.0}]})
    end

    test "empty tuple becomes an empty list" do
      assert {"t", %{"u" => []}} = KeyNormalizer.canonical_cache_key("t", %{u: {}})
    end

    test "tuple {1, 2} and list [1, 2] produce equal cache keys (PTC-Lisp parity)" do
      a = KeyNormalizer.canonical_cache_key("t", %{xs: {1, 2}})
      b = KeyNormalizer.canonical_cache_key("t", %{xs: [1, 2]})
      assert a == b
    end
  end

  describe "rule 7 — hyphen→underscore key normalization (Tier 3.5 Fix 3a)" do
    # PTC-Lisp's stringify_key/1 in eval.ex applies hyphen→underscore to
    # map keys at the tool boundary, so a native cache write keyed
    # "was-improved" must match a PTC-Lisp lookup keyed "was_improved".
    test "atom key with hyphen normalizes to underscore" do
      assert {"t", %{"was_improved" => true}} =
               KeyNormalizer.canonical_cache_key("t", %{:"was-improved" => true})
    end

    test "string key with hyphen normalizes to underscore" do
      assert {"t", %{"was_improved" => true}} =
               KeyNormalizer.canonical_cache_key("t", %{"was-improved" => true})
    end

    test "hyphen and underscore variants produce equal cache keys" do
      a = KeyNormalizer.canonical_cache_key("t", %{"was-improved" => true})
      b = KeyNormalizer.canonical_cache_key("t", %{"was_improved" => true})
      assert a == b
    end

    test "nested map keys with hyphens also normalize" do
      input = %{"outer-key" => %{"inner-key" => 1}}

      assert {"t", %{"outer_key" => %{"inner_key" => 1}}} =
               KeyNormalizer.canonical_cache_key("t", input)
    end
  end

  describe "rule 8 — non-map args sentinel fallback (Tier 3.5 Fix 3b)" do
    # Non-map args get wrapped in a `{:non_map, args}` sentinel rather than
    # crashing the cache layer. Chaos-resilient: a misbehaving tool plumbing
    # path producing a list/scalar arg still produces a deterministic key.
    test "list args produce {:non_map, list} sentinel" do
      assert {"t", {:non_map, [1, 2, 3]}} =
               KeyNormalizer.canonical_cache_key("t", [1, 2, 3])
    end

    test "scalar args produce {:non_map, scalar} sentinel" do
      assert {"t", {:non_map, "foo"}} =
               KeyNormalizer.canonical_cache_key("t", "foo")
    end

    test "nil args produce {:non_map, nil} sentinel" do
      assert {"t", {:non_map, nil}} = KeyNormalizer.canonical_cache_key("t", nil)
    end

    test "two equal non-map args produce equal cache keys" do
      a = KeyNormalizer.canonical_cache_key("t", [1, 2])
      b = KeyNormalizer.canonical_cache_key("t", [1, 2])
      assert a == b
    end

    test "different non-map args produce different cache keys" do
      a = KeyNormalizer.canonical_cache_key("t", [1, 2])
      b = KeyNormalizer.canonical_cache_key("t", [1, 3])
      refute a == b
    end
  end

  describe "rule 6 — strings, booleans, nil unchanged" do
    test "binary values pass through" do
      assert {"t", %{"s" => "hello"}} =
               KeyNormalizer.canonical_cache_key("t", %{s: "hello"})
    end

    test "string with special chars passes through unchanged" do
      assert {"t", %{"s" => ~s({"x":1})}} =
               KeyNormalizer.canonical_cache_key("t", %{s: ~s({"x":1})})
    end
  end

  describe "nested maps" do
    test "atom-keyed inner maps with string-keyed outer collapse to all-string" do
      input = %{"outer" => %{inner: %{leaf: 1}}}

      assert {"t", %{"outer" => %{"inner" => %{"leaf" => 1}}}} =
               KeyNormalizer.canonical_cache_key("t", input)
    end

    test "mixed atom/string keys at every level converge" do
      a = KeyNormalizer.canonical_cache_key("t", %{outer: %{"inner" => %{leaf: 1.0}}})
      b = KeyNormalizer.canonical_cache_key("t", %{"outer" => %{inner: %{"leaf" => 1}}})
      assert a == b
    end

    test "deeply nested maps recurse fully" do
      input = %{a: %{b: %{c: %{d: 1.0}}}}

      assert {"t", %{"a" => %{"b" => %{"c" => %{"d" => 1}}}}} =
               KeyNormalizer.canonical_cache_key("t", input)
    end

    test "empty nested map stays empty" do
      assert {"t", %{"a" => %{}}} = KeyNormalizer.canonical_cache_key("t", %{a: %{}})
    end
  end

  describe "input validation" do
    test "raises on non-binary tool name" do
      assert_raise FunctionClauseError, fn ->
        KeyNormalizer.canonical_cache_key(:not_a_string, %{})
      end
    end

    # Tier 3.5 Fix 3b: non-map args no longer raise; they wrap in a
    # `{:non_map, args}` sentinel. See rule 8 tests above.
  end

  describe "cache-identity guarantees" do
    test "two semantically identical calls from different layers produce equal keys" do
      # Simulating a native app-tool call: atom-keyed Elixir map.
      native = %{query: "error code 42", limit: 10, since: 1.0}
      # Simulating a PTC-Lisp call site (already string-keyed by stringify_keys/1
      # at eval.ex), with map insertion order differing from native.
      ptc =
        Map.new()
        |> Map.put("limit", 10)
        |> Map.put("since", 1.0)
        |> Map.put("query", "error code 42")

      assert KeyNormalizer.canonical_cache_key("search_logs", native) ==
               KeyNormalizer.canonical_cache_key("search_logs", ptc)
    end

    test "different tool names produce different keys for identical args" do
      a = KeyNormalizer.canonical_cache_key("a", %{x: 1})
      b = KeyNormalizer.canonical_cache_key("b", %{x: 1})
      refute a == b
    end

    test "different args produce different keys for identical tool names" do
      a = KeyNormalizer.canonical_cache_key("t", %{x: 1})
      b = KeyNormalizer.canonical_cache_key("t", %{x: 2})
      refute a == b
    end

    test "1 vs 1.5 do NOT collapse (only integer-equal floats collapse)" do
      a = KeyNormalizer.canonical_cache_key("t", %{n: 1})
      b = KeyNormalizer.canonical_cache_key("t", %{n: 1.5})
      refute a == b
    end
  end
end
