defmodule PtcRunner.Lisp.SymbolCounter do
  @moduledoc """
  Counts unique user-defined symbols and keywords in a parsed Lisp AST.

  Used to enforce the `max_symbols` limit, preventing atom table exhaustion
  from malicious programs that create many unique symbols/keywords.

  Core language symbols (special forms like `if`, `let`, `fn`) are excluded
  from the count since they're predefined and don't contribute to atom exhaustion.
  """

  # Core language symbols that don't count toward the limit.
  # These are already atoms in the BEAM and won't exhaust the atom table.
  @core_symbols MapSet.new([
                  # Special forms
                  :let,
                  :if,
                  :fn,
                  :when,
                  :"if-let",
                  :"when-let",
                  :cond,
                  :do,
                  :and,
                  :not,
                  :or,
                  :"->>",
                  :->,
                  :where,
                  :"all-of",
                  :"any-of",
                  :"none-of",
                  :call,
                  :return,
                  :fail,
                  # Comparison operators
                  :=,
                  :"not=",
                  :>,
                  :<,
                  :>=,
                  :<=,
                  # Namespaces
                  :ctx,
                  :memory,
                  # Common keywords
                  :else
                ])

  @doc """
  Counts unique non-core symbols and keywords in the AST.

  Returns the count of unique user-defined atoms that would be created
  when parsing/evaluating the program.

  ## Examples

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("{:a 1 :b 2}")
      iex> PtcRunner.Lisp.SymbolCounter.count(ast)
      2

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("{:a 1 :a 2}")
      iex> PtcRunner.Lisp.SymbolCounter.count(ast)
      1

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("(if true 1 2)")
      iex> PtcRunner.Lisp.SymbolCounter.count(ast)
      0
  """
  @spec count(term()) :: non_neg_integer()
  def count(ast) do
    ast
    |> collect_symbols(MapSet.new())
    |> MapSet.size()
  end

  # Recursively collect unique non-core symbols and keywords from AST

  defp collect_symbols({:symbol, name}, acc) when is_atom(name) do
    if MapSet.member?(@core_symbols, name) do
      acc
    else
      MapSet.put(acc, name)
    end
  end

  defp collect_symbols({:keyword, name}, acc) when is_atom(name) do
    if MapSet.member?(@core_symbols, name) do
      acc
    else
      MapSet.put(acc, name)
    end
  end

  defp collect_symbols({:ns_symbol, _ns, key}, acc) when is_atom(key) do
    # Namespaced symbols like ctx/foo - count the key part
    if MapSet.member?(@core_symbols, key) do
      acc
    else
      MapSet.put(acc, key)
    end
  end

  # Turn history symbols (*1, *2, *3) don't create new atoms
  defp collect_symbols({:turn_history, _n}, acc), do: acc

  defp collect_symbols({:vector, elems}, acc) do
    Enum.reduce(elems, acc, fn elem, inner_acc -> collect_symbols(elem, inner_acc) end)
  end

  defp collect_symbols({:list, elems}, acc) do
    Enum.reduce(elems, acc, fn elem, inner_acc -> collect_symbols(elem, inner_acc) end)
  end

  defp collect_symbols({:map, pairs}, acc) do
    Enum.reduce(pairs, acc, fn {k, v}, inner_acc ->
      inner_acc = collect_symbols(k, inner_acc)
      collect_symbols(v, inner_acc)
    end)
  end

  defp collect_symbols({:set, elems}, acc) do
    Enum.reduce(elems, acc, fn elem, inner_acc -> collect_symbols(elem, inner_acc) end)
  end

  defp collect_symbols({:short_fn, body_asts}, acc) do
    Enum.reduce(body_asts, acc, fn elem, inner_acc -> collect_symbols(elem, inner_acc) end)
  end

  # Literals and strings don't create atoms
  defp collect_symbols({:string, _}, acc), do: acc
  defp collect_symbols(n, acc) when is_number(n), do: acc
  defp collect_symbols(b, acc) when is_boolean(b), do: acc
  defp collect_symbols(nil, acc), do: acc
end
