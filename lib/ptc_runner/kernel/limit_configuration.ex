defmodule PtcRunner.Kernel.LimitConfiguration do
  @moduledoc false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits

  @doc false
  @spec validate_effective(Limits.t(), :normal | :private) ::
          :ok
          | {:error, {:limit_configuration_invalid, pos_integer(), pos_integer(), pos_integer()}}
  def validate_effective(%Limits{} = limits, :normal) do
    required_bytes =
      EventSink.terminal_reserve(:normal, limits).bytes + limits.event_payload_bytes

    if limits.normal_event_bytes >= required_bytes do
      :ok
    else
      {:error,
       {:limit_configuration_invalid, limits.normal_event_bytes, required_bytes,
        limits.event_payload_bytes}}
    end
  end

  def validate_effective(%Limits{}, :private), do: :ok
end
