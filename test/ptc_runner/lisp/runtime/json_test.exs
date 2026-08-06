defmodule PtcRunner.Lisp.Runtime.JsonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Json

  doctest PtcRunner.Lisp.Runtime.Json

  # `generate_string/1` either returns a JSON string or raises a named
  # `type_error`; every refusal assertion goes through this.
  defp refusal(value) do
    assert_raise(RuntimeError, fn -> Json.generate_string(value) end).message
  end

  defp eval_error(src) do
    case Lisp.run(src) do
      {:error, %{fail: %{message: msg}}} -> msg
      {:ok, %{return: value}} -> flunk("expected error, got #{inspect(value)}\n#{src}")
    end
  end

  describe "parse_string/1 — happy paths" do
    test "parses a JSON object into a string-keyed map" do
      assert Json.parse_string(~S|{"a": 1, "b": [2, 3]}|) == %{"a" => 1, "b" => [2, 3]}
    end

    test "parses a JSON array into a list" do
      assert Json.parse_string("[1, 2, 3]") == [1, 2, 3]
    end

    test "parses scalar JSON values" do
      assert Json.parse_string("1") == 1
      assert Json.parse_string("1.5") == 1.5
      assert Json.parse_string(~S|"hello"|) == "hello"
      assert Json.parse_string("true") == true
      assert Json.parse_string("false") == false
    end

    test "parses JSON null to nil (collides with parse-failure signal — see OQ-1)" do
      assert Json.parse_string("null") == nil
    end

    test "parses JSON integers larger than int64 cleanly (bigint support)" do
      bigint_str = "12345678901234567890123456789"
      assert Json.parse_string(bigint_str) == 12_345_678_901_234_567_890_123_456_789
    end

    test "parses nested structures with string keys only" do
      assert Json.parse_string(~S|{"x": {"y": [1, {"z": 2}]}}|) ==
               %{"x" => %{"y" => [1, %{"z" => 2}]}}
    end
  end

  describe "parse_string/1 — failure modes (DIV-23: nil, never raise)" do
    test "returns nil on invalid JSON" do
      assert Json.parse_string("not json") == nil
      assert Json.parse_string("{") == nil
      assert Json.parse_string("[1,") == nil
    end

    test "returns nil on nil input" do
      assert Json.parse_string(nil) == nil
    end

    test "returns nil on non-binary input" do
      assert Json.parse_string(123) == nil
      assert Json.parse_string(:foo) == nil
      assert Json.parse_string([1, 2]) == nil
      assert Json.parse_string(%{}) == nil
    end

    test "does not raise" do
      # Pathological inputs that might trigger Jason raises
      Enum.each([<<0>>, String.duplicate("[", 100), ""], fn s ->
        assert Json.parse_string(s) == nil or is_list(Json.parse_string(s)) or
                 is_map(Json.parse_string(s)) or is_binary(Json.parse_string(s)) or
                 is_number(Json.parse_string(s)) or is_boolean(Json.parse_string(s))
      end)
    end
  end

  describe "parse_lines/1" do
    test "parses multiple JSON objects" do
      assert Json.parse_lines(~S|{"a":1}| <> "\n" <> ~S|{"b":2}|) == [
               %{"a" => 1},
               %{"b" => 2}
             ]
    end

    test "skips blank and whitespace-only lines" do
      assert Json.parse_lines("\n  \n" <> ~S|{"ok":true}| <> "\n\t\n") == [
               %{"ok" => true}
             ]
    end

    test "accepts arrays and scalars per line" do
      assert Json.parse_lines("[1,2]\n42\ntrue\n\"x\"") == [[1, 2], 42, true, "x"]
    end

    test "uses parse_string failure behavior for bad lines" do
      assert Json.parse_lines(~S|{"ok":true}| <> "\nnot json\n[1]") == [
               %{"ok" => true},
               nil,
               [1]
             ]
    end

    test "malformed lines and literal null lines both produce nil" do
      assert Json.parse_lines("null\nnot json") == [nil, nil]
    end

    test "does not split Unicode line separators inside valid JSON strings" do
      json = ~S|{"x":"a| <> "\u2028" <> ~S|b"}|

      assert Json.parse_lines(json) == [%{"x" => "a\u2028b"}]
    end

    test "returns nil on non-binary input" do
      assert Json.parse_lines(nil) == nil
      assert Json.parse_lines(123) == nil
      assert Json.parse_lines([~S|{"a":1}|]) == nil
    end
  end

  describe "generate_string/1 — happy paths" do
    test "encodes a string-keyed map" do
      assert Json.generate_string(%{"a" => 1, "b" => [2, 3]}) in [
               ~S|{"a":1,"b":[2,3]}|,
               ~S|{"b":[2,3],"a":1}|
             ]
    end

    test "encodes a list" do
      assert Json.generate_string([1, 2, 3]) == "[1,2,3]"
    end

    test "encodes scalar values" do
      assert Json.generate_string(nil) == "null"
      assert Json.generate_string(true) == "true"
      assert Json.generate_string(false) == "false"
      assert Json.generate_string(42) == "42"
      assert Json.generate_string("hello") == ~S|"hello"|
    end

    test "encodes integer keys (stringifies them — Jason default; see §4.3 carve-out)" do
      assert Json.generate_string(%{1 => "a"}) == ~S|{"1":"a"}|
    end
  end

  describe "generate_string/1 — keyword keys encode as their name (#1165)" do
    test "a keyword key becomes a JSON string key" do
      assert Json.generate_string(%{:server => "fs"}) == ~S|{"server":"fs"}|
    end

    test "keyword names are used verbatim — no tool-boundary hyphen normalization" do
      # KeyNormalizer.normalize_key/1 would emit "max_turns"; renaming a key
      # behind the caller's back is the trap #1165 is about, not the fix.
      assert Json.generate_string(%{:"max-turns" => 3}) == ~S|{"max-turns":3}|
    end

    test "a novel struct-backed keyword key encodes the same way" do
      assert Json.generate_string(%{LispKeyword.new("novel-key") => 1}) == ~S|{"novel-key":1}|
    end

    test "an invalid keyword struct is refused rather than encoded" do
      msg = refusal(%{%LispKeyword{name: "not a keyword"} => 1})
      assert msg =~ "as a JSON object key"
    end

    test "keys that collide after encoding are refused, not silently merged" do
      keyword_vs_string = refusal(%{:a => 1, "a" => 2})
      assert keyword_vs_string =~ ~s|both encode to the JSON key "a"|

      # Pre-existing hazard: Jason stringifies integer keys, so {1 "a"} and
      # {"1" "b"} would have produced a duplicate JSON key.
      integer_vs_string = refusal(%{1 => "a", "1" => "b"})
      assert integer_vs_string =~ ~s|both encode to the JSON key "1"|
    end
  end

  describe "generate_string/1 — refusals raise a named type_error (never nil)" do
    test "a keyword value names the position and how to convert it" do
      # The module raises the message; `Eval.Apply` is what classifies it as a
      # `type_error` (asserted through the evaluator below).
      msg = refusal(%{"server" => :fs})
      assert msg =~ "json/generate-string"
      assert msg =~ "cannot encode a keyword as a JSON value"
      assert msg =~ ~s|at ["server"]|
      assert msg =~ "(name x)"
    end

    test "a top-level keyword value says so instead of naming a path" do
      assert refusal(:fs) =~ "at the top level"
    end

    test "a novel struct-backed keyword value is refused like an atom one" do
      assert refusal(%{"server" => LispKeyword.new("fs")}) =~
               "cannot encode a keyword as a JSON value"
    end

    test "the path names every step down to the offending value" do
      msg = refusal(%{"config" => [%{:port => :auto}]})
      assert msg =~ ~s|at ["config" 0 :port]|
    end

    test "booleans and nil are refused in key position" do
      for key <- [true, false, nil] do
        assert refusal(%{key => 1}) =~ "as a JSON object key"
      end
    end

    test "a float key is refused and says keys must be strings" do
      msg = refusal(%{1.5 => "a"})
      assert msg =~ "cannot encode a number as a JSON object key"
      assert msg =~ "must be strings"
    end

    test "tuples are refused" do
      assert refusal({:ok, 1}) =~ "cannot encode a tuple as a JSON value"
      assert refusal([{:a, 1}]) =~ "at [0]"
    end

    test "a set is refused and points at (vec s)" do
      msg = refusal(MapSet.new([1, 2]))
      assert msg =~ "cannot encode a set as a JSON value"
      assert msg =~ "(vec x)"
    end

    test "a PTC-Lisp closure is named a function, not the tuple it is built from" do
      msg = eval_error(~S<(json/generate-string {"subject" (fn [] 1)})>)

      assert msg =~ "cannot encode a function as a JSON value"
      assert msg =~ ~s|at ["subject"]|
    end

    test "PIDs, references and functions are refused" do
      assert refusal(self()) =~ "cannot encode"
      assert refusal(make_ref()) =~ "cannot encode"
      assert refusal(fn x -> x end) =~ "cannot encode"
    end

    test "special float atoms say JSON has no infinity or NaN" do
      for special <- [:infinity, :negative_infinity, :nan] do
        msg = refusal(special)
        assert msg =~ "infinity"
        assert msg =~ "NaN"
      end
    end

    test "a special float in key position is refused, not stringified" do
      # ##Inf is a number carried as a bounded atom; encoding it as the key
      # "infinity" would turn a number into a word behind the caller's back.
      for special <- [:infinity, :negative_infinity, :nan] do
        msg = refusal(%{special => 1})
        assert msg =~ "as a JSON object key"
        assert msg =~ "JSON has no infinity or NaN literal"
      end

      assert eval_error("(json/generate-string {##Inf 1})") =~
               "cannot encode ##Inf as a JSON object key"
    end

    test "a refusal nested deep still reports its path" do
      assert refusal([%{"k" => [1, 2, [3, :bad]]}]) =~ ~s|at [0 "k" 2 1]|
    end

    test "a deep path is truncated rather than rendered in full" do
      deep = Enum.reduce(1..40, :bad, fn i, acc -> %{"k#{i}" => acc} end)
      msg = refusal(deep)
      assert msg =~ "…"
      assert String.length(msg) < 500
    end

    test "an oversized key is truncated in the path" do
      long_key = String.duplicate("x", 500)
      msg = refusal(%{long_key => :bad})
      refute msg =~ long_key
      assert msg =~ "…"
    end
  end

  describe "round-trip property (string-keyed maps only — §4.3)" do
    test "scalars round-trip" do
      for v <- [nil, true, false, 0, -1, 1.5, "", "hello", "with \"quotes\""] do
        assert v == Json.parse_string(Json.generate_string(v))
      end
    end

    test "string-keyed maps round-trip" do
      v = %{"a" => 1, "b" => [2, 3], "c" => %{"d" => "e"}}
      assert v == Json.parse_string(Json.generate_string(v))
    end

    test "lists round-trip" do
      v = [1, "two", [3, %{"four" => 5}], nil]
      assert v == Json.parse_string(Json.generate_string(v))
    end

    test "integer-keyed maps DO NOT round-trip — keys come back as strings" do
      # Carve-out per §4.3.
      assert Json.parse_string(Json.generate_string(%{1 => "a"})) == %{"1" => "a"}
    end

    test "keyword-keyed maps DO NOT round-trip — keys come back as strings" do
      assert Json.parse_string(Json.generate_string(%{:a => 1})) == %{"a" => 1}
    end
  end

  # The reported failure: `describe` emits keyword keys, so encoding its
  # output produced `nil`, and `str` turned that into an empty string — a
  # prompt section that silently went out blank.
  describe "through the evaluator (#1165)" do
    test "describe output encodes instead of vanishing" do
      {:ok, %{return: encoded}} =
        Lisp.run(~S<(json/generate-string (describe [{"a" 1} {"a" 2}]))>)

      assert is_binary(encoded)
      assert %{"type" => "vector", "count" => 2} = Json.parse_string(encoded)
    end

    test "a keyword value fails loudly with a named type_error" do
      msg = eval_error(~S<(json/generate-string {"server" :fs})>)

      assert msg =~ "type_error"
      assert msg =~ "cannot encode a keyword as a JSON value"
      assert msg =~ ~s|at ["server"]|
    end

    test "str no longer silently swallows a failed encode" do
      # (str "shape: " (json/generate-string ...)) was the shape of the bug:
      # a refusal has to reach the caller, not become "".
      msg = eval_error(~S<(str "shape: " (json/generate-string {:a :b}))>)

      assert msg =~ "type_error"
    end
  end
end
