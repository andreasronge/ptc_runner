defmodule PtcRunnerMcp.DebugConfig do
  @moduledoc """
  Boot-time configuration for the opt-in `lisp_debug` diagnostics tool.

  See `Plans/ptc-runner-mcp-debug-tool.md` § 4. Mirrors the
  `PtcRunnerMcp.AgenticConfig` / `PtcRunnerMcp.AggregatorConfig`
  pattern: `defaults/0`, `set/1`, `get/0`, plus predicates. Stored in
  `:persistent_term`.

  When `enabled` is `false` (the default) there is no `DebugBuffer`
  process, no recording hook work beyond a single `:persistent_term`
  read per `tools/call`, and `lisp_debug` is not advertised in
  `tools/list`.
  """

  @ring_size_min 10
  @ring_size_max 5_000

  # A maximally-truncated `lisp_debug` envelope — worst case the
  # `op=get` "too large" shape: `op` + a 256-byte `request_id` +
  # `payload_policy` + `redaction_applied` + `found` + `truncated` +
  # the `note`, doubled into `content[0].text`, plus the JSON-RPC
  # frame — fits comfortably under 4 KiB. Raising the operator value
  # to this floor guarantees the shrink logic can always produce a
  # response within the configured cap, so `--max-debug-response-bytes`
  # is a *real* hard limit even for absurd operator values.
  @max_response_bytes_min 4_096

  @defaults %{
    enabled: false,
    ring_size: 500,
    max_response_bytes: 65_536
  }

  @typedoc "Debug-tool configuration stored in persistent_term."
  @type t :: %{
          enabled: boolean(),
          ring_size: pos_integer(),
          max_response_bytes: pos_integer()
        }

  @doc "Default debug-tool config."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Inclusive `[min, max]` clamp range for `--debug-ring-size`."
  @spec ring_size_bounds() :: {pos_integer(), pos_integer()}
  def ring_size_bounds, do: {@ring_size_min, @ring_size_max}

  @doc """
  Set process-wide debug-tool config.

  Unknown keys are ignored. Missing keys fall back to defaults.
  """
  @spec set(map()) :: :ok
  def set(overrides) when is_map(overrides) do
    merged = Map.merge(defaults(), Map.take(overrides, Map.keys(defaults())))
    :persistent_term.put({__MODULE__, :config}, merged)
    :ok
  end

  @doc "Read current process-wide debug-tool config."
  @spec get() :: t()
  def get do
    :persistent_term.get({__MODULE__, :config}, defaults())
  end

  @doc "True when the `lisp_debug` tool is enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: get().enabled == true

  @doc "Configured ring-buffer capacity (records)."
  @spec ring_size() :: pos_integer()
  def ring_size, do: get().ring_size

  @doc "Configured `--max-debug-response-bytes` cap."
  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: get().max_response_bytes

  @doc """
  Clamp a requested ring size to `[#{@ring_size_min}, #{@ring_size_max}]`.

  Returns `{clamped_value, clamped?}` so the caller can emit a `warn`
  log line on clamp.
  """
  @spec clamp_ring_size(integer()) :: {pos_integer(), boolean()}
  def clamp_ring_size(value) when is_integer(value) do
    clamped = value |> max(@ring_size_min) |> min(@ring_size_max)
    {clamped, clamped != value}
  end

  @doc "Minimum enforceable `--max-debug-response-bytes` value."
  @spec max_response_bytes_min() :: pos_integer()
  def max_response_bytes_min, do: @max_response_bytes_min

  @doc """
  Raise a requested `--max-debug-response-bytes` to the floor that can
  hold a minimal envelope (#{@max_response_bytes_min} bytes).

  Returns `{clamped_value, clamped?}`.
  """
  @spec clamp_max_response_bytes(integer()) :: {pos_integer(), boolean()}
  def clamp_max_response_bytes(value) when is_integer(value) do
    clamped = max(value, @max_response_bytes_min)
    {clamped, clamped != value}
  end
end
