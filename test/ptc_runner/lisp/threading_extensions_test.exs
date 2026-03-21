defmodule PtcRunner.Lisp.ThreadingExtensionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # ============================================================
  # as->
  # ============================================================

  describe "as->" do
    test "basic threading with named binding" do
      assert {:ok, %{return: 4}} = Lisp.run("(as-> 1 x (+ x 1) (* x 2))")
    end

    test "zero forms returns expr" do
      assert {:ok, %{return: 42}} = Lisp.run("(as-> 42 x)")
    end

    test "name is available in each form" do
      # x is bound to the map, then we can use x freely in the form
      assert {:ok, %{return: 3}} = Lisp.run("(as-> [1 2 3] x (count x))")
    end

    test "threading where position varies" do
      # Classic use case: thread into different argument positions
      assert {:ok, %{return: [2, 3, 4]}} =
               Lisp.run("(as-> [1 2 3] x (map inc x))")
    end

    test "error with missing name" do
      assert {:error, _} = Lisp.run("(as-> 42)")
    end
  end

  # ============================================================
  # cond-> and cond->>
  # ============================================================

  describe "cond->" do
    test "applies steps where tests are true" do
      assert {:ok, %{return: 2}} = Lisp.run("(cond-> 1 true inc false dec)")
    end

    test "all false leaves value unchanged" do
      assert {:ok, %{return: 42}} = Lisp.run("(cond-> 42 false inc false dec)")
    end

    test "zero clauses returns expr" do
      assert {:ok, %{return: 42}} = Lisp.run("(cond-> 42)")
    end

    test "multiple true clauses apply sequentially" do
      assert {:ok, %{return: 3}} = Lisp.run("(cond-> 1 true inc true inc)")
    end

    test "threads as first argument" do
      assert {:ok, %{return: 5}} = Lisp.run("(cond-> 10 true (- 5))")
    end

    test "error on odd number of forms" do
      assert {:error, _} = Lisp.run("(cond-> 1 true)")
    end
  end

  describe "cond->>" do
    test "threads as last argument" do
      assert {:ok, %{return: -5}} = Lisp.run("(cond->> 10 true (- 5))")
    end

    test "applies steps conditionally" do
      assert {:ok, %{return: [2, 3, 4]}} =
               Lisp.run("(cond->> [1 2 3] true (map inc) false (filter odd?))")
    end
  end

  # ============================================================
  # some-> and some->>
  # ============================================================

  describe "some->" do
    test "threads through non-nil values" do
      assert {:ok, %{return: 2}} = Lisp.run("(some-> 1 inc)")
    end

    test "nil short-circuits immediately" do
      assert {:ok, %{return: nil}} = Lisp.run("(some-> nil inc)")
    end

    test "nil mid-chain short-circuits" do
      # (get {:a nil} :a) => nil, then short-circuits
      assert {:ok, %{return: nil}} = Lisp.run("(some-> {:a nil} (:a) inc)")
    end

    test "false is NOT nil — continues threading" do
      assert {:ok, %{return: true}} = Lisp.run("(some-> false not)")
    end

    test "zero forms returns expr" do
      assert {:ok, %{return: 42}} = Lisp.run("(some-> 42)")
    end

    test "threads as first argument" do
      assert {:ok, %{return: 5}} = Lisp.run("(some-> 10 (- 5))")
    end
  end

  describe "some->>" do
    test "threads as last argument" do
      assert {:ok, %{return: -5}} = Lisp.run("(some->> 10 (- 5))")
    end

    test "nil short-circuits" do
      assert {:ok, %{return: nil}} = Lisp.run("(some->> nil (map inc))")
    end

    test "threads through non-nil" do
      assert {:ok, %{return: [2, 3, 4]}} = Lisp.run("(some->> [1 2 3] (map inc))")
    end
  end

  # ============================================================
  # if-some
  # ============================================================

  describe "if-some" do
    test "binds non-nil value and takes then branch" do
      assert {:ok, %{return: 43}} = Lisp.run("(if-some [x 42] (inc x) :nope)")
    end

    test "nil takes else branch" do
      assert {:ok, %{return: :nope}} = Lisp.run("(if-some [x nil] (inc x) :nope)")
    end

    test "false is NOT nil — binds and takes then branch" do
      assert {:ok, %{return: false}} = Lisp.run("(if-some [x false] x :nope)")
    end

    test "else defaults to nil when omitted" do
      # if-some requires explicit else
      assert {:error, _} = Lisp.run("(if-some [x 42] x)")
    end

    test "error with multiple bindings" do
      assert {:error, _} = Lisp.run("(if-some [x 1 y 2] x :nope)")
    end

    test "error with non-vector binding" do
      assert {:error, _} = Lisp.run("(if-some x x :nope)")
    end
  end

  # ============================================================
  # when-some
  # ============================================================

  describe "when-some" do
    test "binds non-nil value and evaluates body" do
      assert {:ok, %{return: 43}} = Lisp.run("(when-some [x 42] (inc x))")
    end

    test "nil returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(when-some [x nil] (inc x))")
    end

    test "false is NOT nil — binds and evaluates body" do
      assert {:ok, %{return: false}} = Lisp.run("(when-some [x false] x)")
    end

    test "implicit do with multiple body expressions" do
      assert {:ok, %{return: 2}} = Lisp.run("(when-some [x 1] (def a x) (+ a 1))")
    end

    test "error with missing body" do
      assert {:error, _} = Lisp.run("(when-some [x 42])")
    end
  end

  # ============================================================
  # when-first
  # ============================================================

  describe "when-first" do
    test "binds first element of non-empty seq" do
      assert {:ok, %{return: 1}} = Lisp.run("(when-first [x [1 2 3]] x)")
    end

    test "empty seq returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(when-first [x []] x)")
    end

    test "nil collection returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(when-first [x nil] x)")
    end

    test "implicit do with multiple body expressions" do
      assert {:ok, %{return: 20}} = Lisp.run("(when-first [x [10]] (def a x) (* a 2))")
    end

    test "error with missing body" do
      assert {:error, _} = Lisp.run("(when-first [x [1 2 3]])")
    end

    test "error with multiple bindings" do
      assert {:error, _} = Lisp.run("(when-first [x 1 y 2] x)")
    end
  end

  # ============================================================
  # Shadowing
  # ============================================================

  describe "shadowing" do
    test "local binding can shadow cond->" do
      assert {:ok, %{return: 42}} = Lisp.run("(let [cond-> 42] cond->)")
    end

    test "local binding can shadow some->" do
      assert {:ok, %{return: 99}} = Lisp.run("(let [some-> 99] some->)")
    end

    test "local binding can shadow as->" do
      assert {:ok, %{return: 7}} = Lisp.run("(let [as-> 7] as->)")
    end

    test "local binding can shadow if-some" do
      assert {:ok, %{return: 5}} = Lisp.run("(let [if-some 5] if-some)")
    end

    test "local binding can shadow when-some" do
      assert {:ok, %{return: 3}} = Lisp.run("(let [when-some 3] when-some)")
    end

    test "local binding can shadow when-first" do
      assert {:ok, %{return: 8}} = Lisp.run("(let [when-first 8] when-first)")
    end
  end
end
