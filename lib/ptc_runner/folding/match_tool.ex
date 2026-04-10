defmodule PtcRunner.Folding.MatchTool do
  @moduledoc """
  Structural pattern matching tool for interactive coevolution.

  Matches a PTC-Lisp source string against a pattern string with `*` wildcards.
  The pattern is matched against the source structurally — `*` matches any single
  balanced subexpression (respecting parentheses), not just any substring.

  ## Pattern Language

  - `*` matches any single balanced token or parenthesized expression
  - Literal tokens match exactly: `count`, `data/products`, `:price`, `500`
  - Parenthesized patterns match parenthesized expressions: `(count *)` matches
    `(count data/products)` but not `(filter (fn [x] ...) data/products)`

  ## Examples

      iex> PtcRunner.Folding.MatchTool.matches?("(count data/products)", "(count *)")
      true

      iex> PtcRunner.Folding.MatchTool.matches?("(filter (fn [x] (> (get x :price) 500)) data/products)", "(filter * *)")
      true

      iex> PtcRunner.Folding.MatchTool.matches?("(count data/products)", "(filter * *)")
      false

  ## Used As

  Called as `(tool/match {:pattern "(count *)"})` from PTC-Lisp.
  The peer source is injected into context as `peer_source` by the
  interactive coevolution runtime.
  """

  @doc """
  Check if a source string matches a pattern with wildcards.

  The `*` wildcard matches any single balanced subexpression:
  - A single token: `count`, `500`, `:price`, `data/products`
  - A balanced parenthesized expression: `(fn [x] (> (get x :price) 500))`
  - A balanced bracketed expression: `[x]`
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(source, pattern) do
    source_tokens = tokenize(String.trim(source))
    pattern_tokens = tokenize(String.trim(pattern))
    match_tokens(pattern_tokens, source_tokens)
  end

  @doc """
  Build a tool executor function for use in interactive coevolution.

  Returns a function that handles `tool/match` calls. The peer source
  is looked up from the context at call time.
  """
  @spec tool_executor(String.t() | nil) :: (String.t(), map() -> {:ok, term()})
  def tool_executor(peer_source) do
    source = peer_source || ""

    fn "match", args ->
      pattern = Map.get(args, "pattern", "")
      {:ok, matches?(source, pattern)}
    end
  end

  # === Tokenizer ===
  # Splits source into balanced tokens: atoms, numbers, strings, keywords,
  # and balanced groups (parenthesized or bracketed expressions as single tokens).

  defp tokenize(str) do
    str
    |> String.trim()
    |> do_tokenize([])
    |> Enum.reverse()
  end

  defp do_tokenize("", acc), do: acc

  defp do_tokenize(<<c, rest::binary>>, acc) when c in [?\s, ?\n, ?\t, ?\r] do
    do_tokenize(rest, acc)
  end

  defp do_tokenize(<<"(", rest::binary>>, acc) do
    {group, remaining} = read_balanced(rest, ?(, ?), 1, "(")
    do_tokenize(remaining, [group | acc])
  end

  defp do_tokenize(<<"[", rest::binary>>, acc) do
    {group, remaining} = read_balanced(rest, ?[, ?], 1, "[")
    do_tokenize(remaining, [group | acc])
  end

  defp do_tokenize(<<?", rest::binary>>, acc) do
    {str_token, remaining} = read_string(rest, "\"")
    do_tokenize(remaining, [str_token | acc])
  end

  defp do_tokenize(str, acc) do
    {token, remaining} = read_atom(str, "")
    if token == "", do: acc, else: do_tokenize(remaining, [token | acc])
  end

  # Read until matching close delimiter, respecting nesting
  defp read_balanced("", _open, _close, _depth, acc), do: {acc, ""}

  defp read_balanced(<<c, rest::binary>>, _open, close, 1, acc) when c == close do
    {acc <> <<c>>, rest}
  end

  defp read_balanced(<<c, rest::binary>>, open, close, depth, acc) when c == close do
    read_balanced(rest, open, close, depth - 1, acc <> <<c>>)
  end

  defp read_balanced(<<c, rest::binary>>, open, close, depth, acc) when c == open do
    read_balanced(rest, open, close, depth + 1, acc <> <<c>>)
  end

  defp read_balanced(<<c, rest::binary>>, open, close, depth, acc) do
    read_balanced(rest, open, close, depth, acc <> <<c>>)
  end

  # Read a quoted string
  defp read_string("", acc), do: {acc, ""}
  defp read_string(<<"\\\"", rest::binary>>, acc), do: read_string(rest, acc <> "\\\"")

  defp read_string(<<?", rest::binary>>, acc) do
    {acc <> "\"", rest}
  end

  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, acc <> <<c>>)

  # Read a non-delimited token (symbol, keyword, number)
  defp read_atom("", acc), do: {acc, ""}

  defp read_atom(<<c, _rest::binary>> = str, acc)
       when c in [?\s, ?\n, ?\t, ?\r, ?(, ?), ?[, ?], ?{, ?}] do
    {acc, str}
  end

  defp read_atom(<<c, rest::binary>>, acc), do: read_atom(rest, acc <> <<c>>)

  # === Pattern Matching ===

  # Both empty → match
  defp match_tokens([], []), do: true
  # Pattern empty but source has more → no match
  defp match_tokens([], [_ | _]), do: false
  # Pattern has more but source empty → no match (unless remaining pattern is all *)
  defp match_tokens([_ | _], []), do: false

  # Wildcard matches any single token (including balanced groups)
  defp match_tokens(["*" | p_rest], [_s_head | s_rest]) do
    match_tokens(p_rest, s_rest)
  end

  # Parenthesized pattern matches parenthesized source — recurse into contents
  defp match_tokens([p_head | p_rest], [s_head | s_rest]) do
    if paren_group?(p_head) and paren_group?(s_head) do
      # Strip outer parens/brackets and match inner tokens
      p_inner = strip_delimiters(p_head)
      s_inner = strip_delimiters(s_head)
      match_tokens(tokenize(p_inner), tokenize(s_inner)) and match_tokens(p_rest, s_rest)
    else
      # Literal token match
      p_head == s_head and match_tokens(p_rest, s_rest)
    end
  end

  defp paren_group?(str) when is_binary(str) do
    String.starts_with?(str, "(") or String.starts_with?(str, "[")
  end

  defp strip_delimiters(str) do
    str
    |> String.slice(1, String.length(str) - 2)
    |> String.trim()
  end
end
