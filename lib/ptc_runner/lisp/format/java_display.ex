defmodule PtcRunner.Lisp.Format.JavaDisplay do
  @moduledoc false

  @enforce_keys [:identity, :label]
  defstruct [:identity, :label]
end

defimpl Inspect, for: PtcRunner.Lisp.Format.JavaDisplay do
  def inspect(%{label: label}, _opts), do: label
end
