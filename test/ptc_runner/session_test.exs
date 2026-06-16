defmodule PtcRunner.SessionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PreludeStore
  alias PtcRunner.Session

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
