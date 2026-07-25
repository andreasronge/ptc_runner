defmodule PtcRunner.Kernel.RunBuilderClassTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunBuilder

  setup do
    {:ok, limits} = Limits.new([])
    {:ok, limits: limits}
  end

  test "a normal sink yields a publishable class", %{limits: limits} do
    {:ok, sink} = EventSink.start(:normal, limits)
    on_exit(fn -> if Process.alive?(sink.pid), do: EventSink.stop(sink) end)

    assert RunBuilder.result_class(sink) == :normal
  end

  test "a private sink yields a private class", %{limits: limits} do
    {:ok, sink} = EventSink.start(:private, limits)
    on_exit(fn -> if Process.alive?(sink.pid), do: EventSink.stop(sink) end)

    assert RunBuilder.result_class(sink) == :private
  end

  # Classification decides whether a value may be printed, so an unreadable
  # policy must never resolve to the publishable class. `EventSink.policy/1`
  # returns an error tuple once its process is gone.
  test "an unreachable sink fails closed rather than publishing", %{limits: limits} do
    {:ok, sink} = EventSink.start(:private, limits)
    reference = Process.monitor(sink.pid)
    EventSink.stop(sink)
    assert_receive {:DOWN, ^reference, :process, _pid, _reason}

    refute EventSink.policy(sink) == :normal
    assert RunBuilder.result_class(sink) == :private
  end
end
