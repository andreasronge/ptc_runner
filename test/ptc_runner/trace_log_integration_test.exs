defmodule PtcRunner.TraceLogIntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.TraceLog

  @moduletag :tmp_dir

  # Mock LLM that returns predefined responses in sequence
  # Responses should be valid PTC-Lisp code
  defp mock_llm(responses) when is_list(responses) do
    agent = Agent.start_link(fn -> responses end) |> elem(1)

    fn %{messages: _} ->
      response =
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {"(return :done)", []}
        end)

      {:ok, %{content: response, tokens: %{input: 10, output: 5}}}
    end
  end

  describe "TraceLog with SubAgent" do
    # Note: max_turns must be > 1 or tools must be present for telemetry to be emitted
    # (single-shot mode with no tools uses run_single_shot which has no telemetry)

    test "captures SubAgent execution events", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return an integer",
          max_turns: 3
        )

      # Use valid PTC-Lisp expression with (return ...) for multi-turn mode
      {:ok, {:ok, step}, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm(["(return (+ 40 2))"])) end,
          path: path
        )

      assert step.return == 42
      assert trace_path == path
      assert File.exists?(path)

      # Load and analyze the trace
      events = TraceLog.Analyzer.load(trace_path)

      # Should have trace.start and multiple SubAgent events
      assert length(events) >= 3

      # Check for expected events
      event_types = Enum.map(events, & &1["event"])
      assert "trace.start" in event_types
      assert "run.start" in event_types
      assert "run.stop" in event_types
    end

    test "captures multi-turn execution", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 3
        )

      {:ok, {:ok, _step}, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm(["(+ 1 2)", "(return 42)"])) end,
          path: path
        )

      events = TraceLog.Analyzer.load(trace_path)
      event_types = Enum.map(events, & &1["event"])

      # Should have turn events
      assert "turn.start" in event_types
      assert "turn.stop" in event_types
    end

    test "captures LLM events", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 3
        )

      {:ok, _result, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm(["(return (+ 40 2))"])) end,
          path: path
        )

      events = TraceLog.Analyzer.load(trace_path)
      event_types = Enum.map(events, & &1["event"])

      assert "llm.start" in event_types
      assert "llm.stop" in event_types
    end

    test "captures execution with tools (tool events captured via sandbox trace propagation)",
         %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      # Tools receive a map of arguments with string keys
      double_tool = fn args -> args["x"] * 2 end

      agent =
        SubAgent.new(
          prompt: "Double 21 and return it",
          max_turns: 3,
          tools: %{"double" => double_tool}
        )

      # PTC-Lisp tools are called with tool/ prefix and map arguments
      {:ok, {:ok, step}, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm([~S|(return (tool/double {:x 21}))|])) end,
          path: path
        )

      # Tool was executed correctly
      assert step.return == 42

      events = TraceLog.Analyzer.load(trace_path)
      event_types = Enum.map(events, & &1["event"])

      # Sandbox propagates trace collectors via TraceLog.join, so tool events
      # emitted inside the sandbox are captured by the trace handler.
      assert "run.start" in event_types
      assert "run.stop" in event_types
      assert "turn.start" in event_types
      assert "llm.start" in event_types
      assert "tool.start" in event_types
      assert "tool.stop" in event_types
    end

    test "captures tool events when tools use {function, options} tuple format", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      # Tools defined as {function, keyword_options} — the format used in livebooks/guides
      double_tool = fn args -> args["x"] * 2 end

      agent =
        SubAgent.new(
          prompt: "Double 21 and return it",
          max_turns: 3,
          tools: %{
            "double" =>
              {double_tool, signature: "(x :int) -> :int", description: "Double a number"}
          }
        )

      {:ok, {:ok, step}, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm([~S|(return (tool/double {:x 21}))|])) end,
          path: path
        )

      assert step.return == 42

      events = TraceLog.Analyzer.load(trace_path)
      event_types = Enum.map(events, & &1["event"])

      # Tool telemetry events must be captured regardless of how tools are defined
      assert "tool.start" in event_types
      assert "tool.stop" in event_types
    end

    test "summary extracts correct metrics", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 3
        )

      {:ok, _result, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm(["(return (+ 40 2))"])) end,
          path: path
        )

      events = TraceLog.Analyzer.load(trace_path)
      summary = TraceLog.Analyzer.summary(events)

      assert is_integer(summary.duration_ms) and summary.duration_ms >= 0
      assert summary.llm_calls == 1
    end

    test "isolates traces between processes", %{tmp_dir: dir} do
      path1 = Path.join(dir, "trace1.jsonl")
      path2 = Path.join(dir, "trace2.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1
        )

      # Run two traces in separate processes
      task1 =
        Task.async(fn ->
          TraceLog.with_trace(
            fn -> SubAgent.run(agent, llm: mock_llm(["42"])) end,
            path: path1,
            meta: %{process: "task1"}
          )
        end)

      task2 =
        Task.async(fn ->
          TraceLog.with_trace(
            fn -> SubAgent.run(agent, llm: mock_llm(["100"])) end,
            path: path2,
            meta: %{process: "task2"}
          )
        end)

      {:ok, _, _} = Task.await(task1)
      {:ok, _, _} = Task.await(task2)

      # Each trace should be independent
      events1 = TraceLog.Analyzer.load(path1)
      events2 = TraceLog.Analyzer.load(path2)

      # Check metadata identifies the correct process
      trace_start1 = Enum.find(events1, &(&1["event"] == "trace.start"))
      trace_start2 = Enum.find(events2, &(&1["event"] == "trace.start"))

      assert trace_start1["data"]["process"] == "task1"
      assert trace_start2["data"]["process"] == "task2"
    end

    test "handles execution errors gracefully", %{tmp_dir: dir} do
      path = Path.join(dir, "trace.jsonl")

      agent =
        SubAgent.new(
          prompt: "Return 42",
          max_turns: 1
        )

      # LLM returns invalid Lisp
      {:ok, {:error, _step}, trace_path} =
        TraceLog.with_trace(
          fn -> SubAgent.run(agent, llm: mock_llm(["(invalid-syntax"])) end,
          path: path
        )

      # Trace should still be complete
      assert File.exists?(trace_path)
      events = TraceLog.Analyzer.load(trace_path)
      assert events != []
    end

    test "captures compaction.triggered events with full numeric data in JSONL",
         %{tmp_dir: dir} do
      # Codex review for step 4 flagged that handler errors are swallowed at
      # debug level — a test that just runs the agent and checks step.return
      # would silently miss broken JSONL writes. So this test reads the file
      # and asserts both the event presence AND that the numeric measurements
      # survived the from_telemetry/4 → JSONL round-trip.

      path = Path.join(dir, "trace.jsonl")

      content = String.duplicate("x", 200)

      agent =
        SubAgent.new(
          prompt: "Test",
          max_turns: 6,
          compaction: [trigger: [turns: 1], keep_recent_turns: 1, keep_initial_user: true]
        )

      llm =
        mock_llm([
          "\"#{content}\"",
          "\"#{content}\"",
          "\"#{content}\"",
          "(return {:result 42})"
        ])

      {:ok, {:ok, step}, trace_path} =
        TraceLog.with_trace(fn -> SubAgent.run(agent, llm: llm) end, path: path)

      assert step.return == %{"result" => 42}

      events = TraceLog.Analyzer.load(trace_path)

      # `Analyzer.filter` accepts a `type:` prefix match.
      compaction_events = TraceLog.Analyzer.filter(events, type: "compaction")

      assert compaction_events != [], "Expected at least one compaction event in JSONL"

      first = hd(compaction_events)
      assert first["event"] == "compaction.triggered"
      assert is_integer(first["turn"])

      # Critical: the numeric measurements must survive into data. Pre-fix,
      # Event.from_telemetry/4 dropped non-promoted measurements entirely.
      data = first["data"] || %{}
      assert is_integer(data["messages_before"])
      assert is_integer(data["messages_after"])
      assert is_integer(data["estimated_tokens_before"])
      assert is_integer(data["estimated_tokens_after"])
      assert data["messages_after"] < data["messages_before"]

      # Descriptive metadata also lands in data.
      assert data["strategy"] == "trim"
      assert data["reason"] in ["turn_pressure", "token_pressure"]
      assert is_boolean(data["kept_initial_user?"])
      assert is_integer(data["kept_recent_turns"])
    end
  end
end
