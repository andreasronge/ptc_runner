defmodule PtcRunner.Kernel.LimitConfiguration do
  @moduledoc false

  alias PtcRunner.Kernel.EventBudget
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits

  @doc false
  @spec validate_effective(Limits.t(), :normal | :private) ::
          :ok
          | {:error, {:limit_configuration_invalid, pos_integer(), pos_integer(), pos_integer()}}
  def validate_effective(%Limits{} = limits, policy) when policy in [:normal, :private] do
    required_bytes = required_event_bytes(limits, policy)

    if limits.normal_event_bytes >= required_bytes do
      :ok
    else
      {:error,
       {:limit_configuration_invalid, limits.normal_event_bytes, required_bytes,
        limits.event_payload_bytes}}
    end
  end

  @doc false
  @spec validate_minimum(Limits.t()) ::
          :ok
          | {:error, {:limit_configuration_invalid, pos_integer(), pos_integer(), pos_integer()}}
  def validate_minimum(%Limits{} = limits), do: validate_effective(limits, :private)

  @doc false
  @spec required_normal_event_bytes(Limits.t()) :: pos_integer()
  def required_normal_event_bytes(%Limits{} = limits), do: required_event_bytes(limits, :normal)

  @doc false
  @spec required_private_event_bytes(Limits.t()) :: pos_integer()
  def required_private_event_bytes(%Limits{} = limits), do: required_event_bytes(limits, :private)

  defp required_event_bytes(limits, policy) do
    terminal_bytes = EventSink.terminal_reserve(policy, limits).bytes
    run_started_bytes = EventBudget.maximum_event_bytes("run-started", limits.event_payload_bytes)
    terminal_bytes + run_started_bytes
  end
end
