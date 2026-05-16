defmodule PtcRunner.Lisp.ClosureCaptureTest do
  @moduledoc """
  Closure capture semantics — regression coverage for issue #944 finding #3
  (defn session-memory bloat) and the edge cases flagged in codex review:

    * lexical capture wins over a later `def`
    * params shadow `def`s
    * params shadow builtins
    * nested closures preserve outer-fn params
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  defp run!(src) do
    case Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn) do
      {:ok, step} -> step.return
    end
  end

  describe "lexical capture vs later def" do
    test "let binding captured by closure shadows a later def of the same name" do
      src = """
      (def f (let [x 1] (fn [] x)))
      (def x 2)
      (f)
      """

      assert run!(src) == 1
    end

    test "fn param captured by inner closure is not overridden by a later def" do
      src = """
      (defn make-adder [delta] (fn [n] (+ n delta)))
      (def add3 (make-adder 3))
      (def delta 999)
      (add3 10)
      """

      assert run!(src) == 13
    end
  end

  describe "param shadowing" do
    test "fn param shadows a def of the same name" do
      src = """
      (def x 100)
      (defn id-of [x] x)
      (id-of 7)
      """

      assert run!(src) == 7
    end

    test "fn param shadows a builtin" do
      src = """
      (defn f [count] count)
      (f 42)
      """

      assert run!(src) == 42
    end

    test "let shadowing a builtin is captured by an inner closure" do
      src = """
      (def f (let [count (fn [_] 999)] (fn [xs] (count xs))))
      (f [1 2 3])
      """

      assert run!(src) == 999
    end
  end

  describe "nested closures" do
    test "inner closure sees outer fn's param" do
      src = """
      (defn outer [a] (fn [b] (+ a b)))
      (def add5 (outer 5))
      (add5 4)
      """

      assert run!(src) == 9
    end

    test "three-level nesting preserves each level's binding" do
      src = """
      (defn three [a]
        (fn [b]
          (fn [c] (+ a (* b c)))))
      (((three 1) 2) 3)
      """

      assert run!(src) == 7
    end

    test "inner closure uses outer let binding, not a later def" do
      src = """
      (def g
        (let [k 100]
          (fn [n]
            (fn [] (+ n k)))))
      (def k 0)
      ((g 5))
      """

      assert run!(src) == 105
    end
  end

  describe "caller-scope hygiene after a closure call" do
    # Regression: codex review caught that calling a closure whose param
    # name overlaps a top-level def would leave that name in the caller's
    # `locals` set after the call, so a subsequent reference resolved to a
    # missing env entry (returning nil) instead of falling through to user_ns.
    test "subsequent reference to a def survives a call whose param shadowed it" do
      src = """
      (def x 100)
      (defn id [x] x)
      (id 7)
      x
      """

      assert run!(src) == 100
    end

    test "subsequent reference to a def survives a loop whose binding shadowed it" do
      src = """
      (def x 50)
      (loop [x 1] (if (> x 0) x (recur (- x 1))))
      x
      """

      assert run!(src) == 50
    end
  end

  describe "self-recursive named fn" do
    test "named fn can call itself without leaking into outer scope" do
      src = """
      (defn fact [n]
        (if (<= n 1) 1 (* n (fact (- n 1)))))
      (fact 5)
      """

      assert run!(src) == 120
    end

    # Regression: codex caught that closure_locals adds fn_name to locals,
    # but the HOF (Erlang-fn) wrapper path didn't bind fn_name -> closure
    # in env. So recursive references inside `(map fact xs)` resolved to
    # nil instead of the def'd closure.
    test "named recursive fn works inside a HOF (map)" do
      src = """
      (defn fact [n]
        (if (<= n 1) 1 (* n (fact (- n 1)))))
      (map fact [1 2 3 4 5])
      """

      assert run!(src) == [1, 2, 6, 24, 120]
    end
  end

  describe "user_ns precedence (codex P2-2)" do
    # Regression: a pre-fix attempt promoted caller-injected env entries to
    # `locals`, which inverted the documented precedence locals > user_ns >
    # env. The fix keeps caller-injected env entries OUT of locals so
    # user_ns still wins.
    test "def wins over a caller-injected env entry inside a closure" do
      alias PtcRunner.Lisp.{Env, Eval}

      env = Map.merge(Env.initial(), %{x: :from_env})
      user_ns = %{x: :from_user_ns}

      # (fn [] x) called with the above env/user_ns
      ast = {:call, {:fn, [], {:var, :x}}, []}

      assert {:ok, :from_user_ns, ^user_ns} =
               Eval.eval(ast, %{}, user_ns, env, fn _, _ -> nil end)
    end

    test "caller-injected env entries are captured for string and atom keys" do
      alias PtcRunner.Lisp.Eval

      string_ast = {:call, {:fn, [], {:var, "external"}}, []}
      atom_ast = {:call, {:fn, [], {:var, :external}}, []}

      assert {:ok, :from_string_env, %{}} =
               Eval.eval(string_ast, %{}, %{}, %{"external" => :from_string_env}, fn _, _ ->
                 nil
               end)

      assert {:ok, :from_atom_env, %{}} =
               Eval.eval(atom_ast, %{}, %{}, %{external: :from_atom_env}, fn _, _ -> nil end)
    end
  end

  describe "memory footprint" do
    test "small (defn ...) consumes far less than the captured-env size" do
      src = """
      (defn word-count [text]
        (count (clojure.string/split (clojure.string/trim text) #"\\s+")))
      """

      {:ok, step} = Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn)
      memory_size = :erlang.external_size(step.memory)

      # Pre-fix this was ~18 KB per closure (whole builtin env). With the
      # fix it's a few hundred bytes — well below 2 KB even with a small
      # body. Asserting < 2_000 leaves headroom for AST growth.
      assert memory_size < 2_000,
             "expected defn memory < 2000 bytes, got #{memory_size}"
    end

    test "closure does not capture a sibling let binding it never references (#961)" do
      src = """
      (def f
        (let [unused-big (apply str (range 0 5000))
              also-unused 7]
          (fn [] 42)))
      """

      {:ok, step} = Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn)
      {:closure, _params, _body, captured_env, _history, _meta} = step.memory[:f]

      # The body is the literal `42` — it references nothing, so neither
      # the 5k-char `unused-big` nor `also-unused` should be pinned.
      assert captured_env == %{}

      assert :erlang.external_size(step.memory) < 2_000,
             "closure pinned an unused sibling binding: #{:erlang.external_size(step.memory)} bytes"
    end

    test "closure still captures the sibling binding its body references (#961)" do
      src = """
      (def adder
        (let [base 100
              unused-big (apply str (range 0 5000))]
          (fn [n] (+ n base))))
      """

      {:ok, step} = Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn)
      {:closure, _params, _body, captured_env, _history, _meta} = step.memory[:adder]

      # `base` is referenced and must survive; `unused-big` must not.
      assert Map.keys(captured_env) == ["base"] or Map.keys(captured_env) == [:base]

      # The captured closure remains callable in a later turn.
      {:ok, next} =
        Lisp.run("(adder 5)", profile: :mcp_no_tools, mode: :multi_turn, memory: step.memory)

      assert next.return == 105
    end

    test "closure param does not capture an outer binding with the same name (#961)" do
      src = """
      (def f
        (let [n (apply str (range 0 5000))]
          (fn [n] n)))
      """

      {:ok, step} = Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn)

      {:closure, _params, _body, captured_env, _history, _meta} =
        Map.get(step.memory, "f") || Map.fetch!(step.memory, :f)

      assert captured_env == %{}

      {:ok, next} =
        Lisp.run("(f 123)", profile: :mcp_no_tools, mode: :multi_turn, memory: step.memory)

      assert next.return == 123
      assert :erlang.external_size(step.memory) < 2_000
    end

    test "inner let binding does not capture an outer binding with the same name (#961)" do
      src = """
      (def f
        (let [x (apply str (range 0 5000))]
          (fn [] (let [x 2] x))))
      """

      {:ok, step} = Lisp.run(src, profile: :mcp_no_tools, mode: :multi_turn)

      {:closure, _params, _body, captured_env, _history, _meta} =
        Map.get(step.memory, "f") || Map.fetch!(step.memory, :f)

      assert captured_env == %{}

      {:ok, next} =
        Lisp.run("(f)", profile: :mcp_no_tools, mode: :multi_turn, memory: step.memory)

      assert next.return == 2
      assert :erlang.external_size(step.memory) < 2_000
    end

    test "closures do not retain prior turn history in session memory" do
      large_history_entry = String.duplicate("x", 100_000)

      {:ok, step} =
        Lisp.run("(def f (fn [] 1))",
          profile: :mcp_no_tools,
          mode: :multi_turn,
          turn_history: [large_history_entry]
        )

      memory_size = :erlang.external_size(step.memory)
      {:closure, _params, _body, _env, captured_history, _meta} = step.memory[:f]

      assert captured_history == []

      assert memory_size < 2_000,
             "expected closure memory to exclude turn history, got #{memory_size} bytes"
    end

    test "closure reads current caller turn history, not definition-time history" do
      {:ok, step1} =
        Lisp.run("(def f (fn [] *1))",
          profile: :mcp_no_tools,
          mode: :multi_turn,
          turn_history: ["definition-time"]
        )

      {:ok, step2} =
        Lisp.run("(f)",
          profile: :mcp_no_tools,
          mode: :multi_turn,
          memory: step1.memory,
          turn_history: ["call-time"]
        )

      assert step2.return == "call-time"
    end
  end
end
