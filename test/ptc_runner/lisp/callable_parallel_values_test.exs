defmodule PtcRunner.Lisp.CallableParallelValuesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Format

  test "apply invokes pmap and pcalls values" do
    source = ~S"""
    [(apply pmap [inc [1 2 3]])
     (apply pcalls [(fn [] 1) (fn [] 2)])]
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [[2, 3, 4], [1, 2]]
    assert Enum.map(step.pmap_calls, & &1.type) == [:pmap, :pcalls]
  end

  test "parallel values compose through identity, let, partial, and collection HOFs" do
    source = ~S"""
    [((identity pmap) inc [1 2])
     ((partial pmap inc) [3 4])
     (let [parallel-map pmap] (parallel-map dec [3 4]))
     (map pmap [inc dec] [[1 2] [3 4]])
     (map #(apply pmap %) [[inc [1 2]] [dec [3 4]]])]
    """

    assert {:ok, step} = Lisp.run(source)

    assert step.return == [
             [2, 3],
             [4, 5],
             [2, 3],
             [[2, 3], [2, 3]],
             [[2, 3], [2, 3]]
           ]
  end

  test "parallel values are functions and fnil accepts them" do
    source = ~S"""
    [(fn? pmap)
     (ifn? pmap)
     (fn? pcalls)
     (ifn? pcalls)
     ((fnil pmap inc) nil [1 2])
     ((fnil pcalls (fn [] 7)) nil)]
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [true, true, true, true, [2, 3], [7]]
  end

  test "saved parallel callables use a later evaluation context" do
    assert {:ok, first} =
             Lisp.run(~S|(do (def parallel-map (partial pmap inc)) (def parallel-calls pcalls))|)

    assert {:partial_fn, {:special, :pmap}, [_increment]} = first.memory["parallel-map"]
    assert {:special, :pcalls} = first.memory["parallel-calls"]

    source = ~S"""
    [(parallel-map [1 2])
     (apply parallel-calls [(fn [] 3) (fn [] 4)])]
    """

    assert {:ok, second} = Lisp.run(source, memory: first.memory, pmap_max_concurrency: 1)
    assert second.return == [[2, 3], [3, 4]]
  end

  test "host-backed collection HOF invocation retains parallel effects exactly once" do
    tools = %{"touch" => fn arguments -> arguments["x"] end}

    source = ~S"""
    (first
      (map pmap
        [(fn [x] (do (println x) (tool/touch {"x" x})))]
        [[1 2]]))
    """

    assert {:ok, step} = Lisp.run(source, tools: tools, pmap_max_concurrency: 1)
    assert step.return == [1, 2]
    assert step.prints == ["1", "2"]
    assert Enum.map(step.tool_calls, & &1.args["x"]) == [1, 2]
    assert [%{type: :pmap, count: 2, success_count: 2, error_count: 0}] = step.pmap_calls
  end

  test "host-backed collection HOFs can invoke pcalls values" do
    source = ~S|(map pcalls [(fn [] 1) (fn [] 2)])|

    assert {:ok, step} = Lisp.run(source, pmap_max_concurrency: 1)
    assert step.return == [[1], [2]]
    assert Enum.map(step.pmap_calls, &{&1.type, &1.count}) == [{:pcalls, 1}, {:pcalls, 1}]
  end

  test "parallel values render and describe as functions without leaking their tuples" do
    assert {:ok, step} = Lisp.run(~S|[(describe pmap) (describe pcalls) pmap pcalls]|)

    assert [
             %{type: "function", sample: "#<builtin>"},
             %{type: "function", sample: "#<builtin>"},
             %Format.Builtin{} = pmap,
             %Format.Builtin{} = pcalls
           ] = step.return

    assert inspect(pmap) == "#<builtin>"
    assert inspect(pcalls) == "#<builtin>"
  end

  test "dynamic pmap arity matches the direct analysis error" do
    assert {:error, step} = Lisp.run(~S|(apply pmap [inc])|)
    assert step.fail.reason == :invalid_arity
    assert step.fail.message =~ "expected (pmap f coll)"
    assert step.pmap_calls == []
  end

  test "pcalls accepts pcalls and rejects pmap during zero-arity preflight" do
    assert {:ok, accepted} = Lisp.run(~S|(pcalls pcalls)|)
    assert accepted.return == [[]]
    assert Enum.map(accepted.pmap_calls, &{&1.type, &1.count}) == [{:pcalls, 0}, {:pcalls, 1}]

    assert {:error, rejected} = Lisp.run(~S|(pcalls pmap)|)
    assert rejected.fail.reason == :pcalls_error
    assert rejected.fail.message =~ "zero-arity"
    assert rejected.pmap_calls == []
  end

  test "pcalls accepts tagged callables that can be invoked with zero arguments" do
    source =
      ~S|(pcalls (partial pmap inc [1 2]) (partial pcalls) (partial (fn [& xs] :variadic)) (partial :x {:x 4}))|

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [[2, 3], [], "variadic", 4]
  end

  test "pcalls accepts a partial runtime callable as a zero-arity thunk" do
    source = ~S|(pcalls (partial tool/echo {:x 5}))|
    tools = %{"echo" => fn arguments -> arguments["x"] end}

    assert {:ok, step} = Lisp.run(source, tools: tools)
    assert step.return == [5]
    assert Enum.map(step.tool_calls, & &1.name) == ["echo"]
  end

  test "pcalls accepts zero-arity println and captures its empty print" do
    assert {:ok, step} = Lisp.run(~S|(pcalls println)|)
    assert step.return == [nil]
    assert step.prints == [""]
  end

  test "local bindings continue to shadow both parallel builtins" do
    source = ~S"""
    (let [pmap (fn [x] [:mapped x])
          pcalls (fn [x] [:called x])]
      [(pmap 3) (pcalls 4)])
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [["mapped", 3], ["called", 4]]
    assert step.pmap_calls == []
  end

  test "def bindings shadow direct and indirect parallel calls in the same turn" do
    source = ~S"""
    (do
      (def pmap (fn [f xs] [:mapped (f (first xs))]))
      (def pcalls (fn [f] [:called (f)]))
      [(pmap inc [1 2])
       (apply pmap [inc [2 3]])
       (pcalls (fn [] 4))
       (apply pcalls [(fn [] 5)])])
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [["mapped", 2], ["mapped", 3], ["called", 4], ["called", 5]]
    assert step.pmap_calls == []
  end

  test "persisted def bindings shadow direct parallel calls in later evaluations" do
    assert {:ok, first} =
             Lisp.run(~S|(do (def pmap (fn [_ _] :mapped)) (def pcalls (fn [_] :called)))|)

    assert {:ok, second} =
             Lisp.run(~S|[(pmap inc [1]) (pcalls (fn [] 1))]|, memory: first.memory)

    assert second.return == ["mapped", "called"]
    assert second.pmap_calls == []
  end

  test "a differently shaped global pmap binding is resolved before builtin arity" do
    source = ~S|(do (def pmap (fn [x] [:shadowed x])) (pmap 3))|

    assert {:ok, step} = Lisp.run(source)
    assert step.return == ["shadowed", 3]
    assert step.pmap_calls == []
  end

  test "same-name aliases of qualified parallel values invoke the selected builtins" do
    source = ~S"""
    (do
      (def pmap clojure.core/pmap)
      (def pcalls clojure.core/pcalls)
      [(pmap inc [1 2]) (pcalls (fn [] 3))])
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [[2, 3], [3]]
    assert Enum.map(step.pmap_calls, & &1.type) == [:pmap, :pcalls]
  end

  test "qualified parallel calls bypass same-named global definitions" do
    source = ~S"""
    (do
      (def pmap (fn [_ _] [:shadowed-map]))
      (def pcalls (fn [_] [:shadowed-calls]))
      [(clojure.core/pmap inc [1 2])
       (clojure.core/pcalls (fn [] 3))])
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [[2, 3], [3]]
    assert Enum.map(step.pmap_calls, & &1.type) == [:pmap, :pcalls]
  end

  test "qualified parallel values bypass same-named local bindings" do
    source = ~S"""
    (let [pmap (fn [_ _] [:shadowed-map])
          pcalls (fn [_] [:shadowed-calls])]
      [(apply clojure.core/pmap [inc [1 2]])
       (apply clojure.core/pcalls [(fn [] 3)])])
    """

    assert {:ok, step} = Lisp.run(source)
    assert step.return == [[2, 3], [3]]
    assert Enum.map(step.pmap_calls, & &1.type) == [:pmap, :pcalls]
  end

  test "component compilation accepts parallel functions in value position" do
    source = ~S"""
    (ns parallel.values)
    (def parallel-map pmap)
    (def parallel-calls pcalls)
    (defn map-later [f xs] (apply parallel-map [f xs]))
    """

    assert {:ok, component} = Component.new(id: "parallel.values", source: source)
    assert {:ok, _bundle} = Kernel.compile_bundle([component])
  end
end
