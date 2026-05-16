defmodule PtcRunner.Lisp.Keyword do
  @moduledoc """
  Runtime representation for PTC-Lisp keywords that are not in the bounded atom vocabulary.

  Existing atom-backed keywords remain atoms for compatibility. New source keywords use this
  struct so user input cannot grow the BEAM atom table while keywords stay distinct from strings.
  """

  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  @spec new(String.t()) :: t()
  def new(name) when is_binary(name), do: %__MODULE__{name: name}

  @spec name(atom() | t()) :: String.t()
  def name(%__MODULE__{name: name}), do: name
  def name(atom) when is_atom(atom), do: Atom.to_string(atom)

  @spec keyword?(term()) :: boolean()
  def keyword?(%__MODULE__{}), do: true

  def keyword?(atom) when is_atom(atom),
    do:
      not is_nil(atom) and not is_boolean(atom) and
        atom not in [:infinity, :negative_infinity, :nan]

  def keyword?(_), do: false
end
