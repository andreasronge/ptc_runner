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
    * `:inspection_adapter` - Required host module implementing
      `pin_inspection/2` and `inspection/2` when an artifact is configured
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
         {:ok, inspection_store} <-
           pin_inspection(inspection_file, inspection_adapter, trace_dir) do
      config =
        [trace_dir: Path.expand(trace_dir), kernel_trace_adapter: kernel_trace_adapter]
        |> maybe_put(:inspection_store, inspection_store)
        |> maybe_put(:inspection_adapter, inspection_adapter)

      result =
        Bandit.start_link(plug: {PtcViewer.Router, config}, port: port, ip: {127, 0, 0, 1})

      attach_inspection_store(result, inspection_store)

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

  defp pin_inspection(nil, nil, _trace_dir), do: {:ok, nil}

  defp pin_inspection(path, nil, _trace_dir) when is_binary(path),
    do: {:error, :invalid_inspection_config}

  defp pin_inspection(path, adapter, trace_dir) when is_binary(path) and is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :pin_inspection, 2) and
         function_exported?(adapter, :inspection, 2) do
      with {:ok, source} <-
             adapter
             |> apply(:pin_inspection, [Path.expand(path), {:directory, Path.expand(trace_dir)}])
             |> normalize_pin_result(),
           {:ok, store} <- PtcViewer.InspectionStore.start(source) do
        {:ok, store}
      end
    else
      {:error, :invalid_inspection_adapter}
    end
  rescue
    _exception -> {:error, :inspection_adapter_failure}
  catch
    _kind, _reason -> {:error, :inspection_adapter_failure}
  end

  defp pin_inspection(_path, _adapter, _trace_dir), do: {:error, :invalid_inspection_config}

  defp normalize_pin_result({:ok, source}) when not is_nil(source), do: {:ok, source}
  defp normalize_pin_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_pin_result(_invalid), do: {:error, :inspection_adapter_failure}

  defp attach_inspection_store({:ok, viewer}, store) when is_pid(store) do
    :ok = PtcViewer.InspectionStore.attach(store, viewer)
  end

  defp attach_inspection_store({:error, _reason}, store) when is_pid(store),
    do: PtcViewer.InspectionStore.stop(store)

  defp attach_inspection_store(_result, nil), do: :ok

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
