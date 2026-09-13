defmodule PtcRunner.Kernel.RunBuilder.Retained do
  @moduledoc "Non-owning build context that supplies acquired capabilities without acquisition."
  @enforce_keys [:borrow]
  defstruct @enforce_keys
  @type t :: %__MODULE__{borrow: PtcRunner.Kernel.ProviderRuntime.Borrow.t()}
end
