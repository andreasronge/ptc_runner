defmodule PtcViewer.Api do
  @moduledoc "Read-only file and host-delegated canonical trace API."

  @max_raw_trace_bytes 8_000_000
  @operations [:list_runs, :get_run, :list_turns, :counters]

  def list_traces(trace_dir \\ "traces") when is_binary(trace_dir) do
    list_files(trace_dir, ".jsonl")
  end

  def get_trace(filename, trace_dir \\ "traces") when is_binary(trace_dir) do
    get_file(trace_dir, filename)
  end

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

  defp list_files(dir, extension) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, extension) and not private_trace?(&1)))
        |> Enum.flat_map(&file_metadata(dir, &1))
        |> Enum.sort_by(& &1.modified, :desc)

      {:error, _reason} ->
        []
    end
  end

  defp file_metadata(dir, filename) do
    path = Path.join(dir, filename)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        base = %{
          filename: filename,
          size: stat.size,
          modified: utc_timestamp(stat.mtime)
        }

        [Map.merge(base, read_trace_header(path, stat))]

      _unsupported ->
        []
    end
  end

  defp utc_timestamp(datetime) do
    unix_seconds =
      :calendar.datetime_to_gregorian_seconds(datetime) -
        :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

    unix_seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  defp read_trace_header(path, expected) do
    with {:ok, prefix} <- read_opened(path, expected, 16_384),
         line when is_binary(line) <- prefix |> String.split("\n", parts: 2) |> List.first(),
         {:ok, event} <- Jason.decode(String.trim(line)) do
      %{
        trace_kind: event["trace_kind"],
        producer: event["producer"],
        trace_label: event["trace_label"],
        model: event["model"],
        query: event["query"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    else
      _reason -> %{}
    end
  end

  defp get_file(dir, filename) when is_binary(filename) do
    safe_name = Path.basename(filename)
    path = Path.join(dir, safe_name)

    with true <-
           safe_name == filename and String.ends_with?(safe_name, ".jsonl") and
             not private_trace?(safe_name),
         {:ok, %File.Stat{type: :regular, size: size} = expected}
         when size <= @max_raw_trace_bytes <- File.lstat(path),
         {:ok, content} <- read_opened(path, expected, @max_raw_trace_bytes + 1),
         true <- byte_size(content) <= @max_raw_trace_bytes do
      {:ok, content}
    else
      _reason -> {:error, :not_found}
    end
  end

  defp get_file(_dir, _filename), do: {:error, :not_found}

  defp read_opened(path, expected, bytes) do
    with {:ok, device} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        with {:ok, file_info} <- :file.read_file_info(device),
             opened = File.Stat.from_record(file_info),
             :ok <- same_file(expected, opened),
             true <- opened.type == :regular do
          case :file.read(device, bytes) do
            {:ok, content} -> {:ok, content}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
          end
        else
          _changed -> {:error, :source_changed}
        end
      after
        :file.close(device)
      end
    end
  end

  defp same_file(
         %File.Stat{major_device: device, minor_device: minor, inode: inode},
         %File.Stat{major_device: device, minor_device: minor, inode: inode}
       ),
       do: :ok

  defp same_file(_expected, _opened), do: {:error, :source_changed}
  defp private_trace?(filename), do: String.ends_with?(filename, ".private.jsonl")
end
