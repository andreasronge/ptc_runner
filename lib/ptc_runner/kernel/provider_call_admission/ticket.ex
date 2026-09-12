defmodule PtcRunner.Kernel.ProviderCallAdmission.Ticket do
  @moduledoc false

  @enforce_keys [:counter]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{counter: :atomics.atomics_ref()}

  @spec new() :: t()
  def new, do: %__MODULE__{counter: :atomics.new(1, signed: false)}

  @spec release(term(), :atomics.atomics_ref()) :: integer() | :ok
  def release(%__MODULE__{counter: counter}, pending) do
    if :atomics.compare_exchange(counter, 1, 0, 1) == :ok,
      do: :atomics.sub_get(pending, 1, 1),
      else: :ok
  end

  def release(_ticket, _pending), do: :ok
end
