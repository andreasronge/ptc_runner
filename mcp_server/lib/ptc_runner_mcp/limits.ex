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
  # Phase 0 (§11.6 / §9): expose the PTC-Lisp sandbox program limits
  # as configurable fields with the v1 defaults (1 s / 10 MB). The
  # aggregator-only limits (upstream_call_timeout_ms,
  # max_upstream_response_bytes, max_upstream_calls_per_program) land
  # in Phase 1a where they are actually consumed.
  @default_program_timeout_ms 1000
  @default_program_memory_limit_bytes 10 * 1024 * 1024

  @typedoc "Limits stored in persistent_term."
  @type t :: %{
          max_frame_bytes: pos_integer(),
          max_program_bytes: pos_integer(),
          max_context_bytes: pos_integer(),
          max_concurrent_calls: pos_integer(),
          program_timeout_ms: pos_integer(),
          program_memory_limit_bytes: pos_integer()
        }

  @doc "Default limits map."
  @spec defaults() :: t()
  def defaults do
    %{
      max_frame_bytes: @default_max_frame_bytes,
      max_program_bytes: @default_max_program_bytes,
      max_context_bytes: @default_max_context_bytes,
      max_concurrent_calls: default_max_concurrent_calls(),
      program_timeout_ms: @default_program_timeout_ms,
      program_memory_limit_bytes: @default_program_memory_limit_bytes
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

  @doc """
  Convenience: read `:program_timeout_ms` (Phase 0 §11.6 / §9).

  Default: 1000 ms (matches the v1 PTC-Lisp sandbox `:timeout`).
  Aggregator mode (Phase 1a) overrides this default to 10 s when
  `configured_aggregator_mode?/0` is true *and* no explicit value
  was provided.
  """
  @spec program_timeout_ms() :: pos_integer()
  def program_timeout_ms, do: get().program_timeout_ms

  @doc """
  Convenience: read `:program_memory_limit_bytes` (Phase 0 §11.6 / §9).

  Default: 10 MB (matches the v1 PTC-Lisp sandbox heap budget).
  Aggregator mode (Phase 1a) overrides this default to 100 MB when
  `configured_aggregator_mode?/0` is true *and* no explicit value
  was provided.
  """
  @spec program_memory_limit_bytes() :: pos_integer()
  def program_memory_limit_bytes, do: get().program_memory_limit_bytes

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
