defmodule PtcRunner.Lisp.Runtime.JsonTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime.Json

  doctest PtcRunner.Lisp.Runtime.Json

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

  describe "generate_string/1 — failure modes (DIV-24: nil, never raise)" do
    test "returns nil for atom values outside true/false/nil (e.g. PTC-Lisp keywords)" do
      assert Json.generate_string(:fs) == nil
      assert Json.generate_string(%{"server" => :fs}) == nil
    end

    test "returns nil for atom-keyed maps (including booleans/nil as keys)" do
      assert Json.generate_string(%{:server => "fs"}) == nil
      assert Json.generate_string(%{true => 1}) == nil
      assert Json.generate_string(%{false => 1}) == nil
      assert Json.generate_string(%{nil => 1}) == nil
    end

    test "returns nil for float-keyed maps" do
      assert Json.generate_string(%{1.5 => "a"}) == nil
    end

    test "returns nil for tuple values" do
      assert Json.generate_string({:ok, 1}) == nil
      assert Json.generate_string([{:a, 1}]) == nil
    end

    test "returns nil for PID values" do
      pid = self()
      assert Json.generate_string(pid) == nil
      assert Json.generate_string(%{"pid" => pid}) == nil
    end

    test "returns nil for function values" do
      f = fn x -> x end
      assert Json.generate_string(f) == nil
      assert Json.generate_string([f]) == nil
    end

    test "returns nil for special-float carve-out (§4.3)" do
      # Special numeric literals resolve to bounded signal atoms.
      assert Json.generate_string(:infinity) == nil
      assert Json.generate_string(:negative_infinity) == nil
      assert Json.generate_string(:nan) == nil
    end

    test "rejects non-encodable atom even when nested deep" do
      assert Json.generate_string([%{"k" => [1, 2, [3, :bad]]}]) == nil
    end

    test "does not raise" do
      # Reference values are not encodable — must not blow the sandbox.
      ref = make_ref()
      assert Json.generate_string(ref) == nil
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
  end
end
