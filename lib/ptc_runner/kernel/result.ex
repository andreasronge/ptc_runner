defmodule PtcRunner.Kernel.Result do
  @moduledoc "A bounded successful Kernel outcome."
  @enforce_keys [:value, :usage, :evaluation_memory]
  defstruct [:value, :usage, :evaluation_memory]

  @type t :: %__MODULE__{value: term(), usage: map(), evaluation_memory: map()}
end
