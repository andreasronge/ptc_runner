defmodule PtcRunner.Lisp.TrustedTool do
  @moduledoc false
  @enforce_keys [:function]
  defstruct [:function, ledger_arguments: :full]
end
