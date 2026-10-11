defmodule PtcRunner.Kernel.HostConfig.Snapshot do
  @moduledoc false

  alias PtcRunner.Kernel.HostConfig.Common

  @max_result_bytes 1_048_576
  @max_trace_source_bytes 8_000_000
  @max_inspection_source_bytes 536_871_120
  @max_inspection_files 1_024
  @minimum_snapshot_result_bytes Common.minimum_snapshot_result_bytes()

  import PtcRunner.Kernel.HostConfig.Common

  def trace_snapshot_installation(value, source)
      when source in [:ptc_trace_snapshot, :ptc_private_trace_snapshot] do
    with :ok <-
           exact_keys(
             value,
             ~w(source directory installation_revision ceilings),
             ~w(source directory installation_revision)
           ),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, installation_revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- trace_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: source,
         directory: directory,
         installation_revision: installation_revision,
         ceilings: ceilings
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp trace_snapshot_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_source_bytes max_result_bytes), []),
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Map.get(value, "max_source_bytes", @max_trace_source_bytes),
         true <- max_source_bytes <= @max_trace_source_bytes,
         max_result_bytes
         when is_integer(max_result_bytes) and
                max_result_bytes >= @minimum_snapshot_result_bytes <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes do
      {:ok,
       %{
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp trace_snapshot_ceilings(_value), do: {:error, :invalid_ceilings}

  def inspection_snapshot_installation(value) do
    with :ok <-
           exact_keys(
             value,
             ~w(source directory installation_revision ceilings),
             ~w(source directory installation_revision)
           ),
         directory when is_binary(directory) <- value["directory"],
         true <- valid_path_string?(directory),
         {:ok, installation_revision} <- revision(value["installation_revision"]),
         {:ok, ceilings} <- inspection_snapshot_ceilings(Map.get(value, "ceilings", %{})) do
      {:ok,
       %{
         source: :ptc_inspection_snapshot,
         directory: directory,
         installation_revision: installation_revision,
         ceilings: ceilings
       }}
    else
      _reason -> {:error, :invalid_installation}
    end
  end

  defp inspection_snapshot_ceilings(value) when is_map(value) do
    with :ok <- exact_keys(value, ~w(max_files max_source_bytes max_result_bytes), []),
         max_files when is_integer(max_files) and max_files > 0 <-
           Map.get(value, "max_files", @max_inspection_files),
         true <- max_files <= @max_inspection_files,
         max_source_bytes when is_integer(max_source_bytes) and max_source_bytes > 0 <-
           Map.get(value, "max_source_bytes", @max_inspection_source_bytes),
         true <- max_source_bytes <= @max_inspection_source_bytes,
         max_result_bytes
         when is_integer(max_result_bytes) and
                max_result_bytes >= @minimum_snapshot_result_bytes <-
           Map.get(value, "max_result_bytes", @max_result_bytes),
         true <- max_result_bytes <= @max_result_bytes do
      {:ok,
       %{
         max_files: max_files,
         max_source_bytes: max_source_bytes,
         max_result_bytes: max_result_bytes
       }}
    else
      _reason -> {:error, :invalid_ceilings}
    end
  end

  defp inspection_snapshot_ceilings(_value), do: {:error, :invalid_ceilings}
end
