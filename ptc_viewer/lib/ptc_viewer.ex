defmodule PtcViewer do
  @moduledoc """
  Local web UI for browsing canonical PTC traces and, when explicitly enabled
  by the host, running one bounded log-analysis REPL profile.
  """

  alias PtcViewer.ReplAdapter
  alias PtcViewer.Server

  @doc """
  Starts a loopback-only Viewer lifecycle.

  In addition to the read-only trace and inspection options, a host may provide
  `:repl_adapter` and opaque `:repl_config`. Supplying an invalid or failed REPL
  adapter fails startup; omission preserves the Runs-only Viewer.
  """
  def start(opts \\ [])

  def start(opts) when is_list(opts) do
    kernel_adapter = Keyword.get(opts, :kernel_trace_adapter)
    repl_adapter = Keyword.get(opts, :repl_adapter)

    with :ok <- valid_kernel_adapter(kernel_adapter),
         :ok <- ReplAdapter.validate(repl_adapter) do
      Server.start(opts)
    end
  end

  def start(_opts), do: {:error, :invalid_viewer_config}

  @doc "Stops traffic, drains accepted REPL work, and terminates the Viewer."
  def stop(pid), do: Server.stop(pid)

  @doc "Returns the loopback listener address and actual bound port."
  def listener_info(pid), do: Server.listener_info(pid)

  defp valid_kernel_adapter(nil), do: :ok
  defp valid_kernel_adapter(adapter) when is_function(adapter, 3), do: :ok

  defp valid_kernel_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :query, 3),
      do: :ok,
      else: {:error, :invalid_kernel_trace_adapter}
  end

  defp valid_kernel_adapter(_adapter), do: {:error, :invalid_kernel_trace_adapter}
end
