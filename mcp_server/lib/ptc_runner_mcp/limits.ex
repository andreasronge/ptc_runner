defmodule PtcRunnerMcp.Limits do
  @moduledoc """
  Resource-limit configuration for the MCP server.

  Per `Plans/ptc-runner-mcp-server.md` § 11 and
  `Plans/ptc-runner-mcp-aggregator.md` §9. Phase 1a adds the three
  aggregator-only limits (`upstream_call_timeout_ms`,
  `max_upstream_response_bytes`, `max_upstream_calls_per_program`)
  and the aggregator-mode override of the v1 program limits.

  Configuration is process-wide and stored in `:persistent_term` for
  cheap reads.
  """

  @default_max_frame_bytes 8 * 1024 * 1024
  @default_max_program_bytes 64 * 1024
  @default_max_context_bytes 4 * 1024 * 1024

  # MCP v1 (no upstreams) defaults — fast and small. Aggregator mode
  # overrides these when configured AND no explicit value was provided
  # (§11.6 "no override of explicit values").
  @default_program_timeout_ms 1000
  @default_program_memory_limit_bytes 10 * 1024 * 1024

  # Aggregator-mode defaults for the v1 program limits (§9 second column).
  @aggregator_program_timeout_ms 10_000
  @aggregator_program_memory_limit_bytes 100 * 1024 * 1024

  # Aggregator-only limits (§9 third+ rows).
  @default_upstream_call_timeout_ms 5_000
  @default_max_upstream_response_bytes 2 * 1024 * 1024
  @default_max_upstream_calls_per_program 50

  @typedoc "Limits stored in persistent_term."
  @type t :: %{
          max_frame_bytes: pos_integer(),
          max_program_bytes: pos_integer(),
          max_context_bytes: pos_integer(),
          max_concurrent_calls: pos_integer(),
          program_timeout_ms: pos_integer(),
          program_memory_limit_bytes: pos_integer(),
          upstream_call_timeout_ms: pos_integer(),
          max_upstream_response_bytes: pos_integer(),
          max_upstream_calls_per_program: pos_integer()
        }

  @doc "Default limits map (v1 / `:mcp_no_tools` profile)."
  @spec defaults() :: t()
  def defaults do
    %{
      max_frame_bytes: @default_max_frame_bytes,
      max_program_bytes: @default_max_program_bytes,
      max_context_bytes: @default_max_context_bytes,
      max_concurrent_calls: default_max_concurrent_calls(),
      program_timeout_ms: @default_program_timeout_ms,
      program_memory_limit_bytes: @default_program_memory_limit_bytes,
      upstream_call_timeout_ms: @default_upstream_call_timeout_ms,
      max_upstream_response_bytes: @default_max_upstream_response_bytes,
      max_upstream_calls_per_program: @default_max_upstream_calls_per_program
    }
  end

  @doc """
  Aggregator-mode default values for the v1 program limits per
  `Plans/ptc-runner-mcp-aggregator.md` §9 / §11.6.

  Used by `PtcRunnerMcp.Application.apply_limits/1` to override the
  v1 defaults *only* when aggregator mode is configured AND the
  operator did not provide an explicit CLI flag or env var. An
  explicit value always wins.
  """
  @spec aggregator_defaults() :: %{
          program_timeout_ms: pos_integer(),
          program_memory_limit_bytes: pos_integer()
        }
  def aggregator_defaults do
    %{
      program_timeout_ms: @aggregator_program_timeout_ms,
      program_memory_limit_bytes: @aggregator_program_memory_limit_bytes
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

  @doc """
  Per-upstream-call wall-clock timeout (§9 row 3).

  Default: 5000 ms. Set via `--upstream-call-timeout-ms` flag or
  `PTC_RUNNER_MCP_UPSTREAM_CALL_TIMEOUT_MS` env var. Honored only
  in aggregator mode (the value is meaningless when no upstreams
  are configured).
  """
  @spec upstream_call_timeout_ms() :: pos_integer()
  def upstream_call_timeout_ms, do: get().upstream_call_timeout_ms

  @doc """
  Per-upstream-response byte cap (§9 row 4).

  Default: 2 MB. Set via `--max-upstream-response-bytes` flag or
  `PTC_RUNNER_MCP_MAX_UPSTREAM_RESPONSE_BYTES` env var. Per §9
  enforced **outside the sandbox**, **before** JSON-decoding the
  response into BEAM terms — the runtime cannot be OOM'd by an
  upstream returning a 100 MB blob.
  """
  @spec max_upstream_response_bytes() :: pos_integer()
  def max_upstream_response_bytes, do: get().max_upstream_response_bytes

  @doc """
  Per-program upstream-call cap (§9 row 5).

  Default: 50. Set via `--max-upstream-calls-per-program` flag or
  `PTC_RUNNER_MCP_MAX_UPSTREAM_CALLS_PER_PROGRAM` env var.
  Enforced via a closure-captured `:counters.new(1, [])` ref per
  `tools/call` (§6.4); the (cap+1)th call returns `nil` and records
  `cap_exhausted` (§7.1).
  """
  @spec max_upstream_calls_per_program() :: pos_integer()
  def max_upstream_calls_per_program, do: get().max_upstream_calls_per_program

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
