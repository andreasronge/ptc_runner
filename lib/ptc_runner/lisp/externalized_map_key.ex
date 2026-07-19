defmodule PtcRunner.Lisp.ExternalizedMapKey do
  @moduledoc false

  @enforce_keys [:value, :ordinal]
  defstruct [:value, :ordinal]
end

defimpl String.Chars, for: PtcRunner.Lisp.ExternalizedMapKey do
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  def to_string(%{value: %LispKeyword{name: name}}), do: name
  def to_string(%{value: value}) when is_binary(value), do: value
  def to_string(%{value: value}) when is_atom(value), do: Atom.to_string(value)
  def to_string(%{value: value}) when is_integer(value), do: Integer.to_string(value)
  def to_string(%{value: value}), do: inspect(value, limit: 100, printable_limit: 1_024)
end
