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

  @doc """
  Wait until `dir` contains at least `expected` completed JSONL trace files.
  """
  @spec wait_for_files(Path.t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def wait_for_files(dir, expected, timeout_ms \\ 1_000)
      when is_binary(dir) and is_integer(expected) and expected >= 0 and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_files(dir, expected, deadline)
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

  defp do_wait_for_files(dir, expected, deadline) do
    files =
      dir
      |> File.ls!()
      |> Enum.reject(&String.ends_with?(&1, ".pending"))
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.sort()

    cond do
      length(files) >= expected ->
        files

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected at least #{expected} jsonl files in #{dir}; got #{length(files)}")

      true ->
        receive do
        after
          10 -> do_wait_for_files(dir, expected, deadline)
        end
    end
  end
end
