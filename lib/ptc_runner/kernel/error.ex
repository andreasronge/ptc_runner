defmodule PtcRunner.Kernel.Error do
  @moduledoc """
  A bounded failed Kernel outcome.

  `kind` is the stable outer category, `reason` is a more specific runtime
  classification, `details` contains sanitized bounded context, and `usage` is
  the final resource snapshot. Provider failures normally remain recoverable
  capability envelopes and become a Kernel error only when workflow policy or
  a hard runtime boundary makes them terminal.

  Outer kinds currently include `:workflow_failed`, `:limit_exceeded`,
  `:event_sink_error`, `:configuration_error`, `:inspection_sink_error`, and
  `:provider_cleanup_error`.
  """
  @enforce_keys [:kind, :reason, :details, :usage]
  defstruct [:kind, :reason, :details, :usage]

  @type t :: %__MODULE__{kind: atom(), reason: atom(), details: map(), usage: map()}
end
