defmodule PtcRunner.TestSupport.TestHelpersTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers, only: [stop_quietly: 1]

  describe "stop_quietly/1" do
    test "stops a live process" do
      {:ok, pid} = Agent.start(fn -> [] end)
      assert :ok = stop_quietly(pid)
      refute Process.alive?(pid)
    end

    test "tolerates an already-dead pid (the teardown race it exists to absorb)" do
      {:ok, pid} = Agent.start(fn -> [] end)
      :ok = Agent.stop(pid)
      refute Process.alive?(pid)

      # The racy `if Process.alive?(pid), do: GenServer.stop(pid)` would exit
      # :noproc here when the pid dies between the check and the stop; this must
      # not raise or exit.
      assert :ok = stop_quietly(pid)
    end

    test "is a no-op on a non-pid value" do
      assert :ok = stop_quietly(nil)
    end
  end
end
