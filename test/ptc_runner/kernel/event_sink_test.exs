defmodule PtcRunner.Kernel.EventSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits

  test "default run identifiers have fixed entropy format and remain unique" do
    {:ok, limits} = Limits.new(normal_event_count: 4, normal_event_bytes: 10_000)

    ids =
      for _ <- 1..64 do
        {:ok, sink} = EventSink.start(:normal, limits)
        :ok = EventSink.emit(sink, "run-started", %{})
        [event] = EventSink.events(sink)
        event.run_id
      end

    assert Enum.uniq(ids) == ids
    assert Enum.all?(ids, &Regex.match?(~r/\Arun-[0-9a-f]{12}\z/, &1))
  end
end
