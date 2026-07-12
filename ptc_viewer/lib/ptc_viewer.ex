defmodule PtcViewer do
  @moduledoc """
  PTC Trace Viewer — a web UI for browsing PTC traces.

  ## Usage

      {:ok, pid} = PtcViewer.start(port: 4123, trace_dir: "traces")
      PtcViewer.stop(pid)
  """

  @doc """
  Starts the PTC Viewer web server.

  ## Options

    * `:port` - Port to listen on (default: 4123)
    * `:trace_dir` - Directory containing .jsonl trace files (default: "traces")
    * `:kernel_trace_adapter` - Optional host module/function implementing the
      shared canonical Kernel trace query contract
    * `:open` - Whether to auto-open the browser (default: true)
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 4123)
    trace_dir = Keyword.get(opts, :trace_dir, "traces")
    kernel_trace_adapter = Keyword.get(opts, :kernel_trace_adapter)
    open = Keyword.get(opts, :open, true)

    with :ok <- valid_adapter(kernel_trace_adapter) do
      config = [trace_dir: Path.expand(trace_dir), kernel_trace_adapter: kernel_trace_adapter]
      result = Bandit.start_link(plug: {PtcViewer.Router, config}, port: port)

      if open && match?({:ok, _}, result) do
        System.cmd("open", ["http://localhost:#{port}"])
      end

      result
    end
  end

  @doc "Stops the PTC Viewer web server."
  def stop(pid) do
    Supervisor.stop(pid)
  end

  defp valid_adapter(nil), do: :ok
  defp valid_adapter(adapter) when is_function(adapter, 3), do: :ok

  defp valid_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :query, 3),
      do: :ok,
      else: {:error, :invalid_kernel_trace_adapter}
  end

  defp valid_adapter(_adapter), do: {:error, :invalid_kernel_trace_adapter}
end
