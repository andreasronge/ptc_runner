defmodule PtcRunner.Kernel.Limits do
  @moduledoc "Normalized, positive hard ceilings for a Kernel run."

  @defaults %{
    run_duration_ms: 30_000,
    workflow_timeout_ms: 30_000,
    evaluation_timeout_ms: 1_000,
    workflow_heap_words: 8_000_000,
    evaluation_heap_words: 1_250_000,
    provider_heap_words: 5_000_000,
    live_provider_tasks: 8,
    workflow_capability_calls: 64,
    workflow_capability_calls_per_name: 16,
    mission_capability_calls: 128,
    mission_capability_calls_per_name: 32,
    subordinate_evaluations: 16,
    protocol_errors: 32,
    entry_source_bytes: 262_144,
    subordinate_source_bytes: 131_072,
    evaluation_memory_bytes: 2_000_000,
    capability_argument_bytes: 262_144,
    capability_result_bytes: 1_000_000,
    event_payload_bytes: 262_144,
    terminal_result_bytes: 1_000_000,
    normal_event_count: 256,
    normal_event_bytes: 4_000_000
  }
  @enforce_keys Map.keys(@defaults)
  defstruct Map.to_list(@defaults)

  @type t :: %__MODULE__{}
  @spec defaults() :: t()
  def defaults, do: struct!(__MODULE__, @defaults)

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_limits}
  def new(overrides \\ %{}) do
    overrides = if is_list(overrides), do: Map.new(overrides), else: overrides

    with true <- is_map(overrides),
         true <- MapSet.subset?(MapSet.new(Map.keys(overrides)), MapSet.new(Map.keys(@defaults))),
         values = Map.merge(@defaults, overrides),
         true <- Enum.all?(values, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok, struct!(__MODULE__, values)}
    else
      _ -> {:error, :invalid_limits}
    end
  end
end
