defmodule PtcRunner.Kernel.LimitConfiguration do
  @moduledoc false

  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits

  @doc false
  @spec validate_effective(Limits.t(), :normal | :private) ::
          :ok
          | {:error, {:limit_configuration_invalid, pos_integer(), pos_integer(), pos_integer()}}
  def validate_effective(%Limits{} = limits, :normal) do
    required_bytes = required_normal_event_bytes(limits)

    if limits.normal_event_bytes >= required_bytes do
      :ok
    else
      {:error,
       {:limit_configuration_invalid, limits.normal_event_bytes, required_bytes,
        limits.event_payload_bytes}}
    end
  end

  def validate_effective(%Limits{}, :private), do: :ok

  @doc false
  @spec required_normal_event_bytes(Limits.t()) :: pos_integer()
  def required_normal_event_bytes(%Limits{} = limits) do
    terminal_bytes = EventSink.terminal_reserve(:normal, limits).bytes
    run_started_bytes = EventBudget.maximum_event_bytes("run-started", limits.event_payload_bytes)
    terminal_bytes + run_started_bytes
  end
end
