defmodule PtcRunnerMcp.McpTestHelpers do
  @moduledoc """
  Shared helpers for `PtcRunnerMcp` tests.

  Extracted (issue #928) to consolidate the `stop_existing_registry`
  helper that was previously copy-pasted across ~13 test files. Each
  test file historically defined its own private `defp` clone of the
  same kill-and-monitor pattern keyed off a `@registry_name` module
  attribute.

  ## When to use this module versus inline cleanup

  Most aggregator/catalog/agentic tests use a single named
  `Upstream.Registry` GenServer per test module, so a single call to
  `stop_existing_registry/2` in a `setup` block (or before
  `start_supervised!/2`) is enough.

  Tests that own additional resources (stdio subprocesses, fake
  upstream pids, Finch supervision trees, etc.) should call those
  cleanup helpers first and then call `stop_existing_registry/2`.
  See `test/integration/real_filesystem_test.exs` for an example that
  composes a different shutdown sequence.
  """

  @doc """
  Kill the named registry GenServer if it is running, waiting up to
  `timeout` ms for the process to exit.

  Returns `:ok` whether the registry was running or not. Idempotent.
  """
  @spec stop_existing_registry(atom() | pid(), non_neg_integer()) :: :ok
  def stop_existing_registry(registry_name, timeout \\ 1_000)

  def stop_existing_registry(registry_name, timeout) when is_atom(registry_name) do
    case Process.whereis(registry_name) do
      nil -> :ok
      pid -> stop_existing_registry(pid, timeout)
    end
  end

  def stop_existing_registry(pid, timeout) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> :ok
    end
  end
end
