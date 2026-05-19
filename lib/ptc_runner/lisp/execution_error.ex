defmodule PtcRunner.Lisp.ExecutionError do
  @moduledoc """
  Exception used to signal execution errors during Lisp evaluation.

  This exception is used internally by the `tool_executor` and `ToolNormalizer`
  to propagate structured errors (like unknown tools or tool failures)
  out of the evaluation loop and into the `Step` failure result.
  """
  defexception [:reason, :message, :data, :child_trace_id, :child_step]

  @doc """
  Compile-time list of stable parallel error reasons that must survive
  nesting unchanged so the security/capacity outcome is deterministic at
  any depth. Safe to use in guard clauses.
  """
  defmacro stable_parallel_reasons do
    [:memory_exceeded, :timeout, :parallel_capacity_exceeded]
  end
end
