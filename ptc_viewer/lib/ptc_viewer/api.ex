defmodule PtcViewer.Api do
  @moduledoc "File-based API for reading traces from disk."

  def list_traces do
    list_files(trace_dir(), ".jsonl")
  end

  def get_trace(filename) do
    get_file(trace_dir(), filename)
  end

  defp trace_dir do
    Application.get_env(:ptc_viewer, :trace_dir, "traces")
  end

  defp list_files(dir, extension) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, extension))
        |> Enum.map(fn filename ->
          path = Path.join(dir, filename)
          stat = File.stat!(path)

          base = %{
            filename: filename,
            size: stat.size,
            modified: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
          }

          # Read trace header from first line for quick metadata
          Map.merge(base, read_trace_header(path))
        end)
        |> Enum.sort_by(& &1.modified, :desc)

      {:error, _} ->
        []
    end
  end

  # Read the first line (trace.start) to extract typed header fields
  defp read_trace_header(path) do
    with {:ok, file} <- File.open(path, [:read, :utf8]),
         line when is_binary(line) <- IO.read(file, :line),
         :ok <- File.close(file),
         {:ok, event} <- Jason.decode(String.trim(line)) do
      %{
        trace_kind: event["trace_kind"],
        producer: event["producer"],
        trace_label: event["trace_label"],
        model: event["model"],
        query: event["query"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp get_file(dir, filename) do
    # Security: prevent path traversal
    safe_name = Path.basename(filename)
    path = Path.join(dir, safe_name)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end
end
