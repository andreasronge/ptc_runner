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
  # Note: . is allowed for Clojure-style namespaces like clojure.string/join
  # Note: & is allowed for rest pattern destructuring [a & rest]
  symbol_rest = [?a..?z, ?A..?Z, ?0..?9, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&]

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

  special_literal =
    ignore(string("##"))
    |> choice([
      string("-Inf") |> lookahead_not(ascii_char(symbol_rest)) |> replace(:negative_infinity),
      string("Inf") |> lookahead_not(ascii_char(symbol_rest)) |> replace(:infinity),
      string("NaN") |> lookahead_not(ascii_char(symbol_rest)) |> replace(:nan)
    ])

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

  # Scientific notation without decimal point: 1e5, 1e-5, 1e+5, 2E10
  # Must come before float_literal in choice to handle integer+exponent forms
  integer_with_exponent =
    optional(ascii_char([?-]))
    |> ascii_string([?0..?9], min: 1)
    |> concat(exponent)
    |> reduce({ParserHelpers, :parse_float, []})

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
      string("r") |> replace(?\r),
      # Passthrough: unknown escapes like \| \d \w preserve the backslash
      utf8_char(not: ?\\, not: ?", not: ?\n, not: ?\r)
      |> map({ParserHelpers, :passthrough_escape, []})
    ])

  # Single-line strings only - exclude literal newlines
  string_char =
    choice([
      escape_sequence,
      utf8_char(not: ?\\, not: ?", not: ?\n, not: ?\r)
    ])

  # Characters
  char_literal =
    ignore(string("\\"))
    |> choice([
      string("newline") |> replace("\n"),
      string("space") |> replace(" "),
      string("tab") |> replace("\t"),
      string("return") |> replace("\r"),
      string("backspace") |> replace("\b"),
      string("formfeed") |> replace("\f"),
      utf8_char([]) |> map({ParserHelpers, :char_to_string, []})
    ])
    |> map({ParserHelpers, :build_char, []})

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
  # & is allowed for rest pattern destructuring [a & rest]
  symbol_first = [?a..?z, ?A..?Z, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&]

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

  # Var reader syntax: #'name (references a var)
  # Symbol name follows same rules as regular symbols (but simpler - no namespace allowed)
  defcombinatorp(
    :var_reader,
    ignore(string("#'"))
    |> ascii_string([?a..?z, ?A..?Z, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_], 1)
    |> optional(
      ascii_string([?a..?z, ?A..?Z, ?0..?9, ?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_], min: 1)
    )
    |> reduce({ParserHelpers, :build_var, []})
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
      special_literal,
      integer_with_exponent,
      float_literal,
      integer_literal,
      string_literal,
      char_literal,
      keyword,
      symbol,
      parsec(:vector),
      parsec(:set),
      parsec(:var_reader),
      parsec(:short_fn),
      parsec(:map_literal),
      parsec(:list)
    ])
  )

  # ============================================================
  # Entry Point
  # ============================================================

  defcombinatorp(
    :inter_expr,
    parsec(:ws)
    |> ignore(repeat(choice([ascii_char([?), ?], ?}]), whitespace_char, comment])))
  )

  defparsec(
    :program,
    parsec(:inter_expr)
    |> repeat(parsec(:expr) |> concat(parsec(:inter_expr)))
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
    # Check for unsupported syntax before parsing
    with :ok <- check_unsupported_syntax(source) do
      do_parse(source)
    end
  end

  defp check_unsupported_syntax(source) do
    # Regex literals: #"pattern"
    if Regex.match?(~r/#"/, source) do
      {:error,
       {:parse_error,
        """
        regex literals (#"...") are not supported. Use instead:
        - (split s "delimiter") for literal delimiters
        - (split-lines s) for newlines
        - (re-split (re-pattern "\\\\s+") s) for regex patterns
        - (re-find (re-pattern "...") s) for matching\
        """}}
    else
      :ok
    end
  end

  defp do_parse(source) do
    case program(source) do
      # Empty program
      {:ok, [], "", _context, _position, _offset} ->
        {:ok, nil}

      # Single expression (backward compatible)
      {:ok, [ast], "", _context, _position, _offset} ->
        {:ok, ast}

      # Multiple expressions -> wrap in {:program, [...]}
      {:ok, asts, "", _context, _position, _offset} when is_list(asts) ->
        {:ok, {:program, asts}}

      {:ok, _result, rest, _context, {line, _}, _offset} ->
        {:error,
         {:parse_error, "Unexpected input at line #{line}: #{inspect(String.slice(rest, 0, 20))}"}}

      {:error, reason, rest, _context, {line, line_offset}, offset} ->
        column = offset - line_offset + 1
        snippet = String.slice(rest, 0, 20)

        # Improve error message for common cases
        improved_reason =
          cond do
            reason == "expected end of string" and offset == 0 ->
              # Failed at position 0 means no expressions were parsed
              # Check for unbalanced delimiters first, then unsupported syntax
              case check_delimiter_balance(source) do
                "syntax error: could not parse expression" ->
                  check_unsupported_patterns(source) ||
                    "syntax error: could not parse expression"

                msg ->
                  msg
              end

            reason == "expected end of string" ->
              # Parsed some content but then failed - check for unsupported syntax
              check_unsupported_patterns(source) ||
                debug_and_return_error(source, reason, line, column, snippet)

            true ->
              "#{reason} at line #{line}, column #{column}: #{inspect(snippet)}"
          end

        {:error, {:parse_error, improved_reason}}
    end
  rescue
    e in ArgumentError -> {:error, {:parse_error, e.message}}
  end

  # Check for unbalanced delimiters and return a helpful error message
  defp check_delimiter_balance(source) do
    {parens, brackets, braces} = count_delimiters(source)

    format_delimiter_error(parens, "parentheses", "(", ")") ||
      format_delimiter_error(brackets, "brackets", "[", "]") ||
      format_delimiter_error(braces, "braces", "{", "}") ||
      "syntax error: could not parse expression"
  end

  defp count_delimiters(source) do
    source
    |> String.graphemes()
    |> Enum.reduce({0, 0, 0}, fn char, {p, b, br} ->
      case char do
        "(" -> {p + 1, b, br}
        ")" -> {p - 1, b, br}
        "[" -> {p, b + 1, br}
        "]" -> {p, b - 1, br}
        "{" -> {p, b, br + 1}
        "}" -> {p, b, br - 1}
        _ -> {p, b, br}
      end
    end)
  end

  defp format_delimiter_error(count, name, open, _close) when count > 0 do
    "unbalanced #{name}: #{count} unclosed '#{open}'"
  end

  defp format_delimiter_error(count, name, _open, close) when count < 0 do
    "unbalanced #{name}: #{-count} extra '#{close}'"
  end

  defp format_delimiter_error(0, _name, _open, _close), do: nil

  # Check for unsupported syntax patterns and return a helpful error message
  defp check_unsupported_patterns(source) do
    # Remove string literals to avoid false positives (e.g., "user@example.com")
    source_without_strings = Regex.replace(~r/"(?:[^"\\]|\\.)*"/, source, "\"\"")
    # Also remove comments to avoid false positives
    source_clean = Regex.replace(~r/;[^\n]*/, source_without_strings, "")

    cond do
      # Reader discard macro: #_ (Clojure-specific, not supported)
      Regex.match?(~r/#_/, source_clean) ->
        "reader discard syntax (#_) is not supported. Use ; for comments"

      # Deref syntax: @atom
      Regex.match?(~r/@[a-zA-Z]/, source_clean) ->
        "deref syntax (@var) is not supported. Atoms and refs are not available"

      # Quote syntax: 'symbol or '(list)
      Regex.match?(~r/'[a-zA-Z(]/, source_clean) ->
        "quote syntax ('expr) is not supported. Use vectors [1 2 3] instead of quoted lists"

      true ->
        nil
    end
  end

  # Debug helper: optionally print source and return error message
  defp debug_and_return_error(source, reason, line, column, snippet) do
    # Enable with: PTC_DEBUG_PARSER=1 mix ...
    if System.get_env("PTC_DEBUG_PARSER") do
      IO.puts("\n=== DEBUG: Unidentified parse error ===")
      IO.puts("Source code:")
      IO.puts("---")
      IO.puts(source)
      IO.puts("---")
      IO.puts("Failed at line #{line}, column #{column}")
      IO.puts("=== END DEBUG ===\n")
    end

    # Improve confusing NimbleParsec error messages
    friendly_reason =
      case reason do
        "expected end of string" ->
          "syntax error: invalid or unexpected content"

        other ->
          other
      end

    "#{friendly_reason} at line #{line}, column #{column}: #{inspect(snippet)}"
  end
end
