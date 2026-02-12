defmodule PtcRunner.TraceLog.CollectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias PtcRunner.TraceLog.Collector

  @moduletag :tmp_dir

  describe "start_link/1" do
    test "creates trace file at specified path", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      assert File.exists?(path)

      {:ok, ^path, 0} = Collector.stop(collector)
    end

    test "uses custom trace_id when provided", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, trace_id: "custom-trace-id")

      assert Collector.trace_id(collector) == "custom-trace-id"

      Collector.stop(collector)
    end

    test "generates trace_id if not provided", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      trace_id = Collector.trace_id(collector)
      assert is_binary(trace_id)
      assert byte_size(trace_id) == 32

      Collector.stop(collector)
    end

    test "creates parent directories if needed", %{tmp_dir: dir} do
      path = Path.join([dir, "nested", "deeply", "test.jsonl"])
      {:ok, collector} = Collector.start_link(path: path)

      assert File.exists?(path)

      Collector.stop(collector)
    end

    test "writes initial metadata event", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path, meta: %{user: "test"})

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      [first_line | _] = String.split(content, "\n", trim: true)
      event = Jason.decode!(first_line)

      assert event["event"] == "trace.start"
      assert event["meta"]["user"] == "test"
    end
  end

  describe "write/2" do
    test "writes JSON line to file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write(collector, ~s({"event":"test"}))

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # First line is trace.start, second is our test event, third is trace.stop
      assert length(lines) == 3
      assert Enum.at(lines, 1) == ~s({"event":"test"})
    end

    test "writes multiple lines in order", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write(collector, ~s({"n":1}))
      Collector.write(collector, ~s({"n":2}))
      Collector.write(collector, ~s({"n":3}))

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # First line is trace.start, last is trace.stop
      assert length(lines) == 5
      assert Jason.decode!(Enum.at(lines, 1))["n"] == 1
      assert Jason.decode!(Enum.at(lines, 2))["n"] == 2
      assert Jason.decode!(Enum.at(lines, 3))["n"] == 3
    end
  end

  describe "write_event/2" do
    test "encodes and writes event map", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write_event(collector, %{"event" => "test", "value" => 42})

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      last_event = Jason.decode!(Enum.at(lines, 1))

      assert last_event["event"] == "test"
      assert last_event["value"] == 42
    end
  end

  describe "stop/1" do
    test "returns path and error count", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      assert {:ok, ^path, 0} = Collector.stop(collector)
    end

    test "closes file properly", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write(collector, ~s({"test":true}))
      {:ok, ^path, 0} = Collector.stop(collector)

      # Should be able to read file after close
      content = File.read!(path)
      assert String.contains?(content, "test")
    end
  end

  describe "terminate/2 (F7)" do
    test "closes file handle on shutdown", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      # Write something before shutdown
      Collector.write(collector, ~s({"before":"shutdown"}))
      # Synchronize to ensure write is processed (regular call, not :sys)
      _ = Collector.trace_id(collector)

      # Unlink so :shutdown doesn't propagate to test process
      Process.unlink(collector)
      GenServer.stop(collector, :shutdown)

      # File should contain the data written before shutdown
      content = File.read!(path)
      assert String.contains?(content, "before")
    end

    test "flushes data on normal termination via stop", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write(collector, ~s({"data":"flushed"}))
      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      assert String.contains?(content, "flushed")
      assert String.contains?(content, "trace.stop")
    end
  end

  describe "write error logging (F8)" do
    test "logs warning on first write error, not on subsequent ones", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      # Kill the file device to make IO.puts fail on next write
      state = :sys.get_state(collector)
      Process.exit(state.file, :kill)

      # Temporarily lower the primary logger level (ExUnit sets it to :critical)
      # and install a custom handler to capture log events from the collector
      test_pid = self()
      handler_id = :"test_log_capture_#{System.unique_integer([:positive])}"
      prev_config = :logger.get_primary_config()
      :logger.set_primary_config(:level, :all)
      :logger.add_handler(handler_id, __MODULE__.LogForwarder, %{test_pid: test_pid})

      try do
        # First write triggers rescue → logs warning → sets file to nil
        Collector.write(collector, ~s({"will":"fail"}))
        _ = Collector.trace_id(collector)

        assert_receive {:log_event, :warning, msg}
        assert msg =~ "Trace collector write failed"

        # Second write hits file: nil clause → increments errors, no log
        Collector.write(collector, ~s({"also":"fails"}))
        _ = Collector.trace_id(collector)

        # Drain mailbox and check no "Trace collector" warnings were emitted
        # (other warnings from concurrent tests may arrive due to global handler)
        refute_received({:log_event, :warning, "Trace collector" <> _})

        state_after = :sys.get_state(collector)
        assert state_after.file == nil
        assert state_after.write_errors == 2
      after
        :logger.remove_handler(handler_id)
        :logger.set_primary_config(:level, prev_config.level)
      end
    end
  end

  describe "IO device crash handling (F10)" do
    test "sets file to nil after IO device crash, stops repeated failures", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      # Kill the file device process
      state = :sys.get_state(collector)
      Process.exit(state.file, :kill)

      # Suppress the expected log warning from the first failed write
      capture_log(fn ->
        Collector.write(collector, ~s({"will":"fail"}))
        _ = Collector.trace_id(collector)
      end)

      # Subsequent writes should be handled gracefully (no crash, no exceptions)
      Collector.write(collector, ~s({"also":"fails"}))
      Collector.write(collector, ~s({"still":"fails"}))
      # Synchronize to ensure casts are processed
      state_after = :sys.get_state(collector)

      assert state_after.file == nil
      assert state_after.write_errors == 3
    end

    test "stop reports accumulated write errors after IO crash", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      # Kill the file device process
      state = :sys.get_state(collector)
      Process.exit(state.file, :kill)

      # Suppress the expected log warning
      capture_log(fn ->
        Collector.write(collector, ~s({"will":"fail"}))
        _ = Collector.trace_id(collector)
      end)

      Collector.write(collector, ~s({"also":"fails"}))
      # Synchronize to ensure cast is processed
      _ = Collector.trace_id(collector)

      {:ok, ^path, errors} = Collector.stop(collector)
      assert errors == 2
    end
  end

  # Erlang :logger handler that forwards log events to a test process
  defmodule LogForwarder do
    @moduledoc false

    def log(%{level: level, msg: msg}, %{test_pid: test_pid}) do
      message =
        case msg do
          {:string, str} -> IO.iodata_to_binary(str)
          {:report, report} -> inspect(report)
          {fmt, args} -> :io_lib.format(fmt, args) |> IO.iodata_to_binary()
        end

      send(test_pid, {:log_event, level, message})
    end
  end
end
