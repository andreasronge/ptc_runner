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
    * `:inspection_file` - Optional exact `.inspection.jsonl` artifact path
    * `:inspection_adapter` - Required host module/function when an inspection
      artifact is configured
    * `:open` - Whether to auto-open the browser (default: true)
  """
  def start(opts \\ []) do
    port = Keyword.get(opts, :port, 4123)
    trace_dir = Keyword.get(opts, :trace_dir, "traces")
    kernel_trace_adapter = Keyword.get(opts, :kernel_trace_adapter)
    inspection_file = Keyword.get(opts, :inspection_file)
    inspection_adapter = Keyword.get(opts, :inspection_adapter)
    open = Keyword.get(opts, :open, true)

    with :ok <- valid_kernel_adapter(kernel_trace_adapter),
         :ok <- valid_inspection_config(inspection_file, inspection_adapter) do
      config =
        [trace_dir: Path.expand(trace_dir), kernel_trace_adapter: kernel_trace_adapter]
        |> maybe_put(:inspection_file, inspection_file && Path.expand(inspection_file))
        |> maybe_put(:inspection_adapter, inspection_adapter)

      result =
        Bandit.start_link(plug: {PtcViewer.Router, config}, port: port, ip: {127, 0, 0, 1})

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

  defp valid_kernel_adapter(nil), do: :ok
  defp valid_kernel_adapter(adapter) when is_function(adapter, 3), do: :ok

  defp valid_kernel_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :query, 3),
      do: :ok,
      else: {:error, :invalid_kernel_trace_adapter}
  end

  defp valid_kernel_adapter(_adapter), do: {:error, :invalid_kernel_trace_adapter}

  defp valid_inspection_config(nil, nil), do: :ok

  defp valid_inspection_config(path, nil) when is_binary(path),
    do: {:error, :invalid_inspection_config}

  defp valid_inspection_config(path, adapter)
       when is_binary(path) and is_function(adapter, 2),
       do: :ok

  defp valid_inspection_config(path, adapter) when is_binary(path) and is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :inspection, 2),
      do: :ok,
      else: {:error, :invalid_inspection_adapter}
  end

  defp valid_inspection_config(_path, _adapter), do: {:error, :invalid_inspection_config}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
