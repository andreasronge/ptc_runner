defmodule PtcRunner.TraceLog.CollectorTest do
  # async: false: tests both attach a global `:logger` handler and rely
  # on tight `assert_receive` timings around spawn/kill behaviour.
  # Under async: true heavy parallel load steals scheduler time and
  # surfaces as 1-in-N flakes.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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
      assert event["schema_version"] == 2
      assert event["seq"] == 0
      assert event["data"]["user"] == "test"
    end
  end

  describe "write_event/2" do
    test "writes event map as JSON line to file", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write_event(collector, %{"event" => "test"})

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # First line is trace.start, second is our test event, third is trace.stop
      assert length(lines) == 3
      decoded = Jason.decode!(Enum.at(lines, 1))
      assert decoded["event"] == "test"
      assert is_integer(decoded["seq"])
    end

    test "writes multiple events in order", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      {:ok, collector} = Collector.start_link(path: path)

      Collector.write_event(collector, %{"n" => 1})
      Collector.write_event(collector, %{"n" => 2})
      Collector.write_event(collector, %{"n" => 3})

      {:ok, ^path, 0} = Collector.stop(collector)

      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      # First line is trace.start, last is trace.stop
      assert length(lines) == 5
      assert Jason.decode!(Enum.at(lines, 1))["n"] == 1
      assert Jason.decode!(Enum.at(lines, 2))["n"] == 2
      assert Jason.decode!(Enum.at(lines, 3))["n"] == 3
    end

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

    test "summarizes events that exceed the encoded event byte cap", %{tmp_dir: dir} do
      with_app_env(:trace_collector_max_event_bytes, 768, fn ->
        path = Path.join(dir, "test.jsonl")
        {:ok, collector} = Collector.start_link(path: path)

        Collector.write_event(collector, %{
          "event" => "huge.payload",
          "agent_id" => "agent-1",
          "data" => %{"payload" => String.duplicate("x", 4_096)}
        })

        {:ok, ^path, 0} = Collector.stop(collector)

        [_start, omitted, _stop] = decoded_lines(path)

        assert omitted["event"] == "trace.event_omitted"
        assert omitted["agent_id"] == "agent-1"
        assert is_binary(omitted["trace_id"])
        assert is_binary(omitted["timestamp"])
        assert is_integer(omitted["seq"])
        assert omitted["data"]["reason"] == "trace_event_too_large"
        assert omitted["data"]["original_event"] == "huge.payload"
        assert omitted["data"]["original_bytes"] > 768
        refute inspect(omitted) =~ String.duplicate("x", 128)
      end)
    end

    test "splits oversized agent_config before bounding the main event", %{tmp_dir: dir} do
      with_app_env(:trace_collector_max_event_bytes, 768, fn ->
        path = Path.join(dir, "test.jsonl")
        {:ok, collector} = Collector.start_link(path: path)

        Collector.write_event(collector, %{
          "event" => "run.start",
          "agent_id" => "agent-1",
          "agent_name" => "planner",
          "data" => %{
            "small" => true,
            "agent_config" => %{"system_prompt" => String.duplicate("x", 4_096)}
          }
        })

        {:ok, ^path, 0} = Collector.stop(collector)

        [_start, config, run_start, _stop] = decoded_lines(path)

        assert config["event"] == "agent.config"
        assert config["agent_id"] == "agent-1"
        assert config["config"]["omitted"] == true
        assert config["config"]["reason"] == "agent_config_too_large"

        assert run_start["event"] == "run.start"
        assert run_start["data"] == %{"small" => true}
      end)
    end

    test "applies event byte cap after adding collector fields", %{tmp_dir: dir} do
      with_app_env(:trace_collector_max_event_bytes, 512, fn ->
        path = Path.join(dir, "test.jsonl")
        {:ok, collector} = Collector.start_link(path: path)

        Collector.write_event(collector, %{
          "event" => "boundary.payload",
          "data" => %{"payload" => String.duplicate("x", 420)}
        })

        {:ok, ^path, 0} = Collector.stop(collector)

        [_start, bounded, _stop] = decoded_lines(path)

        assert bounded["event"] == "trace.event_omitted"
        assert bounded["data"]["original_event"] == "boundary.payload"

        line =
          path
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.at(1)

        assert byte_size(line) <= 512
      end)
    end

    test "drops oversized events when the summary cannot fit the byte cap", %{tmp_dir: dir} do
      with_app_env(:trace_collector_max_event_bytes, 64, fn ->
        path = Path.join(dir, "test.jsonl")
        {:ok, collector} = Collector.start_link(path: path)

        Collector.write_event(collector, %{
          "event" => "huge.payload",
          "data" => %{"payload" => String.duplicate("x", 4_096)}
        })

        {:ok, ^path, 0} = Collector.stop(collector)

        assert [%{"event" => "trace.start"}, %{"event" => "trace.stop"}] = decoded_lines(path)
      end)
    end

    test "sheds events before enqueueing when collector mailbox is at the cap", %{tmp_dir: dir} do
      with_app_env(:trace_collector_max_mailbox_len, 0, fn ->
        path = Path.join(dir, "test.jsonl")
        {:ok, collector} = Collector.start_link(path: path)

        Collector.write_event(collector, %{"event" => "shed"})

        {:ok, ^path, 0} = Collector.stop(collector)

        assert [%{"event" => "trace.start"}, %{"event" => "trace.stop"}] = decoded_lines(path)
      end)
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

      Collector.write_event(collector, %{"test" => true})
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
      Collector.write_event(collector, %{"before" => "shutdown"})
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

      Collector.write_event(collector, %{"data" => "flushed"})
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
        Collector.write_event(collector, %{"will" => "fail"})
        _ = Collector.trace_id(collector)

        assert_receive {:log_event, :warning, msg}
        assert msg =~ "Trace collector write failed"

        # Second write hits file: nil clause → increments errors, no log
        Collector.write_event(collector, %{"also" => "fails"})
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
        Collector.write_event(collector, %{"will" => "fail"})
        _ = Collector.trace_id(collector)
      end)

      # Subsequent writes should be handled gracefully (no crash, no exceptions)
      Collector.write_event(collector, %{"also" => "fails"})
      Collector.write_event(collector, %{"still" => "fails"})
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
        Collector.write_event(collector, %{"will" => "fail"})
        _ = Collector.trace_id(collector)
      end)

      Collector.write_event(collector, %{"also" => "fails"})
      # Synchronize to ensure cast is processed
      _ = Collector.trace_id(collector)

      {:ok, ^path, errors} = Collector.stop(collector)
      assert errors == 2
    end
  end

  describe "configurable trace directory" do
    test "uses configured :trace_dir for default path", %{tmp_dir: dir} do
      trace_dir = Path.join(dir, "custom_traces")
      Application.put_env(:ptc_runner, :trace_dir, trace_dir)

      try do
        {:ok, collector} = Collector.start_link()
        path = Collector.path(collector)

        assert String.starts_with?(path, trace_dir)
        assert String.ends_with?(path, ".jsonl")
        assert File.exists?(path)

        Collector.stop(collector)
      after
        Application.delete_env(:ptc_runner, :trace_dir)
      end
    end

    test "uses CWD when :trace_dir is not configured", %{tmp_dir: _dir} do
      Application.delete_env(:ptc_runner, :trace_dir)

      {:ok, collector} = Collector.start_link()
      path = Collector.path(collector)

      # Default path is just a filename (relative to CWD, no directory prefix)
      refute String.contains?(Path.basename(path), "/")
      assert String.starts_with?(Path.basename(path), "trace_")

      Collector.stop(collector)
      File.rm(path)
    end

    test "creates trace_dir if it doesn't exist", %{tmp_dir: dir} do
      trace_dir = Path.join([dir, "new", "nested", "dir"])
      Application.put_env(:ptc_runner, :trace_dir, trace_dir)

      try do
        {:ok, collector} = Collector.start_link()
        path = Collector.path(collector)

        assert File.dir?(trace_dir)
        assert File.exists?(path)

        Collector.stop(collector)
      after
        Application.delete_env(:ptc_runner, :trace_dir)
      end
    end
  end

  describe "parent process killed (Task.async_stream :kill_task)" do
    test "collector closes file cleanly when parent is killed", %{tmp_dir: dir} do
      path = Path.join(dir, "test.jsonl")
      test_pid = self()

      # Simulate Task.async_stream with on_timeout: :kill_task.
      # The task spawns a Collector via start_link, then gets killed by the stream timeout.
      # Before the fix, this caused:
      #   GenServer #PID<...> terminating
      #   ** (stop) killed
      #   Last message: {:EXIT, #PID<...>, :killed}
      results =
        [1]
        |> Task.async_stream(
          fn _ ->
            {:ok, collector} = Collector.start_link(path: path)
            send(test_pid, {:collector, collector})

            # Simulate long-running work that exceeds the timeout
            Process.sleep(:infinity)
          end,
          # 200 ms (up from 50 ms) gives the spawned task enough scheduler
          # time under heavy parallel test load to reach the `send/2`
          # call before getting killed; `:infinity` sleep still
          # guarantees the kill fires at the timeout. Without this the
          # task can be killed before the spawn lands, the
          # `{:collector, _}` message never arrives, and `assert_receive`
          # below times out — surfaces as a 1-in-N flake.
          timeout: 200,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      # Task was killed
      assert [{:exit, :timeout}] = results

      # Get the collector PID and wait for it to shut down cleanly.
      # Default `assert_receive` timeout of 100 ms is too tight under
      # heavy parallel-suite load; 5 s is plenty.
      assert_receive {:collector, collector}, 5_000
      ref = Process.monitor(collector)
      assert_receive {:DOWN, ^ref, :process, ^collector, :normal}, 5_000

      # Trace file should contain valid data (trace.start + trace.stop)
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) >= 2

      event_types = Enum.map(lines, fn line -> Jason.decode!(line)["event"] end)
      assert "trace.start" in event_types
      assert "trace.stop" in event_types
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

  defp decoded_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp with_app_env(key, value, fun) do
    previous = Application.get_env(:ptc_runner, key)
    Application.put_env(:ptc_runner, key, value)

    try do
      fun.()
    after
      if is_nil(previous) do
        Application.delete_env(:ptc_runner, key)
      else
        Application.put_env(:ptc_runner, key, previous)
      end
    end
  end
end
