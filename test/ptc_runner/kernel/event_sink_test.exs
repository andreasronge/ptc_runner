defmodule PtcRunner.Kernel.EventSinkTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits

  test "default run identifiers are safe to mix across separate CLI invocations" do
    {:ok, limits} = Limits.new(normal_event_count: 4, normal_event_bytes: 10_000)

    ids =
      for _ <- 1..64 do
        {:ok, sink} = EventSink.start(:normal, limits)
        :ok = EventSink.emit(sink, "run-started", %{})
        [event] = EventSink.events(sink)
        event.run_id
      end

    assert Enum.uniq(ids) == ids

    # A VM-local counter ("run-<integer>") restarts on every CLI invocation,
    # so traces written by separate invocations into one directory collide on
    # run identity and Kernel.TraceLog fail-closes the whole directory source.
    # The default must therefore carry entropy, never just the counter.
    refute Enum.any?(ids, &Regex.match?(~r/\Arun-\d+\z/, &1))
  end
end
