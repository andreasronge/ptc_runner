defmodule PtcRunner.TestSupport.ObservedException do
  @moduledoc false

  defexception [:owner, :value, mode: :value]

  @impl Exception
  def message(%__MODULE__{mode: :raise}), do: raise("message formatter failed")

  def message(%__MODULE__{mode: :block}) do
    receive do
      :never -> "unreachable"
    end
  end

  def message(%__MODULE__{owner: owner, value: value}) when is_pid(owner) and is_binary(value) do
    send(owner, {:exception_message_formatted, value})
    value
  end

  def message(%__MODULE__{value: value}) when is_binary(value), do: value
end
