defmodule PtcRunner.Lisp.TrustedError do
  @moduledoc false

  @enforce_keys [:reason, :message, :details]
  defstruct [:reason, :message, :details, status: :error]
end
