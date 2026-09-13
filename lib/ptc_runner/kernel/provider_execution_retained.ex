defmodule PtcRunner.Kernel.ProviderExecution.Retained do
  @moduledoc "Retained acquisition context: the same runtime borrow and its sealed plan identity."
  @enforce_keys [:execution, :borrow, :plan_identity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          execution: PtcRunner.Kernel.ProviderExecution.t(),
          borrow: PtcRunner.Kernel.ProviderRuntime.Borrow.t(),
          plan_identity: tuple()
        }
end
