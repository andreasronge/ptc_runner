defmodule PtcViewer.Api do
  @moduledoc "Read-only host-delegated canonical trace API."

  @operations [:list_runs, :get_run, :list_turns, :counters]

  @doc "Delegates a canonical trace query to one explicitly configured host adapter."
  def kernel_query(config, operation, arguments)
      when is_list(config) and operation in @operations and is_map(arguments) do
    source = {:directory, Keyword.fetch!(config, :trace_dir)}

    case Keyword.get(config, :kernel_trace_adapter) do
      nil -> {:error, :unavailable}
      adapter when is_function(adapter, 3) -> safely_query(adapter, source, operation, arguments)
      adapter when is_atom(adapter) -> safely_query(adapter, source, operation, arguments)
    end
  end

  def kernel_query(_config, _operation, _arguments), do: {:error, :invalid_query}

  defp safely_query(adapter, source, operation, arguments) when is_function(adapter, 3) do
    adapter.(source, operation, arguments)
    |> normalize_adapter_result()
  rescue
    _exception -> {:error, :adapter_failure}
  catch
    _kind, _reason -> {:error, :adapter_failure}
  end

  defp safely_query(adapter, source, operation, arguments) when is_atom(adapter) do
    apply(adapter, :query, [source, operation, arguments])
    |> normalize_adapter_result()
  rescue
    _exception -> {:error, :adapter_failure}
  catch
    _kind, _reason -> {:error, :adapter_failure}
  end

  defp normalize_adapter_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_adapter_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_adapter_result(_invalid), do: {:error, :adapter_failure}
end
