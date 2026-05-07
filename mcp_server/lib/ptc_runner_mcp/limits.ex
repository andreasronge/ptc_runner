defmodule PtcRunnerMcp.Limits do
  @moduledoc """
  Resource-limit configuration for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 11. Phase 1 implements
  `:max_frame_bytes` only; the rest of the table (program/context/
  concurrency) lands in later phases but their getters live here so
  call sites can be wired without churn.

  Configuration is process-wide and stored in `:persistent_term` for
  cheap reads.
  """

  @default_max_frame_bytes 8 * 1024 * 1024
  @default_max_program_bytes 64 * 1024
  @default_max_context_bytes 4 * 1024 * 1024

  @typedoc "Limits stored in persistent_term."
  @type t :: %{
          max_frame_bytes: pos_integer(),
          max_program_bytes: pos_integer(),
          max_context_bytes: pos_integer(),
          max_concurrent_calls: pos_integer()
        }

  @doc "Default limits map."
  @spec defaults() :: t()
  def defaults do
    %{
      max_frame_bytes: @default_max_frame_bytes,
      max_program_bytes: @default_max_program_bytes,
      max_context_bytes: @default_max_context_bytes,
      max_concurrent_calls: default_max_concurrent_calls()
    }
  end

  @doc """
  Set the process-wide limits map.

  Any keys missing from the input map fall back to defaults.
  """
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :limits}, merged)
    :ok
  end

  @doc "Read the current limits map."
  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :limits}, defaults())
  end

  @doc "Convenience: read `:max_frame_bytes`."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: get().max_frame_bytes

  @doc "Convenience: read `:max_program_bytes` (per § 11)."
  @spec max_program_bytes() :: pos_integer()
  def max_program_bytes, do: get().max_program_bytes

  @doc "Convenience: read `:max_context_bytes` (per § 11)."
  @spec max_context_bytes() :: pos_integer()
  def max_context_bytes, do: get().max_context_bytes

  @doc "Convenience: read `:max_concurrent_calls` (per § 11)."
  @spec max_concurrent_calls() :: pos_integer()
  def max_concurrent_calls, do: get().max_concurrent_calls

  defp default_max_concurrent_calls do
    cores =
      try do
        :erlang.system_info(:logical_processors)
      rescue
        _ -> 1
      end

    cores = if is_integer(cores) and cores > 0, do: cores, else: 1
    min(8, cores)
  end
end
