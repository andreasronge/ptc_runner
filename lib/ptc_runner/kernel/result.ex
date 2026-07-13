defmodule PtcRunner.Kernel.Result do
  @moduledoc """
  A bounded successful Kernel outcome.

  `value` is the workflow's projected public return value. `usage` is the final
  resource snapshot, including remaining time, capability calls, subordinate
  evaluations, protocol errors, memory accounting, and event loss.
  `evaluation_memory` is a bounded summary; workflow locals and raw mission
  memory are never exposed.
  """
  @enforce_keys [:value, :usage, :evaluation_memory]
  defstruct [:value, :usage, :evaluation_memory]

  @type t :: %__MODULE__{value: term(), usage: map(), evaluation_memory: map()}
end
