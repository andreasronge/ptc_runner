defmodule PtcRunner.Lisp.TypeError do
  @moduledoc """
  Raised by Lisp runtime functions when arguments have the wrong type.

  Caught by the evaluator and converted to `{:error, {:type_error, message, args}}`.
  """

  defexception [:message]
end
