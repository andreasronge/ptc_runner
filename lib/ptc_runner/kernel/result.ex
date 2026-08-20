defmodule PtcRunner.Kernel.Result do
  @moduledoc """
  A bounded successful Kernel outcome.

  `value` is the workflow's inert, collision-free public return value. A value
  whose distinct keys or set members become ambiguous at the Kernel boundary is
  rejected with `:public_projection_collision` instead of entering this struct.
  `usage` is the final resource snapshot, including remaining time, capability
  calls, capability refusals, subordinate evaluations, protocol errors, memory accounting, and event
  loss.
  `evaluation_memory` is a bounded continuation summary with definition/history
  counts and byte accounting; workflow locals, raw mission memory, and exact
  history values are never exposed.
  """
  @enforce_keys [:value, :usage, :evaluation_memory]
  defstruct [:value, :usage, :evaluation_memory]

  @type t :: %__MODULE__{value: term(), usage: map(), evaluation_memory: map()}
end
