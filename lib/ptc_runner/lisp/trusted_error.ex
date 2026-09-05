defmodule PtcRunner.Lisp.TrustedError do
  @moduledoc false

  @enforce_keys [:reason, :message, :details]
  defstruct [:reason, :message, :details, status: :error]

  @type t :: %__MODULE__{reason: atom(), message: String.t(), details: map(), status: :error}
end
