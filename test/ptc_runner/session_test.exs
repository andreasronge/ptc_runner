defmodule PtcRunner.SessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.PreludeStore
  alias PtcRunner.Session
  import PtcRunner.TestSupport.PublicStepAssertions

  doctest PtcRunner.Session

  describe "eval/3" do
    test "persists def bindings across successful evals" do
      session = Session.new()

      {{:ok, step1}, session} =
        Session.eval(session, "(def session_total 41)")

      assert step1.memory["session_total"] == 41

      {{:ok, step2}, _session} =
        Session.eval(session, "(+ session_total 1)")

      assert step2.return == 42
    end

    test "preserves nested keyword values across evals" do
      session = Session.new()

      {{:ok, _step1}, session} =
        Session.eval(session, "(def m2 {:page {:parse :jsonl}})")

      {{:ok, _step2}, session} =
        Session.eval(session, "(do (defn touch [x] x) (touch 1))")

      {{:ok, step2}, _session} =
        Session.eval(session, "(keyword? (get (get m2 :page) :parse))")

      assert step2.return == true
    end

    test "returns externalized memory while storing native memory internally" do
      session = Session.new()

      {{:ok, step}, session} =
        Session.eval(session, "(def m2 {:page {:parse :jsonl}})")

      assert_public_step!(step)
      page = get_in(step.memory, ["m2", "page"])

      assert (page["parse"] || page[:parse]) == "jsonl"

      page_key = %LispKeyword{name: "page"}
      parse_value = %LispKeyword{name: "jsonl"}

      assert get_in(session.memory, ["m2", page_key, :parse]) == parse_value
    end

    test "preserves keyword return values in turn history across evals" do
      session = Session.new()

      {{:ok, step1}, session} =
        Session.eval(session, ":jsonl")

      {{:ok, step2}, _session} =
        Session.eval(session, "(keyword? *1)")

      assert_public_step!(step1)
      assert_public_step!(step2)
      assert step1.return == "jsonl"
      assert step2.return == true
    end

    test "does not persist a top-level runtime callable binding" do
      tools = %{"echo" => fn args -> args["x"] end}
      session = Session.new(tools: tools)

      {{:ok, step}, session} =
        Session.eval(session, "(def f tool/echo)")

      refute Map.has_key?(step.memory, "f")
      refute Map.has_key?(session.memory, "f")
    end

    test "sanitizes nested runtime callables while preserving nested keywords" do
      tools = %{"echo" => fn args -> args["x"] end}
      session = Session.new(tools: tools)

      {{:ok, _step}, session} =
        Session.eval(session, "(def m {:f tool/echo :xs [tool/echo] :parse :jsonl})")

      {{:ok, step}, _session} =
        Session.eval(
          session,
          "[(keyword? (get m :parse)) (= (get m :f) \"tool/echo\") (= (first (get m :xs)) \"tool/echo\")]"
        )

      assert step.return == [true, true, true]
    end

    test "preserves runtime callables captured by persisted closures" do
      tools = %{"echo" => fn args -> args["x"] end}
      session = Session.new(tools: tools)

      {{:ok, _step}, session} =
        Session.eval(session, ~S|(def f (let [g tool/echo] (fn [xs] (map g xs))))|)

      {{:ok, step}, _session} =
        Session.eval(session, ~S|(f [{:x 7}])|)

      assert step.return == [7]
    end

    test "returns public closure previews while storing native closures internally" do
      session = Session.new()

      {{:ok, step}, session} =
        Session.eval(session, "(defn touch [x] x)")

      assert_public_step!(step)
      assert step.memory["touch"] == "#fn[x]"

      assert match?(
               {:closure, _params, _body, _env, _turn_history, _metadata},
               session.memory["touch"]
             )
    end

    test "*1 reads the most recent successful return" do
      session = Session.new()

      {{:ok, _step}, session} = Session.eval(session, "7")
      {{:ok, step}, _session} = Session.eval(session, "*1")

      assert step.return == 7
    end

    test "history depth is configurable and keeps the newest returns" do
      session = Session.new(history_depth: 2)

      {{:ok, _}, session} = Session.eval(session, "1")
      {{:ok, _}, session} = Session.eval(session, "2")
      {{:ok, _}, session} = Session.eval(session, "3")

      assert session.turn_history == [2, 3]

      {{:ok, step1}, _session} = Session.eval(session, "*1")
      assert step1.return == 3

      {{:ok, step2}, _session} = Session.eval(session, "*2")
      assert step2.return == 2
    end

    test "keeps prior memory and history on errors" do
      session = Session.new()

      {{:ok, _}, session} = Session.eval(session, "(def stable_value 10)")
      {{:ok, _}, session} = Session.eval(session, "20")

      {{:error, step}, returned_session} = Session.eval(session, "missing_value")

      assert step.fail.reason == :unbound_var
      assert returned_session.memory == session.memory
      assert returned_session.turn_history == session.turn_history
    end

    test "stores default run options and lets per-eval options override them" do
      session = Session.new(context: %{"value" => 10}, timeout: 1_000)

      {{:ok, step1}, session} = Session.eval(session, "data/value")
      assert step1.return == 10
      assert session.run_opts[:timeout] == 1_000

      {{:ok, step2}, _session} =
        Session.eval(session, "data/value", context: %{"value" => 20})

      assert step2.return == 20
    end

    test "resolves prelude_store and preludes at session start and freezes the bundle" do
      {:ok, store} = PreludeStore.new()

      v1 = """
      (ns helper)
      (defn answer [] 1)
      """

      v2 = """
      (ns helper)
      (defn answer [] 2)
      """

      assert {:ok, first} = PreludeStore.write(store, "helper", v1)
      first_checksum = first.checksum
      session = Session.new(prelude_store: store, preludes: ["helper"])

      assert {:ok, [%{id: "helper", version: 1, checksum: ^first_checksum}]} =
               Session.preludes(session)

      assert {:ok, second} = PreludeStore.write(store, "helper", v2)
      verifier = Session.new(prelude_store: store, preludes: ["helper"])

      {{:ok, frozen_step}, _session} = Session.eval(session, "(helper/answer)")
      {{:ok, verifier_step}, _session} = Session.eval(verifier, "(helper/answer)")

      assert frozen_step.return == 1
      assert verifier_step.return == 2
      assert Enum.map(frozen_step.prelude_trace.components, & &1.version) == [1]
      assert Enum.map(verifier_step.prelude_trace.components, & &1.version) == [2]

      pinned =
        Session.new(
          prelude_store: store,
          preludes: [%{id: "helper", version: 1, checksum: first.checksum}]
        )

      {{:ok, pinned_step}, _session} = Session.eval(pinned, "(helper/answer)")

      assert pinned_step.return == 1

      for override <- [
            [prelude: nil],
            [preludes: ["helper"]],
            [prelude_store: store]
          ] do
        assert_raise ArgumentError, ~r/cannot override frozen session preludes/, fn ->
          Session.eval(session, "(helper/answer)", override)
        end
      end

      assert_raise ArgumentError, fn ->
        Session.new(
          prelude_store: store,
          preludes: [%{id: "helper", version: 1, checksum: second.checksum}]
        )
      end
    end

    test "selected preludes reject duplicate namespaces and require granted tools at eval" do
      {:ok, store} = PreludeStore.new()

      source = """
      (ns cap)
      (defn fetch []
        (tool/fetch {:id 1}))
      """

      assert {:ok, _} = PreludeStore.write(store, "cap", source)

      assert_raise ArgumentError, fn ->
        Session.new(prelude_store: store, preludes: ["cap", "cap"])
      end

      session = Session.new(prelude_store: store, preludes: ["cap"])
      {{:error, step}, _session} = Session.eval(session, "(cap/fetch)")

      assert step.fail.reason == :prelude_attach_failed

      tools = %{"fetch" => fn _ -> "ok" end}
      session = Session.new(prelude_store: store, preludes: ["cap"], tools: tools)
      {{:ok, step}, _session} = Session.eval(session, "(cap/fetch)")

      assert step.return == "ok"
    end
  end
end
