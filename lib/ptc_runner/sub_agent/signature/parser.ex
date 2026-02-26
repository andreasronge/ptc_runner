defmodule PtcRunner.SubAgent.Signature.Parser do
  @moduledoc """
  NimbleParsec-based parser for signature strings.

  Transforms signature syntax into AST:
  - Primitives: :string, :int, :float, :bool, :keyword, :any
  - Collections: [:type], {field :type}, :map
  - Optional fields: :type?
  - Full format: (params) -> output or shorthand: output
  """

  import NimbleParsec

  alias PtcRunner.SubAgent.Signature.ParserHelpers

  # ============================================================
  # Whitespace
  # ============================================================

  whitespace_char = ascii_char([?\s, ?\t, ?\n, ?\r])

  defcombinatorp(
    :ws,
    repeat(ignore(whitespace_char))
  )

  # ============================================================
  # Basic Tokens
  # ============================================================

  # Identifier - letters, numbers, hyphens, underscores
  # First char must be letter or underscore
  identifier_start = [?a..?z, ?A..?Z, ?_]
  identifier_rest = [?a..?z, ?A..?Z, ?0..?9, ?-, ?_]

  identifier =
    ascii_string(identifier_start, 1)
    |> optional(ascii_string(identifier_rest, min: 1))
    |> reduce({ParserHelpers, :concat_identifier, []})

  # Type keyword (:string, :int, :float, :bool, :keyword, :any, :map)
  type_keyword =
    ignore(ascii_char([?:]))
    |> choice([
      string("string"),
      string("int"),
      string("float"),
      string("bool"),
      string("keyword"),
      string("map"),
      string("fn"),
      string("any")
    ])
    |> map({String, :to_atom, []})

  # ============================================================
  # Type Parsing
  # ============================================================

  # Primitive type with optional ? suffix
  defcombinatorp(
    :primitive_type,
    type_keyword
    |> optional(ascii_char([??]) |> replace({:optional}))
    |> reduce({ParserHelpers, :build_type, []})
  )

  # List type: [element_type]
  defcombinatorp(
    :list_type,
    ignore(ascii_char([?[]))
    |> parsec(:ws)
    |> parsec(:simple_type)
    |> parsec(:ws)
    |> ignore(ascii_char([?\]]))
    |> reduce({ParserHelpers, :wrap_list, []})
  )

  # Map field: name :type
  defcombinatorp(
    :map_field,
    identifier
    |> parsec(:ws)
    |> parsec(:simple_type)
    |> reduce({ParserHelpers, :build_map_field, []})
  )

  # Map fields: field, field, field (zero or more)
  defcombinatorp(
    :map_fields_list,
    parsec(:map_field)
    |> repeat(
      parsec(:ws)
      |> ignore(ascii_char([?,]))
      |> parsec(:ws)
      |> parsec(:map_field)
    )
    |> reduce({ParserHelpers, :flatten_list, []})
  )

  # Map type: {field :type, field :type}
  defcombinatorp(
    :map_type,
    ignore(ascii_char([?{]))
    |> parsec(:ws)
    |> optional(parsec(:map_fields_list))
    |> parsec(:ws)
    |> ignore(ascii_char([?}]))
    |> reduce({ParserHelpers, :build_map_type, []})
  )

  # Simple type: primitive, list, or map
  defcombinatorp(
    :simple_type,
    choice([
      parsec(:map_type),
      parsec(:list_type),
      parsec(:primitive_type)
    ])
  )

  # Parameter: name :type
  defcombinatorp(
    :parameter,
    identifier
    |> parsec(:ws)
    |> parsec(:simple_type)
    |> reduce({ParserHelpers, :build_parameter, []})
  )

  # Parameter list: param, param, param
  defcombinatorp(
    :parameters_list,
    parsec(:parameter)
    |> repeat(
      parsec(:ws)
      |> ignore(ascii_char([?,]))
      |> parsec(:ws)
      |> parsec(:parameter)
    )
    |> reduce({ParserHelpers, :flatten_list, []})
  )

  # Full signature: (params) -> type
  defcombinatorp(
    :full_signature,
    ignore(ascii_char([?(]))
    |> parsec(:ws)
    |> optional(parsec(:parameters_list))
    |> parsec(:ws)
    |> ignore(ascii_char([?)]))
    |> parsec(:ws)
    |> ignore(string("->"))
    |> parsec(:ws)
    |> parsec(:simple_type)
    |> reduce({ParserHelpers, :build_full_signature, []})
  )

  # Shorthand signature: just the type
  defcombinatorp(
    :shorthand_signature,
    parsec(:simple_type)
    |> reduce({ParserHelpers, :build_shorthand_signature, []})
  )

  # Main signature parser
  defcombinatorp(
    :signature,
    parsec(:ws)
    |> choice([
      parsec(:full_signature),
      parsec(:shorthand_signature)
    ])
    |> parsec(:ws)
  )

  # Entry point
  defparsec(
    :parse_impl,
    parsec(:signature) |> eos()
  )

  @valid_types ~w(string int float bool keyword map fn any)

  @doc """
  Parse a signature string into AST.

  Returns {:ok, ast} or {:error, reason}
  """
  @spec parse(String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    case parse_impl(input) do
      {:ok, [ast], "", _context, _position, _offset} ->
        {:ok, ast}

      {:ok, _parsed, rest, _context, {line, _}, _offset} ->
        column = String.length(input) - String.length(rest) + 1

        {:error,
         "unexpected input at line #{line}, column #{column}: #{String.slice(rest, 0, 20)}..."}

      {:error, reason, _rest, _context, {line, _line_offset}, offset} ->
        {:error, format_error(input, reason, line, offset)}
    end
  end

  def parse(input) do
    {:error, "signature must be a string, got #{inspect(input)}"}
  end

  defp format_error(input, reason, line, offset) do
    base_error = "parse error at line #{line}, column #{offset}: #{inspect(reason)}"

    # Detect generic "expected ASCII character" errors and add type hint
    if generic_type_error?(reason) and likely_invalid_type?(input) do
      base_error <>
        "\n\nHint: Valid types are :#{Enum.join(@valid_types, ", :")}. " <>
        "For lists use [:type], for maps use {field :type}."
    else
      base_error
    end
  end

  defp generic_type_error?(reason) do
    String.contains?(reason, "expected ASCII character")
  end

  defp likely_invalid_type?(input) do
    # Check if input contains a colon followed by a word that isn't a valid type
    Regex.match?(~r/:([a-z]+)/, input) and
      Regex.scan(~r/:([a-z]+)/, input)
      |> Enum.any?(fn [_, type] -> type not in @valid_types end)
  end
end
