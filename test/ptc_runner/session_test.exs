defmodule PtcRunner.SessionTest do
  use ExUnit.Case, async: true

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
  end
end
