defmodule PtcRunner.Lisp.Parser do
  @moduledoc """
  NimbleParsec-based parser for PTC-Lisp.

  Transforms source code into AST nodes.
  """

  import NimbleParsec
  alias PtcRunner.Lisp.AST
  alias PtcRunner.Lisp.ParserHelpers

  # ============================================================
  # Whitespace and Comments
  # ============================================================

  whitespace_char = ascii_char([?\s, ?\t, ?\n, ?\r, ?,])

  comment =
    string(";")
    |> repeat(lookahead_not(ascii_char([?\n])) |> utf8_char([]))
    |> optional(ascii_char([?\n]))

  defcombinatorp(
    :ws,
    repeat(choice([ignore(whitespace_char), ignore(comment)]))
  )

  # ============================================================
  # Literals
  # ============================================================

  # Character classes for lookahead
  symbol_rest = [?a..?z, ?A..?Z, ?0..?9, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%]

  nil_literal =
    string("nil")
    |> lookahead_not(ascii_char(symbol_rest))
    |> replace(nil)

  true_literal =
    string("true")
    |> lookahead_not(ascii_char(symbol_rest))
    |> replace(true)

  false_literal =
    string("false")
    |> lookahead_not(ascii_char(symbol_rest))
    |> replace(false)

  # Numbers
  sign = ascii_char([?-, ?+])

  integer_literal =
    optional(ascii_char([?-]))
    |> ascii_string([?0..?9], min: 1)
    |> reduce({ParserHelpers, :parse_integer, []})

  exponent =
    ascii_char([?e, ?E])
    |> optional(sign)
    |> ascii_string([?0..?9], min: 1)

  float_literal =
    optional(ascii_char([?-]))
    |> ascii_string([?0..?9], min: 1)
    |> string(".")
    |> ascii_string([?0..?9], min: 1)
    |> optional(exponent)
    |> reduce({ParserHelpers, :parse_float, []})

  # Strings
  escape_sequence =
    ignore(string("\\"))
    |> choice([
      string("\\") |> replace(?\\),
      string("\"") |> replace(?"),
      string("n") |> replace(?\n),
      string("t") |> replace(?\t),
      string("r") |> replace(?\r)
    ])

  # Single-line strings only - exclude literal newlines
  string_char =
    choice([
      escape_sequence,
      utf8_char(not: ?\\, not: ?", not: ?\n, not: ?\r)
    ])

  string_literal =
    ignore(string("\""))
    |> repeat(string_char)
    |> ignore(string("\""))
    |> reduce({ParserHelpers, :build_string, []})

  # Keywords (no / allowed)
  keyword =
    ignore(string(":"))
    |> ascii_string([?a..?z, ?A..?Z, ?0..?9, ?-, ?_, ??, ?!], min: 1)
    |> reduce({ParserHelpers, :build_keyword, []})

  # Symbols (/ allowed for namespacing, _ for ignored bindings, % for param placeholders in #())
  symbol_first = [?a..?z, ?A..?Z, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%]

  symbol =
    ascii_string(symbol_first, 1)
    |> optional(ascii_string(symbol_rest, min: 1))
    |> reduce({ParserHelpers, :build_symbol, []})

  # ============================================================
  # Collections (recursive)
  # ============================================================

  defcombinatorp(
    :vector,
    ignore(string("["))
    |> concat(parsec(:ws))
    |> repeat(parsec(:expr) |> concat(parsec(:ws)))
    |> ignore(string("]"))
    |> tag(:vector)
    |> map({ParserHelpers, :build_vector, []})
  )

  defcombinatorp(
    :map_literal,
    ignore(string("{"))
    |> concat(parsec(:ws))
    |> repeat(parsec(:expr) |> concat(parsec(:ws)))
    |> ignore(string("}"))
    |> tag(:map)
    |> map({ParserHelpers, :build_map, []})
  )

  defcombinatorp(
    :set,
    ignore(string("#" <> "{"))
    |> concat(parsec(:ws))
    |> repeat(parsec(:expr) |> concat(parsec(:ws)))
    |> ignore(string("}"))
    |> tag(:set)
    |> map({ParserHelpers, :build_set, []})
  )

  defcombinatorp(
    :short_fn,
    ignore(string("#("))
    |> concat(parsec(:ws))
    |> repeat(parsec(:expr) |> concat(parsec(:ws)))
    |> ignore(string(")"))
    |> tag(:short_fn)
    |> map({ParserHelpers, :build_short_fn, []})
  )

  defcombinatorp(
    :list,
    ignore(string("("))
    |> concat(parsec(:ws))
    |> repeat(parsec(:expr) |> concat(parsec(:ws)))
    |> ignore(string(")"))
    |> tag(:list)
    |> map({ParserHelpers, :build_list, []})
  )

  # ============================================================
  # Expression
  # ============================================================

  defcombinatorp(
    :expr,
    choice([
      nil_literal,
      true_literal,
      false_literal,
      float_literal,
      integer_literal,
      string_literal,
      keyword,
      symbol,
      parsec(:vector),
      parsec(:set),
      parsec(:short_fn),
      parsec(:map_literal),
      parsec(:list)
    ])
  )

  # ============================================================
  # Entry Point
  # ============================================================

  defparsec(
    :program,
    parsec(:ws)
    |> concat(parsec(:expr))
    |> concat(parsec(:ws))
    |> eos()
  )

  # ============================================================
  # Public API
  # ============================================================

  @doc """
  Parse PTC-Lisp source code into AST.

  Returns `{:ok, ast}` or `{:error, {:parse_error, message}}`.
  """
  @spec parse(String.t()) :: {:ok, AST.t()} | {:error, {:parse_error, String.t()}}
  def parse(source) when is_binary(source) do
    case program(source) do
      {:ok, [ast], "", _context, _position, _offset} ->
        {:ok, ast}

      {:ok, _result, rest, _context, {line, _}, _offset} ->
        {:error,
         {:parse_error, "Unexpected input at line #{line}: #{inspect(String.slice(rest, 0, 20))}"}}

      {:error, reason, rest, _context, {line, line_offset}, offset} ->
        column = offset - line_offset + 1
        snippet = String.slice(rest, 0, 20)

        {:error,
         {:parse_error, "#{reason} at line #{line}, column #{column}: #{inspect(snippet)}"}}
    end
  rescue
    e in ArgumentError -> {:error, {:parse_error, e.message}}
  end
end
