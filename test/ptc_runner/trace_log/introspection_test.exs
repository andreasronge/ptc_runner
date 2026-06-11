defmodule PtcRunner.TraceLog.IntrospectionTest do
  @moduledoc """
  Plan P3 Verify: a session can answer "what did my previous session do, and
  where did it waste turns?" using ONLY the `log/` introspection prelude
  exports — and the prelude fails closed without the host-granted tools.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.{Lisp, Session, TraceLog}
  alias PtcRunner.Step
  alias PtcRunner.TraceLog.{Introspection, MemorySink}

  # Records a 3-turn session (2 committed + 1 failed attempt) and returns its
  # turn-log events.
  defp recorded_events do
    {:ok, sink} = TraceLog.start_memory_sink()

    try do
      session = Session.new(session_id: "investigation")
      {{:ok, _}, session} = Session.eval(session, "(def x 1)")
      # A failed attempt: wasted work the analysis should be able to surface.
      {{:error, _}, session} = Session.eval(session, "(no-such-fn 1)")
      {{:ok, _}, _session} = Session.eval(session, "(inc x)")
    after
      TraceLog.stop_memory_sink(sink)
    end

    MemorySink.events(sink)
  end

  describe "tool closures (plain data access)" do
    test "expose sessions, turns, programs, and tool calls over a source" do
      tools = Introspection.tools(recorded_events())

      assert [summary] = tools["log_sessions"].(%{})
      assert summary["correlation_id"] == "investigation"
      assert summary["driver"] == "session"
      assert summary["turns"] == 3
      assert summary["committed"] == 2
      assert summary["failed"] == 1

      turns = tools["log_turns"].(%{"session-id" => "investigation"})
      assert length(turns) == 3
      assert Enum.map(turns, & &1["program"]) == ["(def x 1)", "(no-such-fn 1)", "(inc x)"]

      assert tools["log_programs"].(%{"session-id" => "investigation"}) ==
               ["(def x 1)", "(no-such-fn 1)", "(inc x)"]

      # Unknown / missing session id is empty, not an error.
      assert tools["log_turns"].(%{"session-id" => "nope"}) == []
      assert tools["log_turns"].(%{}) == []
    end
  end

  describe "the log/ prelude end-to-end" do
    test "a program answers what the previous session did using only log/ exports" do
      events = recorded_events()

      program = """
      [(count (log/sessions))
       (count (log/turns "investigation"))
       (log/programs "investigation")]
      """

      assert {:ok, %Step{} = step} =
               Lisp.run(program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(events)
               )

      assert step.return == [
               1,
               3,
               ["(def x 1)", "(no-such-fn 1)", "(inc x)"]
             ]
    end

    test "the analysis layer (where did it waste turns?) lives in PTC-Lisp" do
      events = recorded_events()

      # The model writes the analysis; the Elixir surface only hands it data.
      program = """
      (def turns (log/turns "investigation"))
      (count (filter (fn [t] (= (get t "committed") false)) turns))
      """

      assert {:ok, %Step{return: 1}} =
               Lisp.run(program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(events)
               )
    end

    test "fails closed when the host does not grant the introspection tools" do
      assert {:error, %Step{} = step} =
               Lisp.run("(log/sessions)",
                 prelude: Introspection.prelude_source(),
                 tools: %{}
               )

      assert step.fail.reason == :prelude_attach_failed
      assert step.fail.message =~ "log_sessions"
    end

    @tag :tmp_dir
    test "reads from a JSONL trace path too (not only an in-memory sink)", %{tmp_dir: dir} do
      path = Path.join(dir, "session.jsonl")

      {:ok, _r, ^path} =
        TraceLog.with_trace(
          fn ->
            session = Session.new(session_id: "from-file")
            {{:ok, _}, _} = Session.eval(session, "(def y 2)")
          end,
          path: path
        )

      assert {:ok, %Step{return: ["(def y 2)"]}} =
               Lisp.run(~S|(log/programs "from-file")|,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(path)
               )
    end
  end
end
