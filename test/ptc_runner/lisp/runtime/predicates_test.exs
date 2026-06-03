defmodule PtcRunner.Lisp.Runtime.PredicatesTest do
  @moduledoc """
  Coverage for `PtcRunner.Lisp.Runtime.Predicates`.

  Where a predicate is reachable as a PTC-Lisp builtin we drive it through the
  real evaluator (`PtcRunner.Lisp.run/1`) so the production dispatch path is
  exercised. Clauses that have no surface syntax (e.g. `fnil`'s `{:variadic,…}`
  and `%Builtin{}` forms, `type_of`'s tuple variants, special-atom branches)
  are covered with direct module calls.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.Predicates

  doctest PtcRunner.Lisp.Runtime.Predicates

  # ------------------------------------------------------------------
  # Eval helpers: drive the real PTC-Lisp pipeline.
  # ------------------------------------------------------------------

  # Returns the program's value, raising if the program errored.
  defp eval!(src) do
    case Lisp.run(src) do
      {:ok, %{return: value}} -> value
      {:error, %{fail: %{message: msg}}} -> flunk("PTC-Lisp program errored: #{msg}\n#{src}")
    end
  end

  # Returns the failure message for a program expected to error at runtime.
  defp eval_error(src) do
    case Lisp.run(src) do
      {:error, %{fail: %{message: msg}}} -> msg
      {:ok, %{return: value}} -> flunk("expected error, got #{inspect(value)}\n#{src}")
    end
  end

  # ==================================================================
  # Logic: not / boolean / identity
  # ==================================================================

  describe "logic primitives (via evaluator)" do
    test "not flips truthiness; only nil and false are falsy" do
      assert eval!("(not nil)") == true
      assert eval!("(not false)") == true
      assert eval!("(not 0)") == false
      assert eval!("(not \"\")") == false
      assert eval!("(not true)") == false
    end

    test "boolean coerces nil/false to false, everything else to true" do
      assert eval!("(boolean nil)") == false
      assert eval!("(boolean false)") == false
      assert eval!("(boolean 0)") == true
      assert eval!("(boolean \"x\")") == true
    end
  end

  describe "logic primitives (direct, fallthrough clauses)" do
    test "not_/1 truthy fallthrough" do
      assert Predicates.not_(:something) == false
      assert Predicates.not_(0) == false
    end

    test "boolean/1 fallthrough clause for arbitrary terms" do
      assert Predicates.boolean([]) == true
      assert Predicates.boolean(%{}) == true
    end

    test "identity/1 returns its argument unchanged" do
      ref = make_ref()
      assert Predicates.identity(ref) == ref
      assert Predicates.identity(nil) == nil
      assert Predicates.identity([1, 2, 3]) == [1, 2, 3]
    end
  end

  # ==================================================================
  # Type predicates (via evaluator where surface-reachable)
  # ==================================================================

  describe "nil?/some?/boolean? (via evaluator)" do
    test "nil? and some? are inverses on nil and non-nil" do
      assert eval!("(nil? nil)") == true
      assert eval!("(nil? 0)") == false
      assert eval!("(some? nil)") == false
      assert eval!("(some? 0)") == true
    end

    test "boolean? recognizes only true/false" do
      assert eval!("(boolean? true)") == true
      assert eval!("(boolean? false)") == true
      assert eval!("(boolean? nil)") == false
      assert eval!("(boolean? 1)") == false
    end
  end

  describe "number?/int?/integer?/float?/double? (via evaluator)" do
    test "number? is true for integers, floats, and IEEE special values" do
      assert eval!("(number? 5)") == true
      assert eval!("(number? 1.5)") == true
      # special values produced at runtime are still numbers
      assert eval!("(number? (/ 1.0 0.0))") == true
      assert eval!("(number? (/ 0.0 0.0))") == true
      assert eval!("(number? \"5\")") == false
    end

    test "int?/integer? true only for integers" do
      assert eval!("(int? 5)") == true
      assert eval!("(integer? 5)") == true
      assert eval!("(int? 5.0)") == false
      assert eval!("(integer? 5.0)") == false
    end

    test "float?/double? true only for floats" do
      assert eval!("(float? 1.5)") == true
      assert eval!("(double? 1.5)") == true
      assert eval!("(float? 1)") == false
      assert eval!("(double? 1)") == false
    end
  end

  describe "number? with special atoms (direct)" do
    test "number? true for :infinity and :nan special atoms" do
      assert Predicates.number?(:infinity) == true
      assert Predicates.number?(:negative_infinity) == true
      assert Predicates.number?(:nan) == true
    end

    test "number? false for ordinary keyword atoms and structs" do
      assert Predicates.number?(:foo) == false
      assert Predicates.number?("5") == false
    end
  end

  describe "int?/float? helper twins agree (direct)" do
    test "int? and integer? agree; float? and double? agree" do
      assert Predicates.int?(7) == Predicates.integer?(7)
      assert Predicates.int?(7.0) == Predicates.integer?(7.0)
      assert Predicates.float?(7.0) == Predicates.double?(7.0)
      assert Predicates.float?(7) == Predicates.double?(7)
    end
  end

  describe "false?/true? (direct)" do
    test "false? strictly matches the boolean false" do
      assert Predicates.false?(false) == true
      assert Predicates.false?(nil) == false
      assert Predicates.false?(0) == false
    end

    test "true? strictly matches the boolean true" do
      assert Predicates.true?(true) == true
      assert Predicates.true?(1) == false
      assert Predicates.true?("true") == false
    end
  end

  describe "string?/keyword?/char? (via evaluator)" do
    test "string? true for binaries only" do
      assert eval!("(string? \"x\")") == true
      assert eval!("(string? 5)") == false
      assert eval!("(string? :x)") == false
    end

    test "keyword? true for keywords" do
      assert eval!("(keyword? :foo)") == true
      assert eval!("(keyword? \"foo\")") == false
      assert eval!("(keyword? 5)") == false
    end

    test "char? true for single-grapheme strings only" do
      assert eval!("(char? \"a\")") == true
      assert eval!("(char? \"ab\")") == false
      assert eval!("(char? \"\")") == false
    end
  end

  describe "keyword?/char? boundary cases (direct)" do
    test "keyword? excludes special-value atoms" do
      assert Predicates.keyword?(:infinity) == false
      assert Predicates.keyword?(:nan) == false
      assert Predicates.keyword?(:foo) == true
      assert Predicates.keyword?(LispKeyword.new("zoozoo")) == true
    end

    test "char? respects utf8 grapheme boundaries (one combined grapheme is a char)" do
      assert Predicates.char?("é") == true
      # "a" + U+0301 combining acute accent collapses to a single grapheme
      assert Predicates.char?("é") == true
      assert Predicates.char?("ab") == false
    end
  end

  describe "vector?/set?/regex?/map? (via evaluator)" do
    test "vector? true for vectors" do
      assert eval!("(vector? [1 2])") == true
      assert eval!("(vector? {:a 1})") == false
      assert eval!("(vector? \"x\")") == false
    end

    test "set? true for sets" do
      assert eval!("(set? (set [1 2]))") == true
      assert eval!("(set? [1 2])") == false
    end

    test "regex? true for compiled regex patterns" do
      assert eval!("(regex? #\"a+\")") == true
      assert eval!("(regex? \"a+\")") == false
    end

    test "map? true for maps but not sets" do
      assert eval!("(map? {:a 1})") == true
      assert eval!("(map? {})") == true
      assert eval!("(map? (set [1]))") == false
      assert eval!("(map? [1 2])") == false
    end
  end

  describe "set?/map? struct rejection (direct)" do
    test "set? rejects non-MapSet structs and plain maps" do
      assert Predicates.set?(LispKeyword.new("a")) == false
      assert Predicates.set?(%{}) == false
      assert Predicates.set?(MapSet.new([1])) == true
    end

    test "map? rejects structs (which are maps under the hood)" do
      assert Predicates.map?(LispKeyword.new("a")) == false
      assert Predicates.map?(MapSet.new([1])) == false
      assert Predicates.map?(%{a: 1}) == true
    end

    test "regex? false for non-tuples and other tuples" do
      assert Predicates.regex?([1, 2]) == false
      assert Predicates.regex?({:other, 1, 2}) == false
    end
  end

  describe "collection shape predicates (via evaluator)" do
    test "coll? true for vectors, maps, and sets; false otherwise" do
      assert eval!("(coll? [1 2])") == true
      assert eval!("(coll? {:a 1})") == true
      assert eval!("(coll? (set [1]))") == true
      assert eval!("(coll? \"x\")") == false
      assert eval!("(coll? 5)") == false
      assert eval!("(coll? nil)") == false
    end

    test "sequential? and seq? true only for vectors" do
      assert eval!("(sequential? [1 2])") == true
      assert eval!("(sequential? {:a 1})") == false
      assert eval!("(seq? [1 2])") == true
      assert eval!("(seq? (set [1]))") == false
    end

    test "associative? true for vectors and maps" do
      assert eval!("(associative? [1 2])") == true
      assert eval!("(associative? {:a 1})") == true
      assert eval!("(associative? (set [1]))") == false
      assert eval!("(associative? \"x\")") == false
    end

    test "counted? true for vectors, maps, sets, and strings" do
      assert eval!("(counted? [1 2])") == true
      assert eval!("(counted? {:a 1})") == true
      assert eval!("(counted? (set [1]))") == true
      assert eval!("(counted? \"x\")") == true
      assert eval!("(counted? 5)") == false
    end

    test "indexed? and reversible? true for vectors and strings" do
      assert eval!("(indexed? [1 2])") == true
      assert eval!("(indexed? \"x\")") == true
      assert eval!("(indexed? {:a 1})") == false
      assert eval!("(reversible? [1 2])") == true
      assert eval!("(reversible? \"x\")") == true
      assert eval!("(reversible? (set [1]))") == false
    end

    test "sorted? is always false (no sorted collections in PTC-Lisp)" do
      assert eval!("(sorted? [1 2])") == false
      assert eval!("(sorted? {:a 1})") == false
    end

    test "seqable? true for nil, vectors, maps, sets, and strings" do
      assert eval!("(seqable? nil)") == true
      assert eval!("(seqable? [1 2])") == true
      assert eval!("(seqable? {:a 1})") == true
      assert eval!("(seqable? (set [1]))") == true
      assert eval!("(seqable? \"x\")") == true
      assert eval!("(seqable? 5)") == false
    end
  end

  describe "collection predicate fallthrough clauses (direct)" do
    test "coll?/associative?/counted?/indexed?/reversible?/seqable? false for structs and scalars" do
      kw = LispKeyword.new("a")
      assert Predicates.coll?(kw) == false
      assert Predicates.associative?(kw) == false
      assert Predicates.associative?(5) == false
      assert Predicates.counted?(kw) == false
      assert Predicates.counted?(5) == false
      assert Predicates.indexed?(5) == false
      assert Predicates.reversible?(5) == false
      assert Predicates.seqable?(kw) == false
      assert Predicates.seqable?(5) == false
    end
  end

  describe "ifn? (via evaluator)" do
    test "ifn? true for sets, keywords, maps, and functions" do
      assert eval!("(ifn? (set [1]))") == true
      assert eval!("(ifn? :foo)") == true
      assert eval!("(ifn? {:a 1})") == true
      assert eval!("(ifn? inc)") == true
    end

    test "ifn? false for vectors, numbers, strings, and nil" do
      assert eval!("(ifn? [1 2])") == false
      assert eval!("(ifn? 5)") == false
      assert eval!("(ifn? \"x\")") == false
      assert eval!("(ifn? nil)") == false
    end
  end

  describe "ifn? atom/special branches (direct)" do
    test "ifn? true for ordinary keyword atoms, false for special-value atoms and booleans" do
      assert Predicates.ifn?(:foo) == true
      # special atoms have type_of :number, so not invokable
      assert Predicates.ifn?(:infinity) == false
      assert Predicates.ifn?(true) == false
      assert Predicates.ifn?(false) == false
      assert Predicates.ifn?(nil) == false
    end

    test "ifn? on a %Builtin{} function value" do
      builtin = Builtin.wrap(:inc, {:normal, &(&1 + 1)})
      assert Predicates.ifn?(builtin) == true
    end
  end

  describe "symbol?/decimal?/ratio?/rational? (via evaluator + direct)" do
    test "symbol? is always false (PTC-Lisp has no symbols)" do
      assert eval!("(symbol? :x)") == false
      assert Predicates.symbol?("anything") == false
      assert Predicates.symbol?(42) == false
    end

    test "decimal? and ratio? are always false on BEAM" do
      assert eval!("(decimal? 1.5)") == false
      assert eval!("(ratio? 5)") == false
      assert Predicates.decimal?(5) == false
      assert Predicates.ratio?(5) == false
    end

    test "rational? true for integers only" do
      assert eval!("(rational? 5)") == true
      assert eval!("(rational? 1.5)") == false
      assert Predicates.rational?(-3) == true
    end
  end

  describe "nat-int?/neg-int?/pos-int? (via evaluator)" do
    test "nat-int? true for non-negative integers" do
      assert eval!("(nat-int? 0)") == true
      assert eval!("(nat-int? 5)") == true
      assert eval!("(nat-int? -1)") == false
      assert eval!("(nat-int? 1.0)") == false
    end

    test "neg-int? true for negative integers" do
      assert eval!("(neg-int? -1)") == true
      assert eval!("(neg-int? 0)") == false
      assert eval!("(neg-int? -1.0)") == false
    end

    test "pos-int? true for positive integers" do
      assert eval!("(pos-int? 1)") == true
      assert eval!("(pos-int? 0)") == false
      assert eval!("(pos-int? 1.5)") == false
    end
  end

  describe "infinite?/NaN? (via evaluator + direct)" do
    test "infinite? true for both infinities" do
      assert eval!("(infinite? (/ 1.0 0.0))") == true
      assert eval!("(infinite? (/ -1.0 0.0))") == true
      assert eval!("(infinite? 5)") == false
      assert Predicates.infinite?(:negative_infinity) == true
    end

    test "NaN? true for nan only" do
      assert eval!("(NaN? (/ 0.0 0.0))") == true
      assert eval!("(NaN? 5)") == false
      assert Predicates.nan?(:nan) == true
      assert Predicates.nan?(1.5) == false
    end
  end

  describe "map-entry? (always false, DIV-49)" do
    test "map-entry? is false even for literal 2-element vectors" do
      assert eval!("(map-entry? [:a 1])") == false
      assert eval!("(map-entry? (first (seq {:a 1})))") == false
      assert Predicates.map_entry?({:a, 1}) == false
      assert Predicates.map_entry?(:anything) == false
    end
  end

  # ==================================================================
  # type / type_of
  # ==================================================================

  describe "type (via evaluator)" do
    test "type of scalars and collections" do
      assert eval!("(type nil)") == nil
      assert eval!("(type true)") == :boolean
      assert eval!("(type 5)") == :number
      assert eval!("(type (/ 1.0 0.0))") == :number
      assert eval!("(type \"x\")") == :string
      assert eval!("(type [1 2])") == :vector
      assert eval!("(type (set [1]))") == :set
      assert eval!("(type :foo)") == :keyword
      assert eval!("(type {:a 1})") == :map
    end

    test "type of functions, builtins, and regexes" do
      assert eval!("(type (fn [x] x))") == :function
      assert eval!("(type +)") == :function
      assert eval!("(type #\"a\")") == :regex
    end
  end

  describe "type_of (direct, every clause)" do
    test "scalar and struct clauses" do
      assert Predicates.type_of(nil) == nil
      assert Predicates.type_of(true) == :boolean
      assert Predicates.type_of(false) == :boolean
      assert Predicates.type_of(3.14) == :number
      assert Predicates.type_of("s") == :string
      assert Predicates.type_of([1]) == :vector
      assert Predicates.type_of(MapSet.new([1])) == :set
      assert Predicates.type_of(LispKeyword.new("longname")) == :keyword
      assert Predicates.type_of(Builtin.wrap(:f, {:normal, &(&1 + 1)})) == :function
    end

    test "atom clause distinguishes special-value atoms from keyword atoms" do
      assert Predicates.type_of(:infinity) == :number
      assert Predicates.type_of(:negative_infinity) == :number
      assert Predicates.type_of(:nan) == :number
      assert Predicates.type_of(:foo) == :keyword
    end

    test "tuple variants: regex, closure, normal/collect, variadic family, unknown" do
      assert Predicates.type_of({:re_mp, 1, 2, 3}) == :regex
      assert Predicates.type_of({:closure, 1, 2, 3, 4, 5}) == :function
      assert Predicates.type_of({:normal, fn -> 1 end}) == :function
      assert Predicates.type_of({:collect, fn -> 1 end}) == :function
      assert Predicates.type_of({:variadic, 1, 2}) == :function
      assert Predicates.type_of({:variadic_nonempty, 1, 2}) == :function
      assert Predicates.type_of({:multi_arity, 1, 2}) == :function
      assert Predicates.type_of({:special, 1, 2}) == :function
      assert Predicates.type_of({:totally_unknown_tag, 1}) == :unknown
    end

    test "map, raw function, and catch-all clauses" do
      assert Predicates.type_of(%{a: 1}) == :map
      assert Predicates.type_of(fn -> 1 end) == :function
      # a pid is not handled by any specific clause
      assert Predicates.type_of(self()) == :unknown
    end
  end

  # ==================================================================
  # HOF combinators
  # ==================================================================

  describe "comp (via evaluator + direct edge cases)" do
    test "comp composes right-to-left for multiple fns" do
      assert eval!("((comp inc inc) 5)") == 7
      assert eval!("((comp str inc) 5)") == "6"
    end

    test "comp with a single fn returns that fn" do
      assert eval!("((comp inc) 5)") == 6
    end

    test "comp with no args is identity" do
      assert eval!("((comp) 42)") == 42
      assert {:normal, fun} = Predicates.comp_variadic([])
      assert fun.(:x) == :x
    end
  end

  describe "partial (via evaluator + direct errors)" do
    test "partial pre-fills leading arguments" do
      assert eval!("((partial + 10) 5)") == 15
      assert eval!("((partial + 10 20) 5)") == 35
    end

    test "partial with only the fn forwards all args" do
      assert eval!("((partial +) 1 2 3)") == 6
    end

    test "partial with no arguments raises ArgumentError" do
      assert_raise ArgumentError, ~r/partial requires at least 1 argument/, fn ->
        Predicates.partial_variadic([])
      end

      assert eval_error("(partial)") =~ "partial requires at least 1 argument"
    end
  end

  describe "complement (via evaluator)" do
    test "complement negates a predicate's truthiness" do
      assert eval!("((complement number?) 5)") == false
      assert eval!("((complement number?) \"x\")") == true
    end

    test "complement on a non-boolean-returning fn still yields a boolean" do
      assert eval!("((complement identity) nil)") == true
      assert eval!("((complement identity) 0)") == false
    end
  end

  describe "constantly (via evaluator)" do
    test "constantly ignores its arguments" do
      assert eval!("((constantly 42) 1 2 3)") == 42
      assert eval!("((constantly 99))") == 99
      assert eval!("(= ((constantly :x) 1 2) :x)") == true
    end
  end

  describe "every-pred (via evaluator + direct error)" do
    test "every-pred returns true when all preds hold for all values" do
      assert eval!("((every-pred number? pos?) 5 10)") == true
    end

    test "every-pred short-circuits to false on first falsy result" do
      assert eval!("((every-pred number? pos?) 5 -1)") == false
      assert eval!("((every-pred number?) \"x\")") == false
    end

    test "every-pred with no predicates raises ArgumentError" do
      assert_raise ArgumentError, ~r/every-pred requires at least 1 predicate/, fn ->
        Predicates.every_pred_variadic([])
      end

      assert eval_error("(every-pred)") =~ "every-pred requires at least 1 predicate"
    end
  end

  describe "some-fn (via evaluator + direct error)" do
    test "some-fn returns the actual (non-boolean) value of the first truthy result" do
      assert eval!("((some-fn :a :b) {:b 2})") == 2
      assert eval!("((some-fn :a :b) {:a 9 :b 2})") == 9
    end

    test "some-fn returns nil when nothing matches" do
      assert eval!("((some-fn :a :b) {:c 3})") == nil
    end

    test "some-fn with no functions raises ArgumentError" do
      assert_raise ArgumentError, ~r/some-fn requires at least 1 function/, fn ->
        Predicates.some_fn_variadic([])
      end

      assert eval_error("(some-fn)") =~ "some-fn requires at least 1 function"
    end
  end

  # ==================================================================
  # fnil — surface + every internal form
  # ==================================================================

  describe "fnil (via evaluator)" do
    test "fnil substitutes a default for nil in a unary fn" do
      assert eval!("((fnil inc 0) nil)") == 1
      assert eval!("((fnil inc 0) 5)") == 6
    end

    test "fnil works inside map over a vector containing nil" do
      assert eval!("(map (fnil inc 0) [nil 1 2])") == [1, 2, 3]
    end
  end

  describe "fnil internal forms (direct)" do
    test "plain arity-1 function: nil maps to default" do
      f = Predicates.fnil(&(&1 + 100), 7)
      assert f.(nil) == 107
      assert f.(3) == 103
    end

    test "plain arity-2 function: nil first arg maps to default" do
      f = Predicates.fnil(&Math.add/2, 10)
      assert f.(nil, 5) == 15
      assert f.(2, 5) == 7
    end

    test "{:normal, fun} arity 1 dispatch" do
      f = Predicates.fnil({:normal, &(&1 + 1)}, 9)
      assert f.(nil) == 10
      assert f.(4) == 5
    end

    test "{:normal, fun} arity 2 dispatch" do
      f = Predicates.fnil({:normal, &Math.add/2}, 100)
      assert f.(nil, 5) == 105
      assert f.(2, 5) == 7
    end

    test "{:normal, fun} arity >= 3 falls back to a {:collect, fn} wrapper" do
      add3 = fn a, b, c -> a + b + c end
      assert {:collect, fun} = Predicates.fnil({:normal, add3}, 1)
      assert fun.([nil, 2, 3]) == 6
      assert fun.([10, 2, 3]) == 15
    end

    test "{:variadic, …} forms wrap into a {:collect, fn} substituting nil" do
      assert {:collect, fun} = Predicates.fnil({:variadic, &Math.add/2, 0}, 100)
      assert fun.([nil, 1, 2]) == 103
      assert fun.([5, 1, 2]) == 8
    end

    test "{:collect, fun} form substitutes only the first nil argument" do
      assert {:collect, fun} =
               Predicates.fnil({:collect, fn args -> Enum.sum(args) end}, 50)

      assert fun.([nil, 1, 2]) == 53
      assert fun.([3, 1, 2]) == 6
    end

    test "%Builtin{binding: {:normal, fun}} dispatches by arity (arity 1)" do
      builtin = Builtin.wrap(:inc, {:normal, &(&1 + 1)})
      f = Predicates.fnil(builtin, 9)
      assert f.(nil) == 10
      assert f.(4) == 5
    end

    test "%Builtin{} non-normal binding wraps into {:collect, fn}" do
      builtin = Builtin.wrap(:sum, {:collect, fn args -> Enum.sum(args) end})
      assert {:collect, fun} = Predicates.fnil(builtin, 5)
      assert fun.([nil, 1]) == 6
      assert fun.([3, 1]) == 4
    end
  end

  # ==================================================================
  # Coercions: keyword / set / vec
  # ==================================================================

  describe "keyword coercion (via evaluator)" do
    test "keyword on a valid string yields a keyword equal to its literal form" do
      assert eval!(~S<(= (keyword "foo") :foo)>) == true
    end

    test "keyword passes through an existing keyword and returns nil for nil" do
      assert eval!("(= (keyword :bar) :bar)") == true
      assert eval!("(keyword nil)") == nil
    end

    test "keyword rejects empty strings, slashes, and non-string/keyword args" do
      assert eval_error(~S<(keyword "")>) =~ "invalid keyword name"
      assert eval_error(~S<(keyword "foo/bar")>) =~ "invalid keyword name"
      assert eval_error("(keyword 5)") =~ "cannot coerce to keyword"
    end
  end

  describe "keyword coercion (direct, all clauses)" do
    test "nil passes through" do
      assert Predicates.keyword(nil) == nil
    end

    test "ordinary keyword atom passes through unchanged" do
      assert Predicates.keyword(:abc) == :abc
    end

    test "special-value atom raises" do
      assert_raise ArgumentError, ~r/cannot coerce special value to keyword/, fn ->
        Predicates.keyword(:infinity)
      end
    end

    test "%Keyword{} struct passes through unchanged" do
      kw = LispKeyword.new("zoozoo")
      assert Predicates.keyword(kw) == kw
    end

    test "string in the bounded vocabulary interns to an atom" do
      assert Predicates.keyword("count") == :count
    end

    test "string outside the bounded vocabulary becomes a %Keyword{} struct" do
      assert Predicates.keyword("zoozoozoo") == LispKeyword.new("zoozoozoo")
    end

    test "invalid keyword names (operator chars, leading digit) raise" do
      assert_raise ArgumentError, ~r/invalid keyword name/, fn ->
        Predicates.keyword("1abc")
      end

      assert_raise ArgumentError, ~r/invalid keyword name/, fn ->
        Predicates.keyword("a+b")
      end
    end

    test "non-string, non-atom arguments raise" do
      assert_raise ArgumentError, ~r/cannot coerce to keyword/, fn ->
        Predicates.keyword([1, 2])
      end
    end
  end

  describe "set coercion (via evaluator + direct)" do
    test "set from a vector deduplicates" do
      assert eval!("(set [1 2 2 3])") == MapSet.new([1, 2, 3])
    end

    test "set passes an existing MapSet through" do
      assert Predicates.set(MapSet.new([1, 2])) == MapSet.new([1, 2])
      assert Predicates.set([1, 1, 2]) == MapSet.new([1, 2])
    end
  end

  describe "vec coercion (via evaluator + direct)" do
    test "vec returns nil unchanged and a vector unchanged" do
      assert eval!("(vec nil)") == nil
      assert eval!("(vec [1 2])") == [1, 2]
      assert Predicates.vec(nil) == nil
      assert Predicates.vec([1, 2]) == [1, 2]
    end

    test "vec turns a set into a list of its elements" do
      assert Enum.sort(eval!("(vec (set [1 2 3]))")) == [1, 2, 3]
      # MapSet.to_list/1 enumeration order is not guaranteed across runtimes;
      # sort before comparing (the evaluated path above does the same).
      assert Enum.sort(Predicates.vec(MapSet.new([1, 2]))) == [1, 2]
    end

    test "vec turns a string into a list of graphemes (utf8 aware)" do
      assert Predicates.vec("héllo") == ["h", "é", "l", "l", "o"]
      assert Predicates.vec("") == []
    end

    test "vec turns a map into a list of [k v] pairs" do
      assert eval!("(vec {:a 1})") == [["a", 1]]
      assert Predicates.vec(%{x: 1}) == [[:x, 1]]
    end
  end

  # ==================================================================
  # Numeric predicates
  # ==================================================================

  describe "zero?/pos?/neg? (via evaluator)" do
    test "zero? matches integer and float zero" do
      assert eval!("(zero? 0)") == true
      assert eval!("(zero? 0.0)") == true
      assert eval!("(zero? 1)") == false
    end

    test "pos? and neg? on finite numbers" do
      assert eval!("(pos? 5)") == true
      assert eval!("(pos? -5)") == false
      assert eval!("(pos? 0)") == false
      assert eval!("(neg? -5)") == true
      assert eval!("(neg? 5)") == false
    end

    test "pos? and neg? on infinities" do
      assert eval!("(pos? (/ 1.0 0.0))") == true
      assert eval!("(neg? (/ -1.0 0.0))") == true
    end
  end

  describe "pos?/neg? non-number branches (direct)" do
    test "pos? true for positive infinity, false for nan and non-numbers" do
      assert Predicates.pos?(:infinity) == true
      assert Predicates.pos?(:negative_infinity) == false
      assert Predicates.pos?(:nan) == false
      assert Predicates.pos?("x") == false
    end

    test "neg? true for negative infinity, false for nan and non-numbers" do
      assert Predicates.neg?(:negative_infinity) == true
      assert Predicates.neg?(:infinity) == false
      assert Predicates.neg?(:nan) == false
      assert Predicates.neg?([]) == false
    end

    test "zero? false for non-numbers" do
      assert Predicates.zero?(:nan) == false
      assert Predicates.zero?("0") == false
    end
  end

  describe "even?/odd? (via evaluator + direct)" do
    test "even?/odd? on integers" do
      assert eval!("(even? 4)") == true
      assert eval!("(even? 3)") == false
      assert eval!("(odd? 3)") == true
      assert eval!("(odd? 4)") == false
    end

    test "even?/odd? on floats with integer value" do
      assert Predicates.even?(4.0) == true
      assert Predicates.even?(3.0) == false
      assert Predicates.odd?(3.0) == true
      assert Predicates.odd?(4.0) == false
    end

    test "even?/odd? false for non-integer-valued floats and non-numbers" do
      assert Predicates.even?(3.5) == false
      assert Predicates.odd?(3.5) == false
      assert Predicates.even?("4") == false
      assert Predicates.odd?(nil) == false
    end
  end
end
