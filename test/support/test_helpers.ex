defmodule PtcRunner.TestSupport.TestHelpers do
  @moduledoc """
  Shared test helper functions used across multiple test files.
  """

  @doc "Dummy tool that ignores name and args and returns :ok"
  def dummy_tool(_name, _args), do: :ok

  @doc """
  Stops a process (Agent/GenServer) started in test setup, tolerating the
  teardown race. A `start_link`-ed process dies with the test process, which can
  race `on_exit`: `if Process.alive?(pid), do: GenServer.stop(pid)` is a TOCTOU —
  the pid can read alive and then exit `:noproc` before the stop lands. This
  swallows that exit and is a no-op on an already-dead pid or non-pid value.
  """
  def stop_quietly(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  def stop_quietly(_), do: :ok
end
