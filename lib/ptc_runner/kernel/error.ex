defmodule PtcRunner.Kernel.Error do
  @moduledoc "A bounded failed Kernel outcome."
  @enforce_keys [:kind, :reason, :details, :usage]
  defstruct [:kind, :reason, :details, :usage]
end
