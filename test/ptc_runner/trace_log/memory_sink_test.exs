defmodule PtcRunner.TraceLog.MemorySinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.TraceLog.MemorySink

  defp start_sink(opts \\ []) do
    {:ok, sink} = MemorySink.start_link(opts)
    on_exit(fn -> if Process.alive?(sink), do: GenServer.stop(sink) end)
    sink
  end

  test "records events and returns them chronologically (oldest first)" do
    sink = start_sink()

    MemorySink.record(sink, %{"event" => "turn", "n" => 1})
    MemorySink.record(sink, %{"event" => "turn", "n" => 2})
    MemorySink.record(sink, %{"event" => "turn", "n" => 3})

    events = MemorySink.events(sink)
    assert Enum.map(events, & &1["n"]) == [1, 2, 3]
    assert MemorySink.count(sink) == 3
  end

  test "stamps a monotonic seq and a timestamp when absent" do
    sink = start_sink()

    MemorySink.record(sink, %{"event" => "turn"})
    MemorySink.record(sink, %{"event" => "turn", "timestamp" => "preset"})

    [first, second] = MemorySink.events(sink)
    assert first["seq"] == 1
    assert is_binary(first["timestamp"])
    assert second["seq"] == 2
    # An explicitly-set timestamp is preserved.
    assert second["timestamp"] == "preset"
  end

  test "evicts oldest events when over the byte budget (ring buffer)" do
    # Each event encodes to well over 50 bytes, so a tiny budget keeps only the
    # most recent few.
    sink = start_sink(max_bytes: 200)

    for n <- 1..50 do
      MemorySink.record(sink, %{"event" => "turn", "n" => n, "pad" => String.duplicate("x", 40)})
    end

    events = MemorySink.events(sink)
    ns = Enum.map(events, & &1["n"])

    # The newest events survive; the oldest were evicted.
    assert List.last(ns) == 50
    assert length(events) < 50
    assert Enum.min(ns) > 1
    # Order is preserved among survivors.
    assert ns == Enum.sort(ns)
  end

  test "retains a single event even when it alone exceeds the budget" do
    sink = start_sink(max_bytes: 1)

    MemorySink.record(sink, %{"event" => "turn", "pad" => String.duplicate("x", 100)})

    assert MemorySink.count(sink) == 1
  end

  test "clear/1 drops all retained events" do
    sink = start_sink()
    MemorySink.record(sink, %{"event" => "turn"})
    MemorySink.clear(sink)

    assert MemorySink.events(sink) == []
    assert MemorySink.count(sink) == 0
  end
end
