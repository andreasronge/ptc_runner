defmodule PtcRunner.Lisp.Eval.CapabilityResult do
  @moduledoc false

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end
