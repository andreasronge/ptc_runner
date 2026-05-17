defmodule PtcRunnerMcp.TestSupport.WaitHelpers do
  @moduledoc """
  Polling helpers for asynchronous MCP tests.
  """

  import ExUnit.Assertions

  @doc """
  Wait until `fun` returns truthy, or fail after `timeout_ms`.
  """
  @spec wait_until((-> as_boolean(term())), non_neg_integer()) :: :ok
  def wait_until(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        receive do
        after
          10 -> do_wait_until(fun, deadline)
        end
    end
  end
end
