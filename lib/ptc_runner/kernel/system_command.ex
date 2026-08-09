defmodule PtcRunner.Kernel.SystemCommand do
  @moduledoc false

  alias PtcRunner.Kernel.BoundedWorker

  @max_heap_words 100_000

  @type error :: :timeout | :cancelled | :heap_exceeded | :worker_failed

  @spec run(binary(), [binary()], pos_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, error()}
  def run(executable, arguments, timeout_ms)
      when is_binary(executable) and is_list(arguments) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    BoundedWorker.run(
      fn -> System.cmd(executable, arguments, stderr_to_stdout: true) end,
      timeout_ms: timeout_ms,
      max_heap_words: @max_heap_words,
      cancel_with_caller: true
    )
  end
end
