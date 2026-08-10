defmodule PtcRunner.Lisp.TrustedTool do
  @moduledoc false
  @enforce_keys [:function]
  defstruct [:function, argument_projection: :tool, ledger_arguments: :full]
end
