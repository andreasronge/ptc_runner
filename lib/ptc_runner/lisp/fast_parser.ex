defmodule PtcRunner.Lisp.FastParser do
  @moduledoc false

  alias PtcRunner.Lisp.AST
  alias PtcRunner.Lisp.SourceAtoms

  @max_integer_digits 100
  @max_nesting_depth 64

  @type cursor :: {binary(), non_neg_integer(), pos_integer(), pos_integer()}

  defguardp is_symbol_first(c)
            when c in ?a..?z or c in ?A..?Z or
                   c in [?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&]

  @spec parse(String.t()) :: {:ok, AST.t() | {:program, [AST.t()]} | nil} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    case parse_program({source, 0, 1, 1}, []) do
      {:ok, [], _cursor} -> {:ok, nil}
      {:ok, [ast], _cursor} -> {:ok, ast}
      {:ok, asts, _cursor} -> {:ok, {:program, asts}}
      {:error, message} -> {:error, message}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
  end

  defp parse_program(cursor, acc) do
    case skip_inter_expr(cursor) do
      {"", _, _, _} = cursor ->
        {:ok, Enum.reverse(acc), cursor}

      cursor ->
        with {:ok, ast, cursor} <- parse_expr(cursor, 0) do
          parse_program(cursor, [ast | acc])
        end
    end
  end

  defp parse_expr(cursor, depth) do
    if depth > @max_nesting_depth do
      {:error, "nesting depth exceeds limit of #{@max_nesting_depth}"}
    else
      do_parse_expr(cursor, depth)
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp do_parse_expr(cursor, depth) do
    cursor = skip_ws(cursor)

    case cursor do
      {"", _offset, line, column} ->
        {:error, "syntax error: could not parse expression at line #{line}, column #{column}"}

      {"(" <> rest, offset, line, column} ->
        parse_sequence({rest, offset + 1, line, column + 1}, ?), :list, [], depth)

      {"[" <> rest, offset, line, column} ->
        parse_sequence({rest, offset + 1, line, column + 1}, ?], :vector, [], depth)

      {"{" <> rest, offset, line, column} ->
        parse_sequence({rest, offset + 1, line, column + 1}, ?}, :map, [], depth)

      {<<?#, ?{, rest::binary>>, offset, line, column} ->
        parse_sequence({rest, offset + 2, line, column + 2}, ?}, :set, [], depth)

      {"#(" <> rest, offset, line, column} ->
        parse_sequence({rest, offset + 2, line, column + 2}, ?), :short_fn, [], depth)

      {"#\"" <> rest, offset, line, column} ->
        parse_string({rest, offset + 2, line, column + 2}, :regex_literal)

      {"#'" <> rest, offset, line, column} ->
        parse_var({rest, offset + 2, line, column + 2})

      {"'" <> rest, offset, line, column} ->
        parse_quoted_symbol({rest, offset + 1, line, column + 1})

      {"##-Inf" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, :negative_infinity, {rest, offset + 6, line, column + 6}},
          else: parse_symbol(cursor)

      {"##Inf" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, :infinity, {rest, offset + 5, line, column + 5}},
          else: parse_symbol(cursor)

      {"##NaN" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, :nan, {rest, offset + 5, line, column + 5}},
          else: parse_symbol(cursor)

      {"\"" <> rest, offset, line, column} ->
        parse_string({rest, offset + 1, line, column + 1}, :string)

      {":" <> _rest, _offset, _line, _column} ->
        parse_keyword(cursor)

      {"\\" <> rest, offset, line, column} ->
        parse_char({rest, offset + 1, line, column + 1})

      {"nil" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, nil, {rest, offset + 3, line, column + 3}},
          else: parse_symbol(cursor)

      {"true" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, true, {rest, offset + 4, line, column + 4}},
          else: parse_symbol(cursor)

      {"false" <> rest, offset, line, column} ->
        if symbol_boundary?(rest),
          do: {:ok, false, {rest, offset + 5, line, column + 5}},
          else: parse_symbol(cursor)

      {<<c, rest::binary>>, offset, line, column} when c in ?0..?9 ->
        parse_number({<<c, rest::binary>>, offset, line, column})

      {"-" <> <<c, _::binary>>, _offset, _line, _column} when c in ?0..?9 ->
        parse_number(cursor)

      _ ->
        parse_symbol(cursor)
    end
  end

  defp parse_sequence(cursor, close, type, acc, depth) do
    cursor = skip_ws(cursor)

    case cursor do
      {<<^close, rest::binary>>, offset, line, column} ->
        elements = Enum.reverse(acc)
        cursor = {rest, offset + 1, line, column + 1}
        build_sequence(type, elements, cursor)

      {"", _offset, line, column} ->
        {:error, "unclosed #{sequence_name(type)} at line #{line}, column #{column}"}

      _ ->
        with {:ok, ast, cursor} <- parse_expr(cursor, depth + 1) do
          parse_sequence(cursor, close, type, [ast | acc], depth)
        end
    end
  end

  defp build_sequence(:list, elements, cursor), do: {:ok, {:list, elements}, cursor}
  defp build_sequence(:vector, elements, cursor), do: {:ok, {:vector, elements}, cursor}
  defp build_sequence(:set, elements, cursor), do: {:ok, {:set, elements}, cursor}
  defp build_sequence(:short_fn, elements, cursor), do: {:ok, {:short_fn, elements}, cursor}

  defp build_sequence(:map, elements, cursor) do
    if rem(length(elements), 2) == 0 do
      pairs =
        elements
        |> Enum.chunk_every(2)
        |> Enum.map(fn [key, value] -> {key, value} end)

      {:ok, {:map, pairs}, cursor}
    else
      {:error, "Map literal requires even number of forms, got #{length(elements)}"}
    end
  end

  defp sequence_name(:list), do: "list"
  defp sequence_name(:vector), do: "vector"
  defp sequence_name(:map), do: "map"
  defp sequence_name(:set), do: "set"
  defp sequence_name(:short_fn), do: "short function"

  defp parse_string(cursor, tag), do: parse_string(cursor, tag, [])

  defp parse_string({"\"" <> rest, offset, line, column}, tag, acc) do
    value = acc |> Enum.reverse() |> IO.iodata_to_binary()
    node = if tag == :regex_literal, do: {:regex_literal, value}, else: {:string, value}
    {:ok, node, {rest, offset + 1, line, column + 1}}
  end

  defp parse_string({"\\" <> rest, offset, line, column}, tag, acc) do
    case rest do
      "\\" <> rest ->
        parse_string({rest, offset + 2, line, column + 2}, tag, ["\\" | acc])

      "\"" <> rest ->
        parse_string({rest, offset + 2, line, column + 2}, tag, ["\"" | acc])

      "n" <> rest ->
        parse_string({rest, offset + 2, line, column + 2}, tag, ["\n" | acc])

      "t" <> rest ->
        parse_string({rest, offset + 2, line, column + 2}, tag, ["\t" | acc])

      "r" <> rest ->
        parse_string({rest, offset + 2, line, column + 2}, tag, ["\r" | acc])

      <<c, _rest::binary>> when c in [?\n, ?\r] ->
        {:error, "unclosed string at line #{line}, column #{column}"}

      <<c::utf8, rest::binary>> ->
        parse_string({rest, offset + byte_size(<<c::utf8>>) + 1, line, column + 2}, tag, [
          <<?\\, c::utf8>> | acc
        ])

      "" ->
        {:error, "unclosed string at line #{line}, column #{column}"}
    end
  end

  defp parse_string({"\n" <> rest, offset, line, _column}, tag, acc),
    do: parse_string({rest, offset + 1, line + 1, 1}, tag, ["\n" | acc])

  defp parse_string({<<c::utf8, rest::binary>>, offset, line, column}, tag, acc) do
    bytes = byte_size(<<c::utf8>>)
    parse_string({rest, offset + bytes, line, column + 1}, tag, [<<c::utf8>> | acc])
  end

  defp parse_string({"", _offset, line, column}, _tag, _acc),
    do: {:error, "unclosed string at line #{line}, column #{column}"}

  defp parse_char(cursor) do
    named = [
      {"newline", "\n"},
      {"space", " "},
      {"tab", "\t"},
      {"return", "\r"},
      {"backspace", "\b"},
      {"formfeed", "\f"}
    ]

    case Enum.find(named, fn {name, _value} -> match_prefix?(cursor, name) end) do
      {name, value} ->
        {:ok, {:string, value}, advance(cursor, byte_size(name))}

      nil ->
        case cursor do
          {<<c::utf8, _rest::binary>>, _offset, _line, _column} ->
            {:ok, {:string, <<c::utf8>>}, advance(cursor, byte_size(<<c::utf8>>))}

          {"", _offset, line, column} ->
            {:error, "invalid character literal at line #{line}, column #{column}"}
        end
    end
  end

  defp parse_keyword({":" <> rest, offset, line, column}) do
    {name, cursor} = take_while({rest, offset + 1, line, column + 1}, &keyword_char?/1)

    if name == "" do
      {:error, "syntax error: could not parse keyword at line #{line}, column #{column}"}
    else
      {:ok, {:keyword, SourceAtoms.intern(name)}, cursor}
    end
  end

  defp parse_var(cursor) do
    case cursor do
      {<<c, _rest::binary>>, _offset, _line, _column} when is_symbol_first(c) ->
        {name, cursor} = take_symbol(cursor)
        {:ok, {:var, SourceAtoms.intern(name)}, cursor}

      {_rest, _offset, line, column} ->
        {:error, "syntax error: could not parse var at line #{line}, column #{column}"}
    end
  end

  defp parse_quoted_symbol(cursor) do
    case cursor do
      {<<c, _rest::binary>>, _offset, _line, _column} when is_symbol_first(c) ->
        {name, cursor} = take_symbol(cursor)
        {:ok, {:quoted_symbol, name}, cursor}

      {<<c, _rest::binary>>, _offset, line, column} when c in [?(, ?[, ?{] ->
        {:error,
         "quoted collections are not supported; only quoted symbols like 'github are allowed at line #{line}, column #{column}"}

      {_rest, _offset, line, column} ->
        {:error, "syntax error: could not parse quoted symbol at line #{line}, column #{column}"}
    end
  end

  defp parse_symbol(cursor) do
    case cursor do
      {<<c, _rest::binary>>, _offset, _line, _column} when is_symbol_first(c) ->
        {name, cursor} = take_symbol(cursor)
        {:ok, AST.symbol(name), cursor}

      {_rest, _offset, line, column} ->
        {:error, "syntax error: could not parse expression at line #{line}, column #{column}"}
    end
  end

  defp parse_number(cursor) do
    {sign, cursor} =
      case cursor do
        {"-" <> _rest, _offset, _line, _column} -> {"-", advance(cursor, 1)}
        _ -> {"", cursor}
      end

    {int, cursor} = take_while(cursor, &digit?/1)

    cond do
      int == "" ->
        parse_symbol(cursor)

      byte_size(int) > @max_integer_digits ->
        {:error, "integer literal exceeds #{@max_integer_digits} digit limit"}

      match_fraction?(cursor) ->
        {fraction, cursor} = take_fraction(cursor)
        {exponent, cursor} = take_valid_exponent(cursor)
        {:ok, parse_float!(sign <> int <> fraction <> exponent), cursor}

      match_exponent?(cursor) ->
        {exponent, cursor} = take_valid_exponent(cursor)
        {:ok, parse_float!(sign <> int <> exponent), cursor}

      true ->
        {:ok, String.to_integer(sign <> int), cursor}
    end
  end

  defp take_fraction({"." <> rest, offset, line, column}) do
    {digits, cursor} = take_while({rest, offset + 1, line, column + 1}, &digit?/1)
    {"." <> digits, cursor}
  end

  defp take_valid_exponent(cursor) do
    if match_exponent?(cursor) do
      take_exponent(cursor)
    else
      {"", cursor}
    end
  end

  defp take_exponent({<<e, rest::binary>>, offset, line, column}) when e in [?e, ?E] do
    cursor = {rest, offset + 1, line, column + 1}

    {sign, cursor} =
      case cursor do
        {<<s, rest::binary>>, offset, line, column} when s in [?+, ?-] ->
          {<<s>>, {rest, offset + 1, line, column + 1}}

        _ ->
          {"", cursor}
      end

    {digits, cursor} = take_while(cursor, &digit?/1)
    {<<e>> <> sign <> digits, cursor}
  end

  defp parse_float!(source) do
    case Float.parse(source) do
      {float, ""} -> float
      {float, _rest} -> float
      :error -> raise ArgumentError, "invalid float: #{source}"
    end
  end

  defp match_fraction?({"." <> <<c, _rest::binary>>, _offset, _line, _column}), do: digit?(c)
  defp match_fraction?(_cursor), do: false

  defp match_exponent?({<<e, rest::binary>>, _offset, _line, _column}) when e in [?e, ?E] do
    case rest do
      <<c, _::binary>> when c in ?0..?9 -> true
      <<s, c, _::binary>> when s in [?+, ?-] and c in ?0..?9 -> true
      _ -> false
    end
  end

  defp match_exponent?(_cursor), do: false

  defp take_symbol(cursor), do: take_while(cursor, &symbol_rest_char?/1)

  defp take_while({binary, offset, line, column}, predicate) do
    length = take_while_length(binary, predicate, 0)
    value = binary_part(binary, 0, length)
    rest = binary_part(binary, length, byte_size(binary) - length)
    {value, {rest, offset + length, line, column + length}}
  end

  defp take_while_length(<<c, rest::binary>>, predicate, length) when c < 128 do
    if predicate.(c) do
      take_while_length(rest, predicate, length + 1)
    else
      length
    end
  end

  defp take_while_length(_binary, _predicate, length), do: length

  defp skip_inter_expr(cursor) do
    cursor
    |> skip_ws()
    |> skip_extra_closers()
  end

  defp skip_extra_closers({<<c, rest::binary>>, offset, line, column}) when c in [?), ?], ?}] do
    skip_extra_closers(skip_ws({rest, offset + 1, line, column + 1}))
  end

  defp skip_extra_closers(cursor), do: cursor

  defp skip_ws({<<c, rest::binary>>, offset, line, column}) when c in [?\s, ?\t, ?\r, ?,],
    do: skip_ws({rest, offset + 1, line, column + 1})

  defp skip_ws({"\n" <> rest, offset, line, _column}),
    do: skip_ws({rest, offset + 1, line + 1, 1})

  defp skip_ws({";" <> rest, offset, line, column}),
    do: skip_comment({rest, offset + 1, line, column + 1})

  defp skip_ws(cursor), do: cursor

  defp skip_comment({"\n" <> rest, offset, line, _column}),
    do: skip_ws({rest, offset + 1, line + 1, 1})

  defp skip_comment({"", offset, line, column}), do: {"", offset, line, column}

  defp skip_comment({<<_c::utf8, rest::binary>>, offset, line, column}),
    do: skip_comment({rest, offset + 1, line, column + 1})

  defp advance(cursor, 0), do: cursor

  defp advance({"\n" <> rest, offset, line, _column}, bytes),
    do: advance({rest, offset + 1, line + 1, 1}, bytes - 1)

  defp advance({<<_c, rest::binary>>, offset, line, column}, bytes),
    do: advance({rest, offset + 1, line, column + 1}, bytes - 1)

  defp match_prefix?({rest, _offset, _line, _column}, prefix),
    do: String.starts_with?(rest, prefix)

  defp symbol_boundary?(""), do: true
  defp symbol_boundary?(<<c, _rest::binary>>) when c < 128, do: not symbol_rest_char?(c)
  defp symbol_boundary?(_), do: true

  defp digit?(c), do: c in ?0..?9

  defp keyword_char?(c),
    do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?+, ?-, ?*, ?<, ?>, ?=, ??, ?!, ?_]

  defp symbol_rest_char?(c),
    do:
      c in ?a..?z or c in ?A..?Z or c in ?0..?9 or
        c in [?+, ?-, ?*, ?/, ?<, ?>, ?=, ??, ?!, ?_, ?%, ?., ?&, ?']
end
