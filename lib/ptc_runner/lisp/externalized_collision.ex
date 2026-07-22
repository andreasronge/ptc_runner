defmodule PtcRunner.Lisp.ExternalizedCollision do
  @moduledoc false

  @enforce_keys [:collection, :value, :ordinal]
  defstruct [:collection, :value, :ordinal]

  @type t :: %__MODULE__{
          collection: :map | :set,
          value: term(),
          ordinal: non_neg_integer()
        }
end

defimpl Inspect, for: PtcRunner.Lisp.ExternalizedCollision do
  def inspect(%{value: value}, opts), do: Inspect.Algebra.to_doc(value, opts)
end

defimpl String.Chars, for: PtcRunner.Lisp.ExternalizedCollision do
  alias PtcRunner.Lisp.Keyword, as: LispKeyword

  def to_string(%{value: %LispKeyword{name: name}}), do: name
  def to_string(%{value: value}) when is_binary(value), do: value
  def to_string(%{value: value}) when is_atom(value), do: Atom.to_string(value)
  def to_string(%{value: value}) when is_integer(value), do: Integer.to_string(value)
  def to_string(%{value: value}), do: inspect(value, limit: 100, printable_limit: 1_024)
end
