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

    test "captures execution with tools (tool events not captured - sandbox process)", %{
      tmp_dir: dir
    } do
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

      # Note: tool.start/tool.stop events are NOT captured because tool telemetry
      # runs inside the sandbox process which doesn't have the trace collector
      # in its process dictionary. The main events are captured correctly.
      assert "run.start" in event_types
      assert "run.stop" in event_types
      assert "turn.start" in event_types
      assert "llm.start" in event_types
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

      assert trace_start1["meta"]["process"] == "task1"
      assert trace_start2["meta"]["process"] == "task2"
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
  end
end
