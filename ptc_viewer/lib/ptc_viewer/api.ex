defmodule PtcViewer.Api do
  @moduledoc "Read-only host-delegated canonical trace API."

  @operations [:list_runs, :get_run, :list_turns, :counters]

  @doc "Delegates a canonical trace query to one explicitly configured host adapter."
  def kernel_query(config, operation, arguments)
      when is_list(config) and operation in @operations and is_map(arguments) do
    source = Keyword.get(config, :trace_source) || trace_source(config)

    case Keyword.get(config, :kernel_trace_adapter) do
      nil -> {:error, :unavailable}
      adapter when is_function(adapter, 3) -> safely_query(adapter, source, operation, arguments)
      adapter when is_atom(adapter) -> safely_query(adapter, source, operation, arguments)
    end
  end

  def kernel_query(_config, _operation, _arguments), do: {:error, :invalid_query}

  @doc "Delegates semantic private conversation reconstruction to the configured host adapter."
  def conversation(config, run_id), do: inspection_query(config, :conversation, run_id)

  @doc "Delegates authorized terminal application-result retrieval to the configured host adapter."
  def result(config, run_id), do: inspection_query(config, :result, run_id)

  @doc "Delegates private effective-prelude source retrieval to the configured host adapter."
  def preludes(config, run_id), do: inspection_query(config, :preludes, run_id)

  @doc "Delegates authorized workflow execution-error records to the host adapter."
  def execution_errors(config, run_id), do: inspection_query(config, :execution_errors, run_id)

  @doc "Delegates dedicated explicit-failure-value records to the host adapter."
  def explicit_failure_values(config, run_id),
    do: inspection_query(config, :explicit_failure_values, run_id)

  defp inspection_query(config, operation, run_id)
       when is_list(config) and is_binary(run_id) do
    store = Keyword.get(config, :inspection_store)
    adapter = Keyword.get(config, :inspection_adapter)

    # A Viewer started for a project that does not record inspection artifacts
    # is given neither. That is a configuration choice with a next action, not
    # evidence that is momentarily out of reach, and the two must not share a
    # reason: only the second is worth retrying.
    if is_pid(store) and not is_nil(adapter) do
      case PtcViewer.InspectionStore.fetch(store) do
        {:ok, source} -> safely_inspection(adapter, operation, source, run_id)
        _missing -> {:error, :unavailable}
      end
    else
      {:error, absence_reason(config)}
    end
  end

  defp inspection_query(_config, _operation, _run_id), do: {:error, :invalid_inspection_query}

  # Two different configuration choices withhold the store, and they have
  # different next actions: one records no artifact at all, the other records it
  # and withholds the private grant that would serve it. The host states which
  # applies, because only the host can see the project document.
  defp absence_reason(config) do
    case Keyword.get(config, :inspection_absence) do
      :not_private -> :inspection_not_private
      _not_recorded -> :inspection_not_configured
    end
  end

  defp trace_source(config) do
    trace_dir = Keyword.fetch!(config, :trace_dir)

    if Keyword.get(config, :private_traces, false),
      do: {:private_directory, trace_dir},
      else: {:directory, trace_dir}
  end

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

  defp safely_inspection(adapter, :conversation, source, run_id)
       when is_function(adapter, 2) do
    adapter.(source, run_id)
    |> normalize_adapter_result()
  rescue
    _exception -> {:error, :adapter_failure}
  catch
    _kind, _reason -> {:error, :adapter_failure}
  end

  defp safely_inspection(adapter, operation, source, run_id) when is_atom(adapter) do
    apply(adapter, operation, [source, run_id])
    |> normalize_adapter_result()
  rescue
    _exception -> {:error, :adapter_failure}
  catch
    _kind, _reason -> {:error, :adapter_failure}
  end

  defp safely_inspection(_adapter, _operation, _source, _run_id),
    do: {:error, :unavailable}

  defp normalize_adapter_result({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_adapter_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_adapter_result(_invalid), do: {:error, :adapter_failure}
end
