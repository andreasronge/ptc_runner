defmodule PtcRunner.Kernel.InspectionArtifact.Limits do
  @moduledoc false

  @word_bytes :erlang.system_info(:wordsize)
  @max_record_bytes 2_000_000
  @max_total_bytes 536_870_912
  @default_records 16_384
  @max_records 65_536
  @max_index_entries 1_000_000
  @max_logical_index_bytes 128_000_000
  @max_retained_bytes 128_000_000
  @max_range_bytes @max_record_bytes
  @max_result_bytes 1_048_576
  @admission_heap_bytes 128_000_000
  @query_heap_bytes 32_000_000
  @phase_deadline_ms 15_000
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
          admission_heap_bytes: pos_integer(),
          query_heap_bytes: pos_integer(),
          admission_deadline_ms: pos_integer(),
          query_deadline_ms: pos_integer(),
          cleanup_deadline_ms: pos_integer(),
          io_buffer_bytes: pos_integer()
        }

  @spec defaults() :: t()
  def defaults do
    %{
      max_record_bytes: @max_record_bytes,
      max_total_bytes: @max_total_bytes,
      max_records: @default_records,
      max_index_entries: @max_index_entries,
      max_logical_index_bytes: @max_logical_index_bytes,
      max_retained_bytes: @max_retained_bytes,
      max_range_bytes: @max_range_bytes,
      max_result_bytes: @max_result_bytes,
      admission_heap_bytes: @admission_heap_bytes,
      query_heap_bytes: @query_heap_bytes,
      admission_deadline_ms: @phase_deadline_ms,
      query_deadline_ms: @phase_deadline_ms,
      cleanup_deadline_ms: @cleanup_deadline_ms,
      io_buffer_bytes: @io_buffer_bytes
    }
  end

  @spec merge(keyword() | map()) :: {:ok, t()} | {:error, :invalid_limits}
  def merge(opts) when is_list(opts), do: merge(Map.new(opts))

  def merge(opts) when is_map(opts) do
    defaults = defaults()
    maxima = %{defaults | max_records: @max_records}

    if Map.keys(opts) -- Map.keys(defaults) == [] and
         Enum.all?(opts, fn {key, value} ->
           is_integer(value) and value > 0 and value <= Map.fetch!(maxima, key)
         end) do
      {:ok, Map.merge(defaults, opts)}
    else
      {:error, :invalid_limits}
    end
  end

  def merge(_opts), do: {:error, :invalid_limits}

  @spec heap_words(pos_integer()) :: pos_integer()
  def heap_words(bytes), do: div(bytes + @word_bytes - 1, @word_bytes)

  @spec max_record_bytes() :: pos_integer()
  def max_record_bytes, do: @max_record_bytes

  @spec max_total_bytes() :: pos_integer()
  def max_total_bytes, do: @max_total_bytes

  @spec max_artifact_bytes() :: pos_integer()
  def max_artifact_bytes, do: @max_total_bytes + 16 + 192

  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @spec default_records() :: pos_integer()
  def default_records, do: @default_records

  @spec max_retained_bytes() :: pos_integer()
  def max_retained_bytes, do: @max_retained_bytes

  @spec word_bytes() :: pos_integer()
  def word_bytes, do: @word_bytes
end
