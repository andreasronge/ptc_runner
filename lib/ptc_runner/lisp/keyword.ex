defmodule PtcRunner.Lisp.Keyword do
  @moduledoc """
  Runtime representation for PTC-Lisp keywords that are not in the bounded atom vocabulary.

  Existing atom-backed keywords remain atoms for compatibility. New source keywords use this
  struct so user input cannot grow the BEAM atom table while keywords stay distinct from strings.
  """

  defstruct [:name]

  @type t :: %__MODULE__{name: String.t()}

  # The parser's keyword grammar — letters, digits, and the operator chars
  # the lexer accepts after `:` (`+ - * < > = ? ! _`). No `/` (DIV-13), no
  # `.`, no spaces. Mirrors the `keyword` token rule in `Lisp.Parser`.
  @valid_name ~r/\A[a-zA-Z0-9+\-*<>=?!_]+\z/

  @spec new(String.t()) :: t()
  def new(name) when is_binary(name), do: %__MODULE__{name: name}

  @doc """
  Whether `name` is a syntactically valid keyword name per the parser grammar.

  A novel keyword externalizes to a plain binary, so this is the check
  callers use to tell a genuine externalized keyword from an arbitrary
  string at a boundary.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@valid_name, name)
  def valid_name?(_), do: false

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
