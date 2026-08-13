defmodule PtcRunner.TestSupport.TestHelpersTest do
  use ExUnit.Case, async: false

  import PtcRunner.TestSupport.TestHelpers,
    only: [environment_skip_reason: 1, executable_skip_reason: 1, stop_quietly: 1]

  describe "executable_skip_reason/1" do
    test "continues when every named executable is available" do
      refute executable_skip_reason(["elixir"])
    end

    test "returns a descriptive reason for unavailable executables" do
      missing = "ptc-test-executable-that-does-not-exist"
      expected = "optional E2E executables are not available on PATH: #{missing}"

      assert executable_skip_reason([missing]) == expected
    end
  end

  describe "environment_skip_reason/1" do
    setup do
      names = ["PTC_TEST_HELPER_PRESENT", "PTC_TEST_HELPER_MISSING"]
      original = Map.new(names, &{&1, System.fetch_env(&1)})

      on_exit(fn ->
        Enum.each(original, fn
          {name, {:ok, value}} -> System.put_env(name, value)
          {name, :error} -> System.delete_env(name)
        end)
      end)

      System.put_env("PTC_TEST_HELPER_PRESENT", "configured")
      System.delete_env("PTC_TEST_HELPER_MISSING")
      :ok
    end

    test "continues when every named variable is non-empty" do
      refute environment_skip_reason(["PTC_TEST_HELPER_PRESENT"])
    end

    test "returns a descriptive reason for missing and empty variables" do
      System.put_env("PTC_TEST_HELPER_PRESENT", "")

      assert "optional E2E prerequisites are not configured: " <>
               "PTC_TEST_HELPER_PRESENT, PTC_TEST_HELPER_MISSING" =
               environment_skip_reason([
                 "PTC_TEST_HELPER_PRESENT",
                 "PTC_TEST_HELPER_MISSING"
               ])
    end
  end

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
