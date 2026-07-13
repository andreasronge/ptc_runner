defmodule PtcRunner.Kernel.Limits do
  @moduledoc """
  Normalized positive hard ceilings for one Kernel run.

  All values are positive integers; there is no disabled or infinite form.
  `new/1` accepts only known fields and overlays them on `defaults/0`.

  Time fields are milliseconds and heap fields are BEAM words:

  - `run_duration_ms` bounds the complete run after construction;
  - `workflow_timeout_ms` and `evaluation_timeout_ms` bound individual
    workflow and subordinate evaluations;
  - `workflow_heap_words`, `evaluation_heap_words`, and
    `provider_heap_words` are per-process heap ceilings;
  - `live_provider_tasks` bounds concurrent provider callback processes;
  - `workflow_capability_calls` and `mission_capability_calls` are total call
    quotas, with matching `*_per_name` quotas;
  - `subordinate_evaluations` and `protocol_errors` bound those operations;
  - `entry_source_bytes`, `subordinate_source_bytes`, and
    `evaluation_memory_bytes` bound code and retained mission state;
  - `capability_argument_bytes`, `capability_result_bytes`, and
    `terminal_result_bytes` bound values crossing runtime boundaries;
  - `event_payload_bytes`, `normal_event_count`, and `normal_event_bytes` bound
    canonical event collection.

  These are runtime enforcement values. A frontend may apply a separate
  administrator ceiling before constructing them.
  """

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

  @type t :: %__MODULE__{
          run_duration_ms: pos_integer(),
          workflow_timeout_ms: pos_integer(),
          evaluation_timeout_ms: pos_integer(),
          workflow_heap_words: pos_integer(),
          evaluation_heap_words: pos_integer(),
          provider_heap_words: pos_integer(),
          live_provider_tasks: pos_integer(),
          workflow_capability_calls: pos_integer(),
          workflow_capability_calls_per_name: pos_integer(),
          mission_capability_calls: pos_integer(),
          mission_capability_calls_per_name: pos_integer(),
          subordinate_evaluations: pos_integer(),
          protocol_errors: pos_integer(),
          entry_source_bytes: pos_integer(),
          subordinate_source_bytes: pos_integer(),
          evaluation_memory_bytes: pos_integer(),
          capability_argument_bytes: pos_integer(),
          capability_result_bytes: pos_integer(),
          event_payload_bytes: pos_integer(),
          terminal_result_bytes: pos_integer(),
          normal_event_count: pos_integer(),
          normal_event_bytes: pos_integer()
        }
  @spec defaults() :: t()
  @doc "Returns the complete application-independent default limit set."
  def defaults, do: struct!(__MODULE__, @defaults)

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, :invalid_limits}
  @doc """
  Builds a complete limit set by applying atom-keyed overrides to the defaults.

  Unknown fields and non-positive or non-integer values are rejected.
  """
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
