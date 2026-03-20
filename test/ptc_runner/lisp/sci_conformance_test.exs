defmodule PtcRunner.Lisp.SciConformanceTest do
  @moduledoc """
  Tests ported from the SCI (Small Clojure Interpreter) test suite.

  Source: https://github.com/borkdude/sci  test/sci/core_test.cljc
  These tests verify PTC-Lisp conformance against behavior validated by SCI,
  another sandboxed Clojure interpreter. Each test includes a comment referencing
  the original SCI deftest and line number.

  Run with: mix test test/ptc_runner/lisp/sci_conformance_test.exs
  """
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.ClojureTestHelpers

  alias PtcRunner.Lisp.ClojureValidator

  unless ClojureValidator.available?() do
    @moduletag skip: "Babashka not installed. Run: mix ptc.install_babashka"
  end

  # ---------------------------------------------------------------------------
  # From: core-test (line 48)
  # ---------------------------------------------------------------------------

  describe "SCI core-test - do" do
    @describetag :clojure

    test "do can have multiple expressions" do
      assert_clojure_equivalent("(do 0 1 2)")
    end

    test "do can return nil" do
      assert_clojure_equivalent("[(do 1 2 nil)]")
    end
  end

  describe "SCI core-test - if and when" do
    @describetag :clojure

    test "if with true/false" do
      assert_clojure_equivalent("(if true 10 20)")
      assert_clojure_equivalent("(if false 10 20)")
    end

    test "when returns nil for falsey" do
      assert_clojure_equivalent("(when true 1)")
      assert_clojure_equivalent("(when false 1)")
    end

    test "when can have multiple body expressions" do
      assert_clojure_equivalent("(when true 0 1 2)")
    end
  end

  describe "SCI core-test - and/or" do
    @describetag :clojure

    # SCI line 81-86
    test "and short-circuits" do
      assert_clojure_equivalent("(and false true 0)")
      assert_clojure_equivalent("(and true true 0)")
    end

    test "or short-circuits" do
      assert_clojure_equivalent("(or false false 1)")
      assert_clojure_equivalent("(or false false false 3)")
    end

    test "or with many nils then true" do
      assert_clojure_equivalent(
        "(or nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil nil true)"
      )
    end
  end

  describe "SCI core-test - fn literals" do
    @describetag :clojure

    # SCI line 88-92
    test "#() with single arg" do
      assert_clojure_equivalent("(#(+ 1 %) 1)")
    end

    test "map with #()" do
      assert_clojure_equivalent("(map #(+ 1 %) [0 1 2])")
    end

    test "defn then call via #()" do
      assert_clojure_equivalent("(do (defn foo [] 1) (#(foo)))")
    end
  end

  describe "SCI core-test - map/keep" do
    @describetag :clojure

    # SCI line 93-96
    test "map inc" do
      assert_clojure_equivalent("(map inc [0 1 2])")
    end

    test "keep with predicate" do
      assert_clojure_equivalent("(keep odd? [0 1 2])")
    end
  end

  describe "SCI core-test - literals" do
    @describetag :clojure

    # SCI line 103-113 (adapted — no *in* binding)
    test "literal map with computed values" do
      assert_clojure_equivalent(
        ~S|(let [x 1] {:a (+ 1 2 x) :b {:a (inc x)} :c [x x] :d #{x (inc x)} :e {:a x}})|
      )
    end
  end

  # ---------------------------------------------------------------------------
  # From: destructure-test (line 131)
  # ---------------------------------------------------------------------------

  describe "SCI destructure-test" do
    @describetag :clojure

    test "map destructuring with :keys" do
      assert_clojure_equivalent("(let [{:keys [a]} {:a 1}] a)")
    end

    test "map destructuring with keyword :keys" do
      assert_clojure_equivalent("(let [{:keys [:a]} {:a 1}] a)")
    end

    test "fn with map destructuring" do
      assert_clojure_equivalent("((fn [{:keys [a]}] a) {:a 1})")
      assert_clojure_equivalent("((fn [{:keys [:a]}] a) {:a 1})")
    end

    test "default destructuring with false" do
      assert_clojure_equivalent("(let [{:keys [:a] :or {a false}} {:b 1}] a)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: let-test (line 162)
  # ---------------------------------------------------------------------------

  describe "SCI let-test" do
    @describetag :clojure

    test "let with dependent bindings" do
      assert_clojure_equivalent("(let [x 1 y (+ x x)] [x y])")
    end

    test "let with map destructuring" do
      assert_clojure_equivalent("(let [{:keys [:x :y]} {:x 1 :y 2}] [x y])")
    end

    test "let can have multiple body expressions" do
      assert_clojure_equivalent("(let [x 2] 1 2 3 x)")
    end

    test "nested lets with shadowing" do
      assert_clojure_equivalent("(let [x 1] [(let [x 2] x) x])")
    end
  end

  # ---------------------------------------------------------------------------
  # From: closure-test (line 185)
  # ---------------------------------------------------------------------------

  describe "SCI closure-test" do
    @describetag :clojure

    test "closure captures let binding" do
      assert_clojure_equivalent("(let [x 1] (defn foo [] x)) (foo)")
    end

    test "nested closures" do
      assert_clojure_equivalent("(let [x 1 y 2] ((fn [] (let [g (fn [] y)] (+ x (g))))))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: fn-literal-test (line 191)
  # ---------------------------------------------------------------------------

  describe "SCI fn-literal-test" do
    @describetag :clojure

    test "#(do %) preserves value" do
      assert_clojure_equivalent("(map #(do %) [1 2 3])")
    end

    test "map-indexed with #()" do
      assert_clojure_equivalent("(map-indexed #(do [%1 %2]) [1 2 3])")
    end
  end

  # ---------------------------------------------------------------------------
  # From: fn-test (line 199)
  # ---------------------------------------------------------------------------

  describe "SCI fn-test" do
    @describetag :clojure

    test "recursive named fn" do
      assert_clojure_equivalent("((fn foo [x] (if (< x 3) (foo (inc x)) x)) 0)")
    end

    test "fn with sequential destructuring rest" do
      assert_clojure_equivalent("((fn foo [[x & xs]] xs) [1 2 3])")
    end

    test "fn with & rest args" do
      assert_clojure_equivalent("((fn foo [x & xs] xs) 1 2 3)")
    end

    test "fn with & and nested destructuring" do
      assert_clojure_equivalent("((fn foo [x & [y]] y) 1 2 3)")
    end

    test "apply with & rest fn" do
      assert_clojure_equivalent("(apply (fn [x & xs] xs) 1 2 [3 4])")
    end
  end

  # ---------------------------------------------------------------------------
  # From: def-test (line 229)
  # ---------------------------------------------------------------------------

  describe "SCI def-test" do
    @describetag :clojure

    test "def and use" do
      assert_clojure_equivalent("(do (def foo \"nice val\") foo)")
    end

    test "def with redefinition" do
      assert_clojure_equivalent("(do (def foo 1) (def foo 2) foo)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: defn-test (line 260)
  # ---------------------------------------------------------------------------

  describe "SCI defn-test" do
    @describetag :clojure

    test "defn with docstring" do
      assert_clojure_equivalent("(do (defn foo \"increment\" [x] (inc x)) (foo 1))")
    end

    test "defn redefinition" do
      assert_clojure_equivalent("(do (defn foo [x] (inc x)) (defn foo [x] (dec x)) (foo 1))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: recur-test (line 667)
  # DIV-01: PTC-Lisp enforces a loop iteration limit (default 1000) for sandbox safety.
  # ---------------------------------------------------------------------------

  describe "SCI recur-test" do
    @describetag :clojure

    @tag :skip
    test "recur in defn (DIV-01: loop limit by design)" do
      assert_clojure_equivalent("(defn hello [x] (if (< x 10000) (recur (inc x)) x)) (hello 0)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: loop-test (line 761)
  # ---------------------------------------------------------------------------

  describe "SCI loop-test" do
    @describetag :clojure

    test "loop with destructuring" do
      assert_clojure_equivalent("(loop [[x y] [1 2]] (if (= x 3) y (recur [(inc x) y])))")
    end

    test "loop building a list" do
      assert_clojure_equivalent("""
      (loop [l [2 1]
             c (count l)]
        (if (> c 4)
          l
          (recur (conj l (inc c)) (inc c))))
      """)
    end

    test "loop with shadowed let binding" do
      assert_clojure_equivalent("(let [x 1] (loop [x (inc x)] x))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: for-test (line 800)
  # ---------------------------------------------------------------------------

  describe "SCI for-test" do
    @describetag :clojure

    test "for with :while and :when" do
      assert_clojure_equivalent(
        "(for [i [1 2 3] :while (< i 2) j [4 5 6] :when (even? j)] [i j])"
      )
    end

    test "for with nested destructuring" do
      assert_clojure_equivalent("(for [[_ counts] [[1 [1 2 3]] [3 [1 2 3]]] c counts] c)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: cond-test (line 832)
  # ---------------------------------------------------------------------------

  describe "SCI cond-test" do
    @describetag :clojure

    test "cond with type check" do
      assert_clojure_equivalent("(let [x 2] (cond (string? x) 1 (int? x) 2))")
    end

    test "cond with :else" do
      assert_clojure_equivalent("(let [x 2] (cond (string? x) 1 :else 2))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: regex-test (line 850)
  # ---------------------------------------------------------------------------

  describe "SCI regex-test" do
    @describetag :clojure

    test "re-find with regex literal" do
      assert_clojure_equivalent(~S|(re-find #"\d" "aaa1aaa")|)
    end
  end

  # ---------------------------------------------------------------------------
  # From: defonce-test (line 1142)
  # ---------------------------------------------------------------------------

  describe "SCI defonce-test" do
    @describetag :clojure

    test "defonce preserves first value" do
      assert_clojure_equivalent("(defonce x 1) (defonce x 2) x")
    end
  end

  # ---------------------------------------------------------------------------
  # From: ifs-test (line 1287)
  # ---------------------------------------------------------------------------

  describe "SCI ifs-test" do
    @describetag :clojure

    test "if-let with nil" do
      assert_clojure_equivalent("(if-let [foo nil] 1 2)")
    end

    test "if-let with false" do
      assert_clojure_equivalent("(if-let [foo false] 1 2)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: whens-test (line 1293)
  # ---------------------------------------------------------------------------

  describe "SCI whens-test" do
    @describetag :clojure

    test "when-let with nil" do
      assert_clojure_equivalent("(when-let [foo nil] 1)")
    end

    test "when-let with false" do
      assert_clojure_equivalent("(when-let [foo false] 1)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: threading-macro-test (line 1463)
  # ---------------------------------------------------------------------------

  describe "SCI threading-macro-test" do
    @describetag :clojure

    test "-> chains" do
      assert_clojure_equivalent("(-> 1 inc inc (inc))")
    end

    test "->> with map/count/max" do
      assert_clojure_equivalent(~S|(->> ["foo" "baaar" "baaaaaz"] (map count) (apply max))|)
    end
  end

  # ---------------------------------------------------------------------------
  # From: do-and-or-test (line 1812)
  # Subtle edge cases for and/or return values
  # ---------------------------------------------------------------------------

  describe "SCI do-and-or-test" do
    @describetag :clojure

    test "and returns last truthy or first falsey" do
      assert_clojure_equivalent("(and)")
      assert_clojure_equivalent("(and 1)")
      assert_clojure_equivalent("(and 1 2)")
      assert_clojure_equivalent("(and 1 nil)")
      assert_clojure_equivalent("(and 1 false)")
      assert_clojure_equivalent("(and nil 1)")
      assert_clojure_equivalent("(and false 1)")
    end

    test "or returns first truthy or last falsey" do
      assert_clojure_equivalent("(or)")
      assert_clojure_equivalent("(or 1)")
      assert_clojure_equivalent("(or nil 1)")
      assert_clojure_equivalent("(or nil false)")
      assert_clojure_equivalent("(or false nil)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: top-level-test (line 439)
  # ---------------------------------------------------------------------------

  describe "SCI top-level-test" do
    @describetag :clojure

    test "nil as last expression returns nil" do
      assert_clojure_equivalent("1 2 nil")
    end
  end

  # ---------------------------------------------------------------------------
  # From: idempotent-eval-test (line 532)
  # Note: skipped assertions using `symbol` (not supported) and `list` (not supported)
  # ---------------------------------------------------------------------------

  describe "SCI idempotent-eval-test" do
    @describetag :clojure

    test "map with identity over nested vectors" do
      assert_clojure_equivalent(~S|(map (fn [x] x) [[\"foo\"] [\"bar\"]])|)
    end
  end

  # ---------------------------------------------------------------------------
  # From: comment-test (line 632)
  # Note: `comment` is not a supported form in PTC-Lisp
  # ---------------------------------------------------------------------------

  describe "SCI comment-test" do
    @describetag :clojure

    test "comment returns nil with string arg" do
      assert_clojure_equivalent(~S|(comment "anything")|)
    end

    test "comment returns nil with number" do
      assert_clojure_equivalent("(comment 1)")
    end

    test "comment returns nil with expression" do
      assert_clojure_equivalent("(comment (+ 1 2 (* 3 4)))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: variable-can-have-macro-or-var-name (line 900)
  # ---------------------------------------------------------------------------

  describe "SCI variable-can-have-macro-or-var-name" do
    @describetag :clojure

    test "parameter named merge shadows builtin" do
      assert_clojure_equivalent("(defn foo [merge] merge) (foo true)")
    end

    test "parameter shadowing across multiple defns" do
      assert_clojure_equivalent("(defn foo [merge] merge) (defn bar [foo] foo) (bar true)")
    end

    test "parameter named fn can be called" do
      assert_clojure_equivalent("(defn foo [fn] (fn 1)) (foo inc)")
    end

    # GAP-S06 edge cases: shadowable names (Clojure macros)
    test "let binding named fn shadows special form" do
      assert_clojure_equivalent("(let [fn inc] (fn 1))")
    end

    test "let binding named let shadows special form" do
      assert_clojure_equivalent("(let [let inc] (let 1))")
    end

    test "fn param named when shadows special form" do
      assert_clojure_equivalent("(defn foo [when] (when 1)) (foo inc)")
    end

    test "fn param named cond shadows special form" do
      assert_clojure_equivalent("(defn foo [cond] (cond 1)) (foo inc)")
    end

    test "sequential let bindings shadow incrementally" do
      assert_clojure_equivalent("(let [fn inc x (fn 1)] x)")
    end

    test "fn param as value not in call position" do
      assert_clojure_equivalent("(defn foo [fn] (map fn [1 2 3])) (foo inc)")
    end

    # Negative: true special forms must remain special even when locally bound
    test "if remains special form even with local binding" do
      # (let [if inc] (if true 1 2)) — if is a true special form, cannot be shadowed
      assert_clojure_equivalent("(let [if inc] (if true 1 2))")
    end

    test "recur remains special form in tail position" do
      assert_clojure_equivalent("(loop [x 0] (if (< x 3) (recur (inc x)) x))")
    end
  end

  # ---------------------------------------------------------------------------
  # From: recursion-test (line 1056)
  # Blocked by GAP-F01 (named fn), but ported to track status
  # ---------------------------------------------------------------------------

  describe "SCI recursion-test" do
    @describetag :clojure

    test "named fn recursion to 72" do
      assert_clojure_equivalent("((fn foo [x] (if (= 72 x) x (foo (inc x)))) 0)")
    end
  end

  # ---------------------------------------------------------------------------
  # From: syntax-errors (line 1061)
  # Tests that invalid forms produce errors. We test that PTC-Lisp also errors
  # (both erroring = conformance, even if error messages differ).
  # ---------------------------------------------------------------------------

  describe "SCI syntax-errors" do
    @describetag :clojure

    test "def with namespace-qualified symbol errors" do
      assert_clojure_equivalent("(def f/b 1)")
    end

    test "too many arguments to def errors" do
      assert_clojure_equivalent("(def -main [] 1)")
    end

    test "def with docstring and value" do
      assert_clojure_equivalent(~S|(def x "foo" 1) x|)
    end

    test "defn with namespace-qualified symbol errors" do
      assert_clojure_equivalent("(defn f/b [])")
    end

    test "defn missing params errors" do
      assert_clojure_equivalent("(defn foo)")
    end

    test "defn with parens instead of vector errors" do
      assert_clojure_equivalent("(defn foo ())")
    end
  end

  # ---------------------------------------------------------------------------
  # From: more-than-twenty-args-test (line 1596)
  # ---------------------------------------------------------------------------

  describe "SCI more-than-twenty-args-test" do
    @describetag :clojure

    test "assoc with many key-value pairs" do
      assert_clojure_equivalent(
        "(assoc {} 1 2 3 4 5 6 7 8 9 1 2 3 4 5 6 7 8 9 1 2 3 4 5 6 7 8 9 10)"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # From: defn-kwargs-test (line 303)
  # Uses `& {:keys [a]}` destructuring — rest args + map destructuring
  # ---------------------------------------------------------------------------

  describe "SCI defn-kwargs-test" do
    @describetag :clojure

    test "defn with keyword args via rest destructuring" do
      assert_clojure_equivalent("(defn foo [& {:keys [a]}] {:a a}) (foo :a 1)")
    end
  end

  # ---------------------------------------------------------------------------
  # Expanded partial: core-test - calling IFns (line 122-127)
  # Maps and sets used as functions
  # ---------------------------------------------------------------------------

  describe "SCI core-test - calling IFns" do
    @describetag :clojure

    test "map as function with default" do
      assert_clojure_equivalent("({:a 1} 2 3)")
    end

    test "map as function with hit" do
      assert_clojure_equivalent("({:a 1} :a 3)")
    end

    test "set as function" do
      assert_clojure_equivalent(~S|(#{:a :b :c} :a)|)
    end
  end

  # ---------------------------------------------------------------------------
  # Expanded partial: fn-literal-test (line 196)
  # %& rest args in anonymous function shorthand
  # ---------------------------------------------------------------------------

  describe "SCI fn-literal-test - rest args" do
    @describetag :clojure

    test "#() with %& rest args" do
      assert_clojure_equivalent("(apply #(do %&) [1 2 3])")
    end
  end

  # ---------------------------------------------------------------------------
  # Expanded partial: recur-test (line 670-690)
  # Variadic recur patterns
  # ---------------------------------------------------------------------------

  describe "SCI recur-test - variadic" do
    @describetag :clojure

    test "variadic fn recur through rest args" do
      assert_clojure_equivalent("((fn [& args] (if-let [x (next args)] (recur x) args)) 1 2 3 4)")
    end
  end

  # ---------------------------------------------------------------------------
  # Expanded partial: destructure-test (line 138-139)
  # :strs destructuring
  # ---------------------------------------------------------------------------

  describe "SCI destructure-test - strs" do
    @describetag :clojure

    test "map destructuring with :strs" do
      assert_clojure_equivalent(~S|((fn [{:strs [a]}] a) {"a" 1})|)
    end
  end

  # ---------------------------------------------------------------------------
  # Expanded partial: core-test - duplicate keys (line 114-116)
  # ---------------------------------------------------------------------------

  # ---------------------------------------------------------------------------
  # HOF Combinators: comp, partial, complement, constantly, every-pred, some-fn
  # ---------------------------------------------------------------------------

  describe "comp" do
    @describetag :clojure

    test "zero-arg comp returns identity" do
      assert_clojure_equivalent("((comp) 42)")
    end

    test "single-arg comp returns the function" do
      assert_clojure_equivalent("((comp inc) 5)")
    end

    test "right-to-left composition" do
      assert_clojure_equivalent("((comp str inc) 5)")
    end

    test "rightmost receives multiple args" do
      assert_clojure_equivalent("((comp str +) 1 2 3)")
    end

    test "chain of three functions" do
      assert_clojure_equivalent("((comp inc inc inc) 0)")
    end
  end

  describe "partial" do
    @describetag :clojure

    test "partial with no fixed args delegates" do
      assert_clojure_equivalent("((partial +) 1 2)")
    end

    test "partial with one fixed arg" do
      assert_clojure_equivalent("((partial + 1) 2)")
    end

    test "partial with all args pre-filled" do
      assert_clojure_equivalent("((partial + 1 2))")
    end

    test "partial with multiple extra args" do
      assert_clojure_equivalent("((partial + 1) 2 3 4)")
    end

    test "partial with str" do
      assert_clojure_equivalent(~S|((partial str "a" "b") "c" "d")|)
    end
  end

  describe "complement" do
    @describetag :clojure

    test "complement of even? on odd" do
      assert_clojure_equivalent("((complement even?) 3)")
    end

    test "complement of even? on even" do
      assert_clojure_equivalent("((complement even?) 4)")
    end

    test "complement of nil? on nil" do
      assert_clojure_equivalent("((complement nil?) nil)")
    end

    test "complement with multi-arg function" do
      assert_clojure_equivalent("((complement <) 3 2)")
    end
  end

  describe "constantly" do
    @describetag :clojure

    test "constantly with zero call-args" do
      assert_clojure_equivalent("((constantly 5))")
    end

    test "constantly ignores args" do
      assert_clojure_equivalent("((constantly 5) 1 2 3)")
    end

    test "constantly nil" do
      assert_clojure_equivalent("((constantly nil) :a :b)")
    end
  end

  describe "every-pred" do
    @describetag :clojure

    test "single pred true" do
      assert_clojure_equivalent("((every-pred even?) 4)")
    end

    test "two preds both true" do
      assert_clojure_equivalent("((every-pred even? pos?) 4)")
    end

    test "two preds one false" do
      assert_clojure_equivalent("((every-pred even? pos?) -4)")
    end

    test "multi-value all pass" do
      assert_clojure_equivalent("((every-pred even? pos?) 4 6 8)")
    end

    test "multi-value one fails" do
      assert_clojure_equivalent("((every-pred even? pos?) 4 -6 8)")
    end

    test "three predicates" do
      assert_clojure_equivalent("((every-pred number? pos? even?) 4)")
    end

    test "zero-arg invocation returns true (vacuous)" do
      assert_clojure_equivalent("((every-pred even?))")
    end
  end

  describe "some-fn" do
    @describetag :clojure

    test "returns actual truthy value from keyword lookup" do
      assert_clojure_equivalent("((some-fn :a :b) {:a 1})")
    end

    test "falls through to second fn" do
      assert_clojure_equivalent("((some-fn :a :b) {:b 2})")
    end

    test "returns nil when none match" do
      assert_clojure_equivalent("((some-fn :a :b) {:c 3})")
    end

    test "skips nil-returning fns" do
      assert_clojure_equivalent("((some-fn (constantly nil) (constantly 42)) 1)")
    end

    test "returns truthy boolean from predicate" do
      assert_clojure_equivalent("((some-fn even? pos?) 3)")
    end

    test "returns false when no pred matches" do
      assert_clojure_equivalent("((some-fn even? pos?) -3)")
    end

    test "zero-arg invocation returns nil" do
      assert_clojure_equivalent("((some-fn even?))")
    end
  end

  describe "HOF combinators in HOFs (integration)" do
    @describetag :clojure

    test "comp in map" do
      assert_clojure_equivalent("(map (comp inc inc) [1 2 3])")
    end

    test "complement in filter" do
      assert_clojure_equivalent("(filter (complement even?) [1 2 3 4])")
    end

    test "partial in map" do
      assert_clojure_equivalent("(map (partial + 10) [1 2 3])")
    end

    test "every-pred in filter" do
      assert_clojure_equivalent("(filter (every-pred even? pos?) [-2 -1 0 1 2 3 4])")
    end
  end

  # DIV-06: Intentional divergence — PTC-Lisp silently deduplicates instead of
  # erroring on duplicate computed keys in map/set literals. Without exception
  # handling, an error would crash the program with no recovery path. Silent
  # dedup is more resilient for LLM-generated sandboxed code.
  describe "SCI core-test - duplicate keys" do
    @describetag :clojure

    @tag :skip
    test "duplicate keys in set literal errors (DIV-06: silent dedup by design)" do
      assert_clojure_equivalent(~S|(let [a 1 b 1] #{a b})|)
    end

    @tag :skip
    test "duplicate keys in map literal errors (DIV-06: silent dedup by design)" do
      assert_clojure_equivalent("(let [a 1 b 1] {a 1 b 2})")
    end
  end
end
