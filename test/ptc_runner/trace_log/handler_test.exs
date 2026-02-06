defmodule PtcRunner.TraceLog.HandlerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.{Collector, Handler}

  @moduletag :tmp_dir

  describe "attach/4 and detach/1" do
    test "attaches and detaches without error", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      handler_id = "test-handler-#{System.unique_integer([:positive])}"
      assert :ok = Handler.attach(handler_id, collector, "trace-123")
      assert :ok = Handler.detach(handler_id)

      Collector.stop(collector)
    end

    test "attach fails if handler_id already exists", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      handler_id = "test-handler-#{System.unique_integer([:positive])}"
      assert :ok = Handler.attach(handler_id, collector, "trace-123")
      assert {:error, :already_exists} = Handler.attach(handler_id, collector, "trace-123")

      Handler.detach(handler_id)
      Collector.stop(collector)
    end
  end

  describe "handle_event/4" do
    test "captures events when collector is in process dictionary stack", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "test-trace")

      # Register collector in process dictionary stack
      Process.put(:ptc_trace_collectors, [collector])

      config = %{collector: collector, trace_id: "test-trace", meta: %{}}

      # Emit a test event
      Handler.handle_event(
        [:ptc_runner, :sub_agent, :run, :start],
        %{},
        %{agent: %{name: "test-agent"}},
        config
      )

      # Give collector time to process
      Process.sleep(10)

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # First line is trace.start, second is our event, third is trace.stop
      assert length(lines) == 3

      event = Jason.decode!(Enum.at(lines, 1))
      assert event["event"] == "run.start"
      assert event["trace_id"] == "test-trace"
    after
      Process.delete(:ptc_trace_collectors)
    end

    test "ignores events when collector not in stack", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "test-trace")

      # Different collector in process dictionary stack
      {:ok, other_collector} = Collector.start_link(path: Path.join(dir, "other.jsonl"))
      Process.put(:ptc_trace_collectors, [other_collector])

      config = %{collector: collector, trace_id: "test-trace", meta: %{}}

      # Emit a test event
      Handler.handle_event(
        [:ptc_runner, :sub_agent, :run, :start],
        %{},
        %{agent: %{name: "test-agent"}},
        config
      )

      Process.sleep(10)

      {:ok, ^path, 0} = Collector.stop(collector)
      Collector.stop(other_collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # trace.start + trace.stop (no captured events since collector wasn't in stack)
      assert length(lines) == 2
    after
      Process.delete(:ptc_trace_collectors)
    end

    test "captures events when collector is nested in stack", %{tmp_dir: dir} do
      path1 = Path.join(dir, "outer.jsonl")
      path2 = Path.join(dir, "inner.jsonl")
      {:ok, outer_collector} = Collector.start_link(path: path1, trace_id: "outer-trace")
      {:ok, inner_collector} = Collector.start_link(path: path2, trace_id: "inner-trace")

      # Both collectors in stack (inner is first/top)
      Process.put(:ptc_trace_collectors, [inner_collector, outer_collector])

      # Event for outer collector should be captured even though inner is on top
      outer_config = %{collector: outer_collector, trace_id: "outer-trace", meta: %{}}

      Handler.handle_event(
        [:ptc_runner, :sub_agent, :run, :start],
        %{},
        %{agent: %{name: "outer-agent"}},
        outer_config
      )

      Process.sleep(10)

      {:ok, ^path1, 0} = Collector.stop(outer_collector)
      Collector.stop(inner_collector)

      content = File.read!(path1)
      lines = String.split(content, "\n", trim: true)
      # trace.start + our event + trace.stop
      assert length(lines) == 3

      event = Jason.decode!(Enum.at(lines, 1))
      assert event["event"] == "run.start"
      assert event["trace_id"] == "outer-trace"
    after
      Process.delete(:ptc_trace_collectors)
    end

    test "adds duration_ms from measurements", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "test-trace")

      Process.put(:ptc_trace_collectors, [collector])

      config = %{collector: collector, trace_id: "test-trace", meta: %{}}

      # Duration in native time units (1 second)
      duration = System.convert_time_unit(1000, :millisecond, :native)

      Handler.handle_event(
        [:ptc_runner, :sub_agent, :run, :stop],
        %{duration: duration},
        %{agent: %{name: "test"}},
        config
      )

      Process.sleep(10)

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      event = Jason.decode!(Enum.at(lines, 1))

      assert event["duration_ms"] == 1000
    after
      Process.delete(:ptc_trace_collectors)
    end

    test "adds span_id and parent_span_id from metadata", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "test-trace")

      Process.put(:ptc_trace_collectors, [collector])

      config = %{collector: collector, trace_id: "test-trace", meta: %{}}

      Handler.handle_event(
        [:ptc_runner, :sub_agent, :tool, :start],
        %{},
        %{span_id: "span-123", parent_span_id: "parent-456", tool_name: "test"},
        config
      )

      Process.sleep(10)

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      event = Jason.decode!(Enum.at(lines, 1))

      assert event["span_id"] == "span-123"
      assert event["parent_span_id"] == "parent-456"
    after
      Process.delete(:ptc_trace_collectors)
    end

    test "never crashes caller even on error", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "test-trace")

      # Stop collector immediately to cause write errors
      Collector.stop(collector)

      config = %{collector: collector, trace_id: "test-trace", meta: %{}}

      # This should not raise even though collector is stopped
      assert :ok =
               Handler.handle_event(
                 [:ptc_runner, :sub_agent, :run, :start],
                 %{},
                 %{agent: %{name: "test"}},
                 config
               )
    end
  end

  describe "events/0" do
    test "returns list of telemetry events" do
      events = Handler.events()

      # Check that known events are included
      assert [:ptc_runner, :sub_agent, :run, :start] in events
      assert [:ptc_runner, :sub_agent, :run, :stop] in events
      assert [:ptc_runner, :sub_agent, :llm, :start] in events
      assert [:ptc_runner, :sub_agent, :tool, :stop] in events
    end
  end
end
