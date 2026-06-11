defmodule PtcRunner.TraceLog.TurnLogIntegrationTest do
  @moduledoc """
  Plan P2 Verify: a multi-turn `PtcRunner.Session` and a `PtcRunner.SubAgent`
  run, under the same `TraceLog.with_trace`, must produce turn events of the
  SAME top-level shape, queryable through the same `Analyzer` calls.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.{Session, SubAgent, TraceLog}
  alias PtcRunner.TraceContext
  alias PtcRunner.TraceLog.{Analyzer, MemorySink}

  @moduletag :tmp_dir

  defp mock_llm(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn %{messages: _} ->
      response =
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {"(return :done)", []}
        end)

      {:ok, %{content: response, tokens: %{input: 10, output: 5}}}
    end
  end

  defp session_turn_events(dir, name, fun) do
    path = Path.join(dir, "#{name}.jsonl")
    {:ok, _result, ^path} = TraceLog.with_trace(fun, path: path)
    path |> Analyzer.load() |> Analyzer.turn_events()
  end

  describe "both drivers produce the same turn-event shape" do
    test "session and SubAgent turns share top-level + data keys", %{tmp_dir: dir} do
      session_turns =
        session_turn_events(dir, "session", fn ->
          session = Session.new(session_id: "sess-A")
          {{:ok, _}, session} = Session.eval(session, "(def x 1)")
          {{:ok, _}, _session} = Session.eval(session, "(inc x)")
        end)

      sub_turns =
        session_turn_events(dir, "subagent", fn ->
          agent = SubAgent.new(prompt: "Return 42", max_turns: 3)
          SubAgent.run(agent, llm: mock_llm(["(+ 1 2)", "(return 42)"]))
        end)

      assert session_turns != []
      assert sub_turns != []

      session_event = hd(session_turns)
      sub_event = hd(sub_turns)

      # Identical top-level shape across drivers (values differ; keys do not).
      assert Map.keys(session_event) |> Enum.sort() == Map.keys(sub_event) |> Enum.sort()

      assert Map.keys(session_event["data"]) |> Enum.sort() ==
               Map.keys(sub_event["data"]) |> Enum.sort()

      assert session_event["driver"] == "session"
      assert sub_event["driver"] == "sub_agent"
      assert session_event["event"] == "turn"
      assert sub_event["event"] == "turn"

      # The collector stamped correlation fields the builder left out.
      assert is_binary(session_event["trace_id"])
      assert is_integer(session_event["seq"])
      assert is_binary(session_event["timestamp"])
    end

    test "both are queryable through the same Analyzer.sessions/1 call", %{tmp_dir: dir} do
      session_turns =
        session_turn_events(dir, "s", fn ->
          session = Session.new(session_id: "sess-Q")
          {{:ok, _}, session} = Session.eval(session, "(def a 1)")
          {{:ok, _}, _} = Session.eval(session, "(inc a)")
        end)

      sub_turns =
        session_turn_events(dir, "a", fn ->
          agent = SubAgent.new(prompt: "Return 7", max_turns: 3)
          SubAgent.run(agent, llm: mock_llm(["(+ 1 1)", "(return 7)"]))
        end)

      combined = session_turns ++ sub_turns
      summaries = Analyzer.sessions(combined)

      # One summary per correlation id (session_id for sessions, agent_id for
      # SubAgent), each reporting the driver and turn counts.
      assert Enum.any?(summaries, &(&1.correlation_id == "sess-Q" and &1.driver == "session"))
      assert Enum.any?(summaries, &(&1.driver == "sub_agent"))

      sess_summary = Enum.find(summaries, &(&1.correlation_id == "sess-Q"))
      assert sess_summary.turns == 2
      assert sess_summary.committed == 2

      assert Analyzer.session_turns(combined, "sess-Q") == session_turns
      assert "(inc a)" in Analyzer.programs(session_turns)
    end

    test "SubAgent turns carry prelude provenance only when actually attached", %{tmp_dir: dir} do
      {:ok, prelude} =
        Compiler.compile("""
        (ns util "Pure helpers." {:visibility :prompt})
        (defn add-one [x] (+ x 1))
        """)

      turns =
        session_turn_events(dir, "sub-prelude", fn ->
          agent = SubAgent.new(prompt: "Return", max_turns: 5, runtime_prelude: prelude)
          # turn 1 is a parse failure (no program -> never attached); the rest
          # execute under the prelude.
          SubAgent.run(agent, llm: mock_llm(["not lisp ((", "(+ 1 0)", "(return 1)"]))
        end)

      {no_program, executed} = Enum.split_with(turns, &is_nil(&1["data"]["program"]))

      # Previously [] for ALL sub_agent turns even with a prelude attached.
      assert executed != []

      assert Enum.all?(executed, fn t ->
               match?([%{"namespaces" => ["util"], "source_hash" => _}], t["data"]["preludes"])
             end)

      # No-program turns never reached Lisp attach, so no provenance (matches
      # Session, which reads the step's prelude_trace).
      assert Enum.all?(no_program, &(&1["data"]["preludes"] == []))
    end

    test "an attach-failure turn reports no prelude even when one is configured", %{tmp_dir: dir} do
      # A prelude requiring an ungranted tool fails attach on every turn.
      {:ok, prelude} =
        Compiler.compile("""
        (ns cap "Needs an ungranted tool." {:visibility :prompt})
        (defn f [] (tool/ungranted {}))
        """)

      turns =
        session_turn_events(dir, "sub-attach-fail", fn ->
          agent = SubAgent.new(prompt: "Return", max_turns: 3, runtime_prelude: prelude)
          SubAgent.run(agent, llm: mock_llm(["(f)", "(f)", "(f)"]))
        end)

      assert turns != []
      assert Enum.any?(turns, &(&1["data"]["fail"]["reason"] == "prelude_attach_failed"))
      # Configured but never attached -> empty provenance (no false positive).
      assert Enum.all?(turns, &(&1["data"]["preludes"] == []))
    end

    test "outer turn keeps its own provenance when a continuation guard clobbers the slot",
         %{tmp_dir: dir} do
      {:ok, prelude} =
        Compiler.compile("""
        (ns util "Pure helpers." {:visibility :prompt})
        (defn add-one [x] (+ x 1))
        """)

      # Simulate a nested SubAgent run (e.g. via continuation_guard) clobbering
      # the shared per-turn slot between the outer turn's Lisp.run and its emit.
      # The provenance is captured onto the Turn at build time, so the outer
      # event must still report the OUTER prelude, never the child's.
      guard = fn _turn, _state, _next ->
        TraceContext.put_lisp_prelude_trace(%{
          source_hash: "child",
          protected_namespaces: ["child"]
        })

        :continue
      end

      turns =
        session_turn_events(dir, "reentrant", fn ->
          agent = SubAgent.new(prompt: "Return", max_turns: 5, runtime_prelude: prelude)
          SubAgent.run(agent, llm: mock_llm(["(+ 1 0)", "(return 1)"]), continuation_guard: guard)
        end)

      executed = Enum.reject(turns, &is_nil(&1["data"]["program"]))
      assert executed != []
      assert Enum.all?(executed, &match?([%{"namespaces" => ["util"]}], &1["data"]["preludes"]))
      refute Enum.any?(turns, &match?([%{"namespaces" => ["child"]}], &1["data"]["preludes"]))
    end

    test "SubAgent failed turns carry fail reason; no-program turns keep raw_response",
         %{tmp_dir: dir} do
      turns =
        session_turn_events(dir, "subfail", fn ->
          agent = SubAgent.new(prompt: "Return an integer", max_turns: 5)

          SubAgent.run(agent,
            llm: mock_llm(["this is not lisp ((", "(undefined-thing)", "(return 1)"])
          )
        end)

      # A no-program (parse-failure) turn keeps the raw LLM output, the only
      # record of what the model generated in a memory-sink-only trace.
      assert Enum.any?(turns, fn t ->
               t["data"]["program"] == nil and is_binary(t["data"]["raw_response"]) and
                 t["data"]["raw_response"] =~ "not lisp"
             end)

      # A failed-program turn carries a structured fail reason, so the canonical
      # analyzer path can distinguish failure types without the legacy event.
      assert Enum.any?(turns, fn t ->
               t["committed"] == false and is_map(t["data"]["fail"]) and
                 t["data"]["fail"]["reason"]
             end)
    end
  end

  describe "session turn-log semantics" do
    test "autogenerates a unique session_id and honors an override" do
      assert Session.new().session_id != Session.new().session_id
      assert Session.new(session_id: "fixed").session_id == "fixed"
    end

    test "turn advances on success, attempts advance on every eval", %{tmp_dir: dir} do
      turns =
        session_turn_events(dir, "counters", fn ->
          session = Session.new(session_id: "sess-C")
          {{:ok, _}, session} = Session.eval(session, "(def x 1)")
          # A failing attempt: unbound symbol called as a function.
          {{:error, _}, session} = Session.eval(session, "(no-such-fn 1)")
          {{:ok, _}, session} = Session.eval(session, "(inc x)")
          session
        end)

      assert [first, failed, third] = turns

      assert first["committed"] == true
      assert first["turn"] == 1
      assert first["attempt"] == 1

      # The failed attempt is recorded but does NOT advance the committed turn.
      assert failed["committed"] == false
      assert failed["status"] == "error"
      assert failed["turn"] == 1
      assert failed["attempt"] == 2
      assert failed["data"]["fail"]["reason"]

      assert third["committed"] == true
      assert third["turn"] == 2
      assert third["attempt"] == 3
    end

    test "records a memory diff and prelude provenance is absent without a prelude", %{
      tmp_dir: dir
    } do
      [turn] =
        session_turn_events(dir, "memdiff", fn ->
          session = Session.new(session_id: "sess-M")
          {{:ok, _}, _} = Session.eval(session, "(def answer 42)")
        end)

      assert turn["data"]["memory_diff"]["changed_keys"] == ["answer"]
      assert turn["data"]["memory_diff"]["values"]["answer"] == 42
      assert turn["data"]["preludes"] == []
    end

    test "the default in-memory sink receives session turns" do
      {:ok, sink} = TraceLog.start_memory_sink()

      try do
        session = Session.new(session_id: "mem-1")
        {{:ok, _}, session} = Session.eval(session, "(def a 1)")
        {{:ok, _}, _} = Session.eval(session, "(inc a)")
      after
        TraceLog.stop_memory_sink(sink)
      end

      events = MemorySink.events(sink)
      assert length(events) == 2
      assert Enum.all?(events, &(&1["event"] == "turn"))

      assert [summary] = Analyzer.sessions(events)
      assert summary.correlation_id == "mem-1"
      assert summary.turns == 2
      assert summary.committed == 2
      assert summary.failed == 0
    end

    test "no turn events are emitted when nothing is recording", %{tmp_dir: dir} do
      # Outside with_trace / a memory sink, eval must not error and must not
      # leak records into a subsequently-opened trace.
      session = Session.new(session_id: "sess-silent")
      {{:ok, _}, _} = Session.eval(session, "(def x 1)")

      path = Path.join(dir, "silent.jsonl")
      {:ok, _r, ^path} = TraceLog.with_trace(fn -> :ok end, path: path)
      assert path |> Analyzer.load() |> Analyzer.turn_events() == []
    end

    test "nested traces each capture the turn event (fan-out to all collectors)", %{tmp_dir: dir} do
      outer_path = Path.join(dir, "outer.jsonl")
      inner_path = Path.join(dir, "inner.jsonl")

      {:ok, _r, ^outer_path} =
        TraceLog.with_trace(
          fn ->
            {:ok, _r2, ^inner_path} =
              TraceLog.with_trace(
                fn ->
                  session = Session.new(session_id: "nested")
                  {{:ok, _}, _} = Session.eval(session, "(def x 1)")
                end,
                path: inner_path
              )
          end,
          path: outer_path
        )

      inner_turns = inner_path |> Analyzer.load() |> Analyzer.turn_events()
      outer_turns = outer_path |> Analyzer.load() |> Analyzer.turn_events()

      # The turn lands in BOTH traces, matching the telemetry handler's
      # all-collectors routing — not just the innermost trace.
      assert length(inner_turns) == 1
      assert length(outer_turns) == 1
      assert hd(inner_turns)["session_id"] == "nested"
      assert hd(outer_turns)["session_id"] == "nested"
      # Each collector stamped its own trace_id on its copy.
      assert hd(inner_turns)["trace_id"] != hd(outer_turns)["trace_id"]
    end
  end
end
