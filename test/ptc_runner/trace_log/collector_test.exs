defmodule PtcRunner.TraceLog.CollectorTest do
  use ExUnit.Case, async: true

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
      # First line is metadata, second is our test event
      assert length(lines) == 2
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
      # First line is metadata
      assert length(lines) == 4
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
end
