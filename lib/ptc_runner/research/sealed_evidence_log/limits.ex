defmodule PtcRunner.Research.SealedEvidenceLog.Limits do
  @moduledoc """
  Prototype-only ceilings and the inventory of existing inspection limits.

  Installed prototype values are research authorities, not host-facing
  production defaults. Proposed production numbers are derived after
  measurement and recorded in the maintainer result page.
  """

  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.InspectionArtifact
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.InspectionSnapshot

  @word_bytes :erlang.system_info(:wordsize)
  @max_record_bytes 64 * 1024 * 1024
  @max_total_bytes 512 * 1024 * 1024 + 16 + 192
  @max_records 1_000_000
  @max_index_entries 8_000_000
  @max_logical_index_bytes 512 * 1024 * 1024
  @max_retained_bytes 512 * 1024 * 1024
  @max_range_bytes 64 * 1024 * 1024
  @max_result_bytes 1_000_000
  @producer_heap_bytes 256 * 1024 * 1024
  @admission_heap_bytes 256 * 1024 * 1024
  @query_heap_bytes 256 * 1024 * 1024
  @producer_deadline_ms 120_000
  @admission_deadline_ms 120_000
  @query_deadline_ms 15_000
  @cleanup_deadline_ms 5_000
  @io_buffer_bytes 65_536

  @type t :: %{
          max_record_bytes: pos_integer(),
          max_total_bytes: pos_integer(),
          max_records: pos_integer(),
          max_index_entries: pos_integer(),
          max_logical_index_bytes: pos_integer(),
          max_retained_bytes: pos_integer(),
          max_range_bytes: pos_integer(),
          max_result_bytes: pos_integer(),
          producer_heap_bytes: pos_integer(),
          admission_heap_bytes: pos_integer(),
          query_heap_bytes: pos_integer(),
          producer_deadline_ms: pos_integer(),
          admission_deadline_ms: pos_integer(),
          query_deadline_ms: pos_integer(),
          cleanup_deadline_ms: pos_integer(),
          io_buffer_bytes: pos_integer()
        }

  @spec word_bytes() :: pos_integer()
  def word_bytes, do: @word_bytes

  @spec defaults() :: t()
  def defaults do
    %{
      max_record_bytes: @max_record_bytes,
      max_total_bytes: @max_total_bytes,
      max_records: @max_records,
      max_index_entries: @max_index_entries,
      max_logical_index_bytes: @max_logical_index_bytes,
      max_retained_bytes: @max_retained_bytes,
      max_range_bytes: @max_range_bytes,
      max_result_bytes: @max_result_bytes,
      producer_heap_bytes: @producer_heap_bytes,
      admission_heap_bytes: @admission_heap_bytes,
      query_heap_bytes: @query_heap_bytes,
      producer_deadline_ms: @producer_deadline_ms,
      admission_deadline_ms: @admission_deadline_ms,
      query_deadline_ms: @query_deadline_ms,
      cleanup_deadline_ms: @cleanup_deadline_ms,
      io_buffer_bytes: @io_buffer_bytes
    }
  end

  @spec merge(keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def merge(opts) when is_list(opts), do: merge(Map.new(opts))

  def merge(opts) when is_map(opts) do
    defaults = defaults()
    allowed = Map.keys(defaults)

    if Map.keys(opts) -- allowed == [] and Enum.all?(opts, &allowed_override?(defaults, &1)) do
      {:ok, Map.merge(defaults, opts)}
    else
      {:error, :invalid_limits}
    end
  end

  def merge(_opts), do: {:error, :invalid_limits}

  @spec heap_words(pos_integer()) :: pos_integer()
  def heap_words(bytes) when is_integer(bytes) and bytes > 0 do
    div(bytes + @word_bytes - 1, @word_bytes)
  end

  @spec inventory() :: [map()]
  def inventory do
    host_facing() ++ snapshot_internal() ++ producer_sink() ++ prototype_installed() ++ guards()
  end

  defp allowed_override?(defaults, {key, value}) do
    is_integer(value) and value > 0 and value <= Map.fetch!(defaults, key)
  end

  defp host_facing do
    [
      limit_row(
        "install.ptc_inspection_snapshot.ceilings.max_files",
        :host_facing,
        :admission,
        :files,
        {1_024, 1_024, 1_024},
        :directory,
        "PtcRunner.Kernel.HostConfig inspection snapshot ceilings"
      ),
      limit_row(
        "install.ptc_inspection_snapshot.ceilings.max_source_bytes",
        :host_facing,
        :admission,
        :bytes,
        {64_000_000, 64_000_000, 64_000_000},
        :aggregate,
        "PtcRunner.Kernel.HostConfig inspection snapshot ceilings"
      ),
      limit_row(
        "install.ptc_inspection_snapshot.ceilings.max_result_bytes",
        :host_facing,
        :query,
        :bytes,
        {1_048_576, 1_048_576, 1_048_576},
        :selected_or_directory,
        "PtcRunner.Kernel.HostConfig inspection snapshot ceilings"
      )
    ]
  end

  defp snapshot_internal do
    [
      limit_row(
        "internal only",
        :snapshot_internal,
        :admission,
        :bytes,
        {128_000_000, 128_000_000, 128_000_000},
        :selected_or_directory,
        "PtcRunner.Kernel.InspectionSnapshot max_retained_bytes"
      ),
      limit_row(
        "internal only",
        :snapshot_internal,
        :admission,
        :files,
        {1_024, 1_024, 1_024},
        :directory,
        "PtcRunner.Kernel.InspectionSnapshot max_files"
      ),
      limit_row(
        "internal only",
        :snapshot_internal,
        :admission,
        :entries,
        {4_096, 4_096, 4_096},
        :directory,
        "PtcRunner.Kernel.InspectionSnapshot max_directory_entries"
      ),
      limit_row(
        "internal only",
        :snapshot_internal,
        :admission,
        :bytes,
        {16_000_000, 16_000_000, 16_000_000},
        :selected_file,
        "PtcRunner.Kernel.InspectionSnapshot max_artifact_bytes / InspectionArtifact"
      )
    ]
  end

  defp producer_sink do
    [
      limit_row(
        "internal only",
        :producer,
        :producer,
        :bytes,
        {2_000_000, 2_000_000, 2_000_000},
        :selected_file,
        "PtcRunner.Kernel.InspectionSink max_record_bytes"
      ),
      limit_row(
        "internal only",
        :producer,
        :producer,
        :bytes,
        {16_000_000, 16_000_000, 16_000_000},
        :selected_file,
        "PtcRunner.Kernel.InspectionSink max_total_bytes"
      )
    ]
  end

  defp prototype_installed do
    defaults = defaults()

    [
      limit_row(
        "internal only",
        :prototype,
        :producer,
        :bytes,
        {defaults.max_record_bytes, defaults.max_record_bytes, defaults.max_record_bytes},
        :selected_file,
        "prototype max_record_bytes"
      ),
      limit_row(
        "internal only",
        :prototype,
        :producer,
        :bytes,
        {defaults.max_total_bytes, defaults.max_total_bytes, defaults.max_total_bytes},
        :selected_file,
        "prototype max_total_bytes"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :records,
        {defaults.max_records, defaults.max_records, defaults.max_records},
        :selected_file,
        "prototype max_records"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :entries,
        {defaults.max_index_entries, defaults.max_index_entries, defaults.max_index_entries},
        :selected_file,
        "prototype max_index_entries"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :bytes,
        {defaults.max_logical_index_bytes, defaults.max_logical_index_bytes,
         defaults.max_logical_index_bytes},
        :selected_file,
        "prototype max_logical_index_bytes"
      ),
      limit_row(
        "internal only",
        :prototype,
        :query,
        :bytes,
        {defaults.max_range_bytes, defaults.max_range_bytes, defaults.max_range_bytes},
        :selected_file,
        "prototype verified range-byte ceiling"
      ),
      limit_row(
        "internal only",
        :prototype,
        :query,
        :milliseconds,
        {defaults.query_deadline_ms, defaults.query_deadline_ms, defaults.query_deadline_ms},
        :selected_or_directory,
        "prototype query deadline"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :bytes,
        {defaults.max_retained_bytes, defaults.max_retained_bytes, defaults.max_retained_bytes},
        :selected_or_directory,
        "prototype max_retained_bytes"
      ),
      limit_row(
        "internal only",
        :prototype,
        :query,
        :bytes,
        {defaults.max_result_bytes, defaults.max_result_bytes, defaults.max_result_bytes},
        :selected_or_directory,
        "prototype max_result_bytes"
      ),
      limit_row(
        "internal only",
        :prototype,
        :producer,
        :bytes,
        {defaults.producer_heap_bytes, defaults.producer_heap_bytes,
         defaults.producer_heap_bytes},
        :selected_file,
        "prototype producer max_heap_size envelope"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :bytes,
        {defaults.admission_heap_bytes, defaults.admission_heap_bytes,
         defaults.admission_heap_bytes},
        :selected_file,
        "prototype admission max_heap_size envelope"
      ),
      limit_row(
        "internal only",
        :prototype,
        :query,
        :bytes,
        {defaults.query_heap_bytes, defaults.query_heap_bytes, defaults.query_heap_bytes},
        :selected_file,
        "prototype query max_heap_size envelope"
      ),
      limit_row(
        "internal only",
        :prototype,
        :producer,
        :milliseconds,
        {defaults.producer_deadline_ms, defaults.producer_deadline_ms,
         defaults.producer_deadline_ms},
        :selected_file,
        "prototype producer deadline"
      ),
      limit_row(
        "internal only",
        :prototype,
        :admission,
        :milliseconds,
        {defaults.admission_deadline_ms, defaults.admission_deadline_ms,
         defaults.admission_deadline_ms},
        :selected_file,
        "prototype admission deadline"
      ),
      limit_row(
        "internal only",
        :prototype,
        :cleanup,
        :milliseconds,
        {defaults.cleanup_deadline_ms, defaults.cleanup_deadline_ms,
         defaults.cleanup_deadline_ms},
        :selected_or_directory,
        "prototype cleanup deadline"
      ),
      limit_row(
        "internal only",
        :prototype,
        :producer,
        :bytes,
        {defaults.io_buffer_bytes, defaults.io_buffer_bytes, defaults.io_buffer_bytes},
        :selected_file,
        "prototype I/O buffer"
      )
    ]
  end

  defp guards do
    [
      limit_row(
        "internal only",
        :maintained_guard,
        :admission,
        :schema_version,
        {8, 8, 8},
        :selected_file,
        "InspectionArtifact / prototype schema_version"
      ),
      limit_row(
        "internal only",
        :maintained_guard,
        :query,
        :items,
        {1_000, 100, 1_000},
        :selected_or_directory,
        "InspectionQuery max/default page limit"
      )
    ]
  end

  defp limit_row(
         path,
         class,
         phase,
         unit,
         {compiled, installed, hard_max},
         file_meaning,
         consumer
       ) do
    %{
      "path" => path,
      "class" => class,
      "phase" => phase,
      "unit" => unit,
      "compiled_default" => compiled,
      "installed_default" => installed,
      "hard_maximum" => hard_max,
      "file_meaning" => file_meaning,
      "consumer" => consumer,
      "modules" => inventory_modules()
    }
  end

  defp inventory_modules do
    [
      HostConfig,
      InspectionSnapshot,
      InspectionArtifact,
      InspectionSink
    ]
  end
end
