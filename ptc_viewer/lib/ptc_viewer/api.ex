defmodule PtcViewer.Api do
  @moduledoc "File-based API for reading traces and plans from disk."

  def list_traces do
    list_files(trace_dir(), ".jsonl")
  end

  def get_trace(filename) do
    get_file(trace_dir(), filename)
  end

  def list_plans do
    list_files(plan_dir(), ".json")
  end

  def get_plan(filename) do
    get_file(plan_dir(), filename)
  end

  defp trace_dir do
    Application.get_env(:ptc_viewer, :trace_dir, "traces")
  end

  defp plan_dir do
    Application.get_env(:ptc_viewer, :plan_dir, "data")
  end

  defp list_files(dir, extension) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, extension))
        |> Enum.map(fn filename ->
          path = Path.join(dir, filename)
          stat = File.stat!(path)

          %{
            filename: filename,
            size: stat.size,
            modified: stat.mtime |> NaiveDateTime.from_erl!() |> NaiveDateTime.to_iso8601()
          }
        end)
        |> Enum.sort_by(& &1.modified, :desc)

      {:error, _} ->
        []
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
