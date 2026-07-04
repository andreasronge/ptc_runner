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

  defp recorded_tool_events do
    {:ok, sink} = TraceLog.start_memory_sink()

    try do
      tools = %{
        "fetch" => fn %{"id" => id} -> %{"id" => id} end
      }

      session = Session.new(session_id: "dupes", tools: tools)

      {{:ok, _}, session} =
        Session.eval(session, ~S|[(tool/fetch {:id 1}) (tool/fetch {:id 1})]|)

      {{:ok, _}, _session} = Session.eval(session, ~S|(tool/fetch {:id 2})|)
    after
      TraceLog.stop_memory_sink(sink)
    end

    MemorySink.events(sink)
  end

  describe "tool closures (plain data access)" do
    test "root session turn events carry canonical tags" do
      {:ok, sink} = TraceLog.start_memory_sink()

      try do
        session =
          Session.new(session_id: "tagged-root", tags: %{"run" => "demo", "stage" => "root"})

        {{:ok, _}, _session} = Session.eval(session, "(+ 1 2)")
      after
        TraceLog.stop_memory_sink(sink)
      end

      [turn] = MemorySink.events(sink)
      assert turn["tags"] == %{"run" => "demo", "stage" => "root"}
    end

    test "root session tags are bounded before turn-event sanitization" do
      too_many = Map.new(1..33, &{"k#{&1}", &1})
      assert_raise ArgumentError, ~r/at most 32 entries/, fn -> Session.new(tags: too_many) end

      too_large = %{"payload" => String.duplicate("x", 4_100)}

      assert_raise ArgumentError, ~r/exceed 4096 encoded bytes/, fn ->
        Session.new(tags: too_large)
      end
    end

    test "expose sessions, turns, programs, and tool calls over a source" do
      tools = Introspection.tools(recorded_events())

      assert %{"items" => [summary], "has_more" => false, "next_cursor" => nil} =
               tools["log_sessions"].(%{})

      assert summary["correlation_id"] == "investigation"
      assert summary["driver"] == "session"
      assert summary["turns"] == 3
      assert summary["committed"] == 2
      assert summary["failed"] == 1

      assert %{"items" => turns} = tools["log_turns"].(%{"session-id" => "investigation"})
      assert length(turns) == 3
      assert Enum.map(turns, & &1["program"]) == ["(def x 1)", "(no-such-fn 1)", "(inc x)"]
      assert Enum.at(turns, 1)["fail"]["reason"] == "unbound_var"
      assert Enum.at(turns, 1)["fail"]["message"] =~ "no-such-fn"

      assert %{"items" => ["(def x 1)", "(no-such-fn 1)", "(inc x)"]} =
               tools["log_programs"].(%{"session-id" => "investigation"})

      # Unknown / missing session id is empty, not an error.
      assert %{"items" => []} = tools["log_turns"].(%{"session-id" => "nope"})
      assert %{"items" => []} = tools["log_turns"].(%{})
    end

    test "filters by tags and exposes counters" do
      {:ok, sink} = TraceLog.start_memory_sink()

      try do
        editor = Session.new(session_id: "editor", tags: %{"run" => "demo", "stage" => "editor"})
        {{:ok, _}, editor} = Session.eval(editor, "(def x 1)")
        {{:error, _}, _editor} = Session.eval(editor, "(missing 1)")

        reviewer =
          Session.new(session_id: "reviewer", tags: %{"run" => "demo", "stage" => "reviewer"})

        {{:ok, _}, _reviewer} = Session.eval(reviewer, "(+ 1 2)")
      after
        TraceLog.stop_memory_sink(sink)
      end

      tools = Introspection.tools(MemorySink.events(sink))

      assert %{"items" => [summary]} =
               tools["log_sessions"].(%{"tags" => %{"stage" => "editor"}})

      assert summary["correlation_id"] == "editor"
      assert summary["tags"] == %{"run" => "demo", "stage" => "editor"}

      assert %{
               "sessions" => 1,
               "attempts" => 2,
               "committed" => 1,
               "failed" => 1
             } = tools["log_counters"].(%{"tags" => %{"stage" => "editor"}})
    end

    test "counter token fields distinguish unknown from observed zero" do
      tools =
        Introspection.tools([
          %{
            "event" => "turn",
            "session_id" => "unknown",
            "driver" => "session",
            "duration_ms" => 7,
            "committed" => true,
            "status" => "ok",
            "tags" => %{"run" => "demo"},
            "data" => %{"tool_calls" => [], "catalog_ops" => []}
          },
          %{
            "event" => "turn",
            "session_id" => "observed-zero",
            "driver" => "sub_agent",
            "duration_ms" => 11,
            "input_tokens" => 0,
            "output_tokens" => 2,
            "total_tokens" => 2,
            "committed" => true,
            "status" => "ok",
            "tags" => %{"run" => "demo"},
            "data" => %{"tool_calls" => [], "catalog_ops" => []}
          }
        ])

      assert %{
               "attempts" => 2,
               "duration_ms" => 18,
               "input_tokens" => 0,
               "input_tokens_known_count" => 1,
               "output_tokens" => 2,
               "output_tokens_known_count" => 1,
               "total_tokens" => 2,
               "total_tokens_known_count" => 1
             } = tools["log_counters"].(%{"tags" => %{"run" => "demo"}})

      assert %{
               "attempts" => 1,
               "duration_ms" => 7,
               "input_tokens" => nil,
               "input_tokens_known_count" => 0,
               "output_tokens" => nil,
               "output_tokens_known_count" => 0,
               "total_tokens" => nil,
               "total_tokens_known_count" => 0
             } = tools["log_counters"].(%{"driver" => "session"})
    end

    test "tag filters ignore malformed historical tag payloads" do
      tools =
        Introspection.tools([
          %{
            "event" => "turn",
            "session_id" => "old",
            "driver" => "session",
            "committed" => true,
            "status" => "ok",
            "tags" => "Map(101 keys)",
            "data" => %{"tool_calls" => []}
          }
        ])

      assert %{"items" => []} = tools["log_sessions"].(%{"tags" => %{"stage" => "editor"}})
      assert %{"attempts" => 0} = tools["log_counters"].(%{"tags" => %{"stage" => "editor"}})
    end

    test "page all projections with one cursor envelope" do
      tools = Introspection.tools(recorded_events())

      assert %{"items" => first_turn, "has_more" => true, "next_cursor" => "1", "limit" => 1} =
               tools["log_turns"].(%{"session-id" => "investigation", "limit" => 1})

      assert Enum.map(first_turn, & &1["program"]) == ["(def x 1)"]

      assert %{"items" => next_turns, "has_more" => false, "next_cursor" => nil} =
               tools["log_turns"].(%{
                 "session-id" => "investigation",
                 "limit" => 10,
                 "cursor" => "1"
               })

      assert Enum.map(next_turns, & &1["program"]) == ["(no-such-fn 1)", "(inc x)"]
    end

    test "clamps zero limits so cursor pagination always makes progress" do
      tools = Introspection.tools(recorded_events())

      assert %{"items" => [_], "has_more" => true, "next_cursor" => "1", "limit" => 1} =
               tools["log_turns"].(%{"session-id" => "investigation", "limit" => 0})
    end
  end

  describe "the log/ prelude end-to-end" do
    test "a program answers what the previous session did using only log/ exports" do
      events = recorded_events()

      program = """
      [(count (get (log/sessions) "items"))
       (count (get (log/turns "investigation") "items"))
       (get (log/programs "investigation") "items")]
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
      (def turns (get (log/turns "investigation") "items"))
      (count (filter (fn [t] (= (get t "committed") false)) turns))
      """

      assert {:ok, %Step{return: 1}} =
               Lisp.run(program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(events)
               )
    end

    test "duplicate tool calls can be detected in PTC-Lisp from args hashes" do
      events = recorded_tool_events()

      program = """
      (def calls (get (log/tool-calls "dupes") "items"))
      (def grouped
        (group-by
          (fn [c] [(get c "tool") (get c "args_hash")])
          calls))
      (count (filter (fn [entry] (> (count (second entry)) 1)) grouped))
      """

      assert {:ok, %Step{return: 1}} =
               Lisp.run(program,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(events)
               )
    end

    test "catalog discovery ops are visible from log turns" do
      {:ok, sink} = TraceLog.start_memory_sink()

      try do
        discovery_exec = fn
          :apropos, ["github" | _] ->
            {:ok, ["github.search(query) - Search repositories"]}

          operation, args ->
            {:programmer_fault, "unexpected discovery call #{inspect({operation, args})}"}
        end

        session = Session.new(session_id: "discovery")

        {{:ok, _}, _session} =
          Session.eval(session, ~s|(apropos "github" {:limit 1})|, discovery_exec: discovery_exec)
      after
        TraceLog.stop_memory_sink(sink)
      end

      tools = Introspection.tools(MemorySink.events(sink))

      assert %{"items" => [turn]} = tools["log_turns"].(%{"session-id" => "discovery"})

      assert [
               %{
                 "operation" => "apropos",
                 "args" => %{"query" => "github", "opts" => %{"limit" => 1}},
                 "outcome" => "ok",
                 "reason" => nil,
                 "duration_ms" => duration
               }
             ] = turn["catalog_ops"]

      assert is_integer(duration)
    end

    test "fails closed when the host does not grant the introspection tools" do
      assert {:error, %Step{} = step} =
               Lisp.run(~S|(log/sessions)|,
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
               Lisp.run(~S|(get (log/programs "from-file") "items")|,
                 prelude: Introspection.prelude_source(),
                 tools: Introspection.tools(path)
               )
    end

    @tag :tmp_dir
    test "reads deterministic directory sources", %{tmp_dir: dir} do
      path_a = Path.join(dir, "a.jsonl")
      path_b = Path.join(dir, "b.jsonl")

      {:ok, _r, ^path_b} =
        TraceLog.with_trace(
          fn ->
            session = Session.new(session_id: "b", tags: %{"run" => "dir"})
            {{:ok, _}, _} = Session.eval(session, "(def b 2)")
          end,
          path: path_b
        )

      {:ok, _r, ^path_a} =
        TraceLog.with_trace(
          fn ->
            session = Session.new(session_id: "a", tags: %{"run" => "dir"})
            {{:ok, _}, _} = Session.eval(session, "(def a 1)")
          end,
          path: path_a
        )

      tools = Introspection.tools(dir)

      assert %{"items" => summaries} = tools["log_sessions"].(%{"tags" => %{"run" => "dir"}})
      assert Enum.map(summaries, & &1["correlation_id"]) == ["a", "b"]

      assert %{"sessions" => 2, "attempts" => 2} =
               tools["log_counters"].(%{"tags" => %{"run" => "dir"}})
    end
  end
end
