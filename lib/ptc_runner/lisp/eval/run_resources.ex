defmodule PtcRunner.Lisp.Eval.RunResources do
  @moduledoc false

  @doc false
  @spec new_counter() :: :atomics.atomics_ref()
  def new_counter, do: :atomics.new(1, [])
end
