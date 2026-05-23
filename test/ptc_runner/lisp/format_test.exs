defmodule PtcRunner.Lisp.FormatTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Format

  doctest PtcRunner.Lisp.Format

  describe "to_string/2 with closures" do
    test "formats closure with single parameter" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      assert Format.to_string(closure) == "#fn[x]"
    end

    test "formats closure with multiple parameters" do
      closure = {:closure, [{:var, :x}, {:var, :y}, {:var, :z}], nil, %{}, [], %{}}
      assert Format.to_string(closure) == "#fn[x y z]"
    end

    test "formats zero-param closure" do
      closure = {:closure, [], nil, %{}, [], %{}}
      assert Format.to_string(closure) == "#fn[]"
    end

    test "formats closure with destructuring pattern as underscore" do
      closure = {:closure, [{:destructure, {:keys, [:a, :b], []}}], nil, %{}, [], %{}}
      assert Format.to_string(closure) == "#fn[_]"
    end

    test "formats closure with metadata" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      assert Format.to_string(closure) == "#fn[x]"
    end
  end

  describe "to_string/2 with builtins" do
    test "formats :normal builtin" do
      assert Format.to_string({:normal, &Enum.map/2}) == "#<builtin>"
    end

    test "formats :variadic builtin" do
      assert Format.to_string({:variadic, &Kernel.+/2, 0}) == "#<builtin>"
    end

    test "formats :variadic_nonempty builtin" do
      assert Format.to_string({:variadic_nonempty, :/, &Kernel.//2}) == "#<builtin>"
    end

    test "formats :multi_arity builtin" do
      assert Format.to_string({:multi_arity, :subs, {&String.slice/2, &String.slice/3}}) ==
               "#<builtin>"
    end

    test "formats wrapped Env builtins" do
      normal = Builtin.wrap(:count, {:normal, &Enum.count/1})
      collect = Builtin.wrap(:merge, {:collect, fn args -> args end})

      assert Format.to_string(normal) == "#<builtin>"
      assert Format.to_string(collect) == "#fn[...]"
    end
  end

  describe "to_string/2 with regular values" do
    test "formats integers" do
      assert Format.to_string(42) == "42"
    end

    test "formats strings" do
      assert Format.to_string("hello") == ~s("hello")
    end

    test "formats maps" do
      assert Format.to_string(%{a: 1}) == "%{a: 1}"
    end

    test "formats lists" do
      assert Format.to_string([1, 2, 3]) == "[1, 2, 3]"
    end

    test "formats nil" do
      assert Format.to_string(nil) == "nil"
    end

    test "formats atoms" do
      assert Format.to_string(:foo) == ":foo"
    end
  end

  describe "to_string/2 with nested values" do
    test "formats closure nested in map" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      assert Format.to_string(%{f: closure}) == "%{f: #fn[x]}"
    end

    test "formats closure nested in list" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      assert Format.to_string([1, closure, 3]) == "[1, #fn[x], 3]"
    end

    test "formats builtin nested in map" do
      assert Format.to_string(%{add: {:variadic, &Kernel.+/2, 0}}) == "%{add: #<builtin>}"
    end

    test "formats deeply nested closures" do
      closure = {:closure, [{:var, :n}], nil, %{}, [], %{}}
      result = Format.to_string(%{outer: %{inner: closure}})
      assert result =~ "#fn[n]"
    end
  end

  describe "to_string/2 with vars" do
    test "formats simple var" do
      assert Format.to_string({:var, :x}) == "#'x"
    end

    test "formats var with question mark" do
      assert Format.to_string({:var, :suspicious?}) == "#'suspicious?"
    end

    test "formats var nested in map" do
      assert Format.to_string(%{result: {:var, :foo}}) == "%{result: #'foo}"
    end

    test "formats var nested in list" do
      assert Format.to_string([{:var, :a}, {:var, :b}]) == "[#'a, #'b]"
    end
  end

  describe "to_clojure/2 with vars" do
    test "formats simple var" do
      assert Format.to_clojure({:var, :x}) == {"#'x", false}
    end

    test "formats var with question mark" do
      assert Format.to_clojure({:var, :suspicious?}) == {"#'suspicious?", false}
    end

    test "formats var nested in list" do
      assert Format.to_clojure([{:var, :x}, {:var, :y}]) == {"[#'x #'y]", false}
    end

    test "formats var nested in map" do
      assert Format.to_clojure(%{result: {:var, :foo}}) == {"{:result #'foo}", false}
    end
  end

  describe "symbol references" do
    test "formats bare symbolic refs as quoted symbols" do
      assert Format.to_string({:symbol_ref, "github/search_repos"}) == "'github/search_repos"

      assert Format.to_clojure({:symbol_ref, "github/search_repos"}) ==
               {"'github/search_repos", false}
    end

    test "formats symbolic refs inside lists and maps" do
      ref = {:symbol_ref, "github/search_repos"}

      assert Format.to_clojure([ref]) == {"['github/search_repos]", false}
      assert Format.to_clojure(%{ref: ref}) == {"{:ref 'github/search_repos}", false}
    end
  end

  describe "to_clojure/2 with regex values" do
    test "formats compiled regexes by source pattern" do
      regex = PtcRunner.Lisp.Runtime.Regex.re_pattern("\\d+")

      assert Format.to_clojure(regex) == {~S(#"\d+"), false}
      assert Format.to_string(regex) == ~S(#"\d+")
    end
  end

  describe "to_string/2 with structs" do
    test "handles MapSet without crashing" do
      # Regression test: MapSet passes is_map/1 but enumerates as elements, not tuples
      result = Format.to_string(MapSet.new(["meals", "travel"]))
      assert result =~ "MapSet"
    end

    test "handles MapSet nested in map" do
      result = Format.to_string(%{categories: MapSet.new(["a", "b"])})
      assert result =~ "categories"
      assert result =~ "MapSet"
    end
  end

  describe "to_clojure/2 with structs" do
    test "handles MapSet as Clojure set syntax" do
      {result, _truncated} = Format.to_clojure(MapSet.new(["meals"]))
      assert result == ~S|#{"meals"}|
    end
  end

  describe "to_clojure/2 formats floats cleanly" do
    test "avoids IEEE 754 noise" do
      # 1.1 + 2.2 produces 3.3000000000000003 in Elixir
      {result, false} = Format.to_clojure(1.1 + 2.2)
      assert result == "3.3"
    end

    test "formats simple floats" do
      assert {"3.14", false} = Format.to_clojure(3.14)
      assert {"0.5", false} = Format.to_clojure(0.5)
    end

    test "formats large numbers" do
      {result, false} = Format.to_clojure(1.0e20)
      # Compact format uses decimal form, not scientific notation
      assert result == "100000000000000000000.0"
    end

    test "formats small numbers" do
      {result, false} = Format.to_clojure(1.0e-10)
      # Compact format uses decimal form, not scientific notation
      assert result == "0.0000000001"
    end
  end

  describe "to_clojure/2 with printable_limit on maps" do
    test "auto-reduces entry limit when budget is too small for all keys" do
      map = %{
        key1: String.duplicate("a", 100),
        key2: String.duplicate("b", 100),
        key3: String.duplicate("c", 100),
        key4: String.duplicate("d", 100),
        key5: String.duplicate("e", 100)
      }

      # Budget of 90 chars can fit ~3 entries (30 chars each)
      {result, truncated} = Format.to_clojure(map, printable_limit: 90)

      # Should show truncation indicator (... at end)
      assert truncated
      assert result =~ "...}"

      # Should show some keys but not all
      refute result =~ ":key4"
      refute result =~ ":key5"
    end

    test "shows all keys when budget is sufficient" do
      map = %{a: "short", b: "values", c: "here"}

      {result, _truncated} = Format.to_clojure(map, printable_limit: 200)

      assert result =~ ":a"
      assert result =~ ":b"
      assert result =~ ":c"
      refute result =~ "..."
    end
  end

  describe "to_string/2 with options" do
    test "respects limit option" do
      assert Format.to_string([1, 2, 3, 4, 5], limit: 2) == "[1, 2, ...]"
    end

    test "respects pretty option" do
      # Pretty printing affects formatting but result should still be valid
      result = Format.to_string(%{a: 1, b: 2}, pretty: true)
      assert result =~ "a:"
      assert result =~ "b:"
    end

    test "options are ignored for closures" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      assert Format.to_string(closure, pretty: true, limit: 5) == "#fn[x]"
    end

    test "options are ignored for builtins" do
      assert Format.to_string({:normal, &Enum.map/2}, pretty: true) == "#<builtin>"
    end
  end

  describe "to_clojure/2 underscore-prefixed keys" do
    test "renders underscore-prefixed keys in top-level maps" do
      {result, _} = Format.to_clojure(%{id: 1, _secret: "hidden"})

      assert result =~ ":id 1"
      assert result =~ ":_secret \"hidden\""
    end

    test "renders underscore-prefixed keys in nested maps within lists" do
      data = [%{id: 1, _secret: "hidden"}, %{id: 2, _token: "also-hidden"}]
      {result, _} = Format.to_clojure(data)

      assert result =~ ":id 1"
      assert result =~ ":id 2"
      assert result =~ ":_secret \"hidden\""
      assert result =~ ":_token \"also-hidden\""
    end

    test "renders underscore-prefixed keys in deeply nested structures" do
      data = %{users: [%{name: "Alice", _password: "secret123"}]}
      {result, _} = Format.to_clojure(data)

      assert result =~ "Alice"
      assert result =~ ":_password \"secret123\""
    end

    test "handles string keys with underscore prefix" do
      data = %{"id" => 1, "_secret" => "hidden"}
      {result, _} = Format.to_clojure(data)

      assert result =~ "\"id\" 1"
      assert result =~ "\"_secret\" \"hidden\""
    end
  end

  describe "to_clojure/2 compact (shown/total) hints" do
    test "lists use compact hint format" do
      {result, true} = Format.to_clojure([1, 2, 3, 4, 5], limit: 2)
      assert result == "[1 2 ...] (2/5)"
    end

    test "sets use compact hint format" do
      set = MapSet.new([1, 2, 3, 4, 5])
      {result, true} = Format.to_clojure(set, limit: 2)
      assert result =~ "...} (2/5)"
    end

    test "maps use compact hint format" do
      map = %{a: 1, b: 2, c: 3, d: 4, e: 5}
      {result, true} = Format.to_clojure(map, limit: 2)
      assert result =~ "...} (2/5)"
    end

    test "map total includes underscore-prefixed fields" do
      map = %{a: 1, b: 2, _secret: "hidden", _token: "also-hidden"}
      {result, true} = Format.to_clojure(map, limit: 1)
      assert result =~ "(1/4)"
    end
  end

  describe "to_clojure/2 string truncation hints" do
    test "shows char-based hint when truncated" do
      {result, true} = Format.to_clojure("hello world", printable_limit: 5)
      assert result =~ "(5/11 chars)"
    end

    test "no hint when string fits within limit" do
      {result, false} = Format.to_clojure("short", printable_limit: 100)
      assert result == ~s("short")
      refute result =~ "chars"
    end

    test "uses String.length not byte_size for guard" do
      # Multi-byte chars: "héllo" is 5 chars but 6 bytes
      {result, false} = Format.to_clojure("héllo", printable_limit: 5)
      assert result == ~s("héllo")
      refute result =~ "chars"
    end

    test "truncates multi-byte string correctly by chars" do
      # "aaaa héllo" is 10 chars; limit to 5 should truncate
      {result, true} = Format.to_clojure("aaaa héllo", printable_limit: 5)
      assert result =~ "(5/10 chars)"
    end
  end

  # Regression: data inventory samples used to render DateTime/NaiveDateTime/Time
  # with `inspect/1`, leaking sigil syntax (`~U[...]`, `~N[...]`, `~T[...]`) into
  # the system prompt. The LLM then shaped its programs around the wrong format.
  describe "to_clojure/2 with temporal structs" do
    test "DateTime renders as quoted ISO 8601" do
      assert {"\"2026-05-03T09:14:00Z\"", false} =
               Format.to_clojure(~U[2026-05-03 09:14:00Z])
    end

    test "NaiveDateTime renders as quoted ISO 8601 (no offset)" do
      assert {"\"2026-05-03T09:14:00\"", false} =
               Format.to_clojure(~N[2026-05-03 09:14:00])
    end

    test "Date renders as quoted ISO 8601" do
      assert {"\"2026-05-03\"", false} = Format.to_clojure(~D[2026-05-03])
    end

    test "Time renders as quoted ISO 8601" do
      assert {"\"09:14:00\"", false} = Format.to_clojure(~T[09:14:00])
    end

    test "temporal struct nested in a map renders cleanly" do
      {result, _} = Format.to_clojure(%{at: ~U[2026-05-03 09:14:00Z]})
      assert result =~ "\"2026-05-03T09:14:00Z\""
      refute result =~ "~U["
    end
  end
end
