defmodule PtcRunner.Kernel.CommandPresentation do
  @moduledoc false

  alias PtcRunner.Kernel.CommandOutcome

  @enforce_keys [:stdout, :stderr, :exit_status, :outcome, :envelope_path]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stdout: binary(),
          stderr: binary(),
          exit_status: non_neg_integer(),
          outcome: CommandOutcome.t() | nil,
          envelope_path: binary() | nil
        }
end
