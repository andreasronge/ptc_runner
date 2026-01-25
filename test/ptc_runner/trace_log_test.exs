defmodule PtcRunner.TraceLogTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog

  @moduletag :tmp_dir

  describe "start/1 and stop/1" do
    test "creates trace file and returns path", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = TraceLog.start(path: path)

      assert is_pid(collector)
      assert TraceLog.current_collector() == collector
      assert collector in TraceLog.active_collectors()

      {:ok, ^path, 0} = TraceLog.stop(collector)

      assert File.exists?(path)
      assert TraceLog.current_collector() == nil
      assert TraceLog.active_collectors() == []
    end

    test "uses custom trace_id", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = TraceLog.start(path: path, trace_id: "custom-123")

      {:ok, ^path, 0} = TraceLog.stop(collector)

      content = File.read!(path)
      [first_line | _] = String.split(content, "\n", trim: true)
      event = Jason.decode!(first_line)

      assert event["trace_id"] == "custom-123"
    end

    test "includes custom metadata", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = TraceLog.start(path: path, meta: %{user: "alice", env: "test"})

      {:ok, ^path, 0} = TraceLog.stop(collector)

      content = File.read!(path)
      [first_line | _] = String.split(content, "\n", trim: true)
      event = Jason.decode!(first_line)

      assert event["meta"]["user"] == "alice"
      assert event["meta"]["env"] == "test"
    end
  end

  describe "with_trace/2" do
    test "captures trace and returns result", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")

      {:ok, result, trace_path} =
        TraceLog.with_trace(fn -> {:computed, 42} end, path: path)

      assert result == {:computed, 42}
      assert trace_path == path
      assert File.exists?(path)
    end

    test "cleans up on exception", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")

      assert_raise RuntimeError, "test error", fn ->
        TraceLog.with_trace(fn -> raise "test error" end, path: path)
      end

      assert TraceLog.current_collector() == nil
      assert TraceLog.active_collectors() == []
      assert File.exists?(path)
    end

    test "supports nested traces", %{tmp_dir: dir} do
      outer_path = Path.join(dir, "outer.jsonl")
      inner_path = Path.join(dir, "inner.jsonl")

      {:ok, outer_result, outer_trace} =
        TraceLog.with_trace(
          fn ->
            # Nested trace
            {:ok, inner_result, inner_trace} =
              TraceLog.with_trace(
                fn -> {:inner, 100} end,
                path: inner_path
              )

            # After nested trace, outer should still work
            assert TraceLog.current_collector() != nil
            {:outer, inner_result, inner_trace}
          end,
          path: outer_path
        )

      assert outer_result == {:outer, {:inner, 100}, inner_path}
      assert outer_trace == outer_path

      # Both trace files should exist
      assert File.exists?(outer_path)
      assert File.exists?(inner_path)

      # After all traces complete, stack should be empty
      assert TraceLog.current_collector() == nil
      assert TraceLog.active_collectors() == []
    end

    test "nested trace events are isolated", %{tmp_dir: dir} do
      outer_path = Path.join(dir, "outer.jsonl")
      inner_path = Path.join(dir, "inner.jsonl")

      {:ok, _, _} =
        TraceLog.with_trace(
          fn ->
            # Emit telemetry for outer
            :telemetry.execute(
              [:ptc_runner, :sub_agent, :run, :start],
              %{},
              %{agent: %{name: "outer"}}
            )

            {:ok, _, _} =
              TraceLog.with_trace(
                fn ->
                  # Emit telemetry for inner
                  :telemetry.execute(
                    [:ptc_runner, :sub_agent, :run, :start],
                    %{},
                    %{agent: %{name: "inner"}}
                  )

                  :inner
                end,
                path: inner_path
              )

            # Emit more telemetry for outer (after inner completes)
            :telemetry.execute(
              [:ptc_runner, :sub_agent, :run, :stop],
              %{duration: 1000},
              %{agent: %{name: "outer"}}
            )

            :outer
          end,
          path: outer_path
        )

      # Check outer trace has outer events
      outer_content = File.read!(outer_path)
      outer_lines = String.split(outer_content, "\n", trim: true)

      # trace.start + 2 outer events (start and stop)
      # The inner event should also appear because inner collector is in the stack
      # when outer emits its first event
      assert length(outer_lines) >= 3

      # Check inner trace has inner event
      inner_content = File.read!(inner_path)
      inner_lines = String.split(inner_content, "\n", trim: true)

      # trace.start + inner run.start
      assert length(inner_lines) >= 2

      # Verify the inner trace contains the "inner" agent event
      inner_events = Enum.map(inner_lines, &Jason.decode!/1)

      assert Enum.any?(inner_events, fn e ->
               e["event"] == "run.start" &&
                 get_in(e, ["metadata", "agent", "name"]) == "inner"
             end)
    end

    test "isolates traces by process", %{tmp_dir: dir} do
      path1 = Path.join(dir, "trace1.jsonl")
      path2 = Path.join(dir, "trace2.jsonl")

      # Start trace in parent process
      {:ok, collector1} = TraceLog.start(path: path1)

      # Start trace in child process
      task =
        Task.async(fn ->
          {:ok, collector2} = TraceLog.start(path: path2)
          TraceLog.stop(collector2)
        end)

      Task.await(task)
      {:ok, ^path1, 0} = TraceLog.stop(collector1)

      # Both files should exist independently
      assert File.exists?(path1)
      assert File.exists?(path2)
    end
  end

  describe "current_collector/0" do
    test "returns nil when no trace is active" do
      assert TraceLog.current_collector() == nil
    end

    test "returns collector when trace is active", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = TraceLog.start(path: path)

      assert TraceLog.current_collector() == collector

      TraceLog.stop(collector)
      assert TraceLog.current_collector() == nil
    end
  end
end
