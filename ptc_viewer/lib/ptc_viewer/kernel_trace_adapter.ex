defmodule PtcViewer.KernelTraceAdapter do
  @moduledoc "Host adapter contract for canonical source-scoped Kernel trace queries."

  @type operation :: :list_runs | :get_run | :list_turns | :counters
  @callback query({:directory, binary()}, operation(), map()) ::
              {:ok, map()} | {:error, atom()}
end
