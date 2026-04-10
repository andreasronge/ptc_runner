defmodule PtcRunner.Folding.Direct do
  @moduledoc """
  Direct encoding baseline — no folding.

  Uses the same alphabet as the folding system but maps genotype to phenotype
  sequentially: read characters left-to-right, skip spacers, and build a
  PTC-Lisp expression by recursive descent.

  This is the control for measuring whether folding adds value. Same alphabet,
  same genetic operators, same evaluation — only the genotype-to-phenotype
  mapping differs.

  ## Mapping Rules

  Read the genotype left-to-right, skipping spacers. Build an expression:

  - **Higher-order functions** (A=filter, C=map, E=reduce, F=group-by):
    consume the next two sub-expressions as `(fn data)`.
    Wraps the first sub-expression in `(fn [x] ...)` automatically.
  - **Wrappers** (B=count, I=first): consume the next sub-expression as `(op expr)`
  - **Get** (D): consume the next sub-expression as field key → `(get x key)`
  - **Set** (G): consume the next sub-expression → `(set expr)`
  - **Contains?** (H): consume the next two sub-expressions → `(contains? expr expr)`
  - **Comparators** (J=+, K=>, L=<, M==): consume next two sub-expressions
  - **Logical** (N=and, O=or): consume next two sub-expressions
  - **Not** (P): consume next one sub-expression
  - **Fn** (Q): consume next sub-expression, wrap in `(fn [x] ...)`
  - **Let** (R): consume next two sub-expressions → `(let [x expr1] expr2)`
  - **Data sources** (S-V): leaf, returns `data/name`
  - **Field keys** (a-h): leaf, returns `:key`
  - **Digits** (0-9): leaf, returns number
  - **Spacers**: skipped entirely
  """

  alias PtcRunner.Evolve.Operators, as: ASTFormat
  alias PtcRunner.Folding.Alphabet

  @doc """
  Develop a genotype string into a PTC-Lisp phenotype using direct encoding.

  Returns `{:ok, source}` or `{:error, :no_expression}`.

  ## Examples

      iex> {:ok, source} = PtcRunner.Folding.Direct.develop("BS")
      iex> source
      "(count data/products)"
  """
  @spec develop(String.t()) :: {:ok, String.t()} | {:error, :no_expression}
  def develop(genotype) when is_binary(genotype) do
    tokens =
      genotype
      |> String.to_charlist()
      |> Enum.reject(fn c -> Alphabet.to_fragment(c) == :spacer end)

    case parse_expression(tokens) do
      {ast, _rest} when ast != nil ->
        {:ok, ASTFormat.format_ast(ast)}

      _ ->
        {:error, :no_expression}
    end
  end

  @doc """
  Develop with debug info, matching the Phenotype.develop_debug/1 interface.
  """
  @spec develop_debug(String.t()) :: map()
  def develop_debug(genotype) when is_binary(genotype) do
    case develop(genotype) do
      {:ok, source} ->
        %{
          genotype: genotype,
          source: source,
          valid?: true,
          encoding: :direct
        }

      {:error, _} ->
        %{
          genotype: genotype,
          source: nil,
          valid?: false,
          encoding: :direct
        }
    end
  end

  # === Recursive Descent Parser ===

  # Returns {ast_node, remaining_tokens}
  defp parse_expression([]), do: {nil, []}

  defp parse_expression([char | rest]) do
    case Alphabet.to_fragment(char) do
      {:fn_fragment, op} -> parse_fn_fragment(op, rest)
      {:comparator, op} -> parse_binary_op(op, rest)
      {:connective, op} -> parse_connective(op, rest)
      {:data_source, name} -> {{:ns_symbol, :data, name}, rest}
      {:field_key, key} -> {{:keyword, key}, rest}
      {:literal, n} -> {n, rest}
      :spacer -> parse_expression(rest)
    end
  end

  # Higher-order: consume fn-body + data -> (op (fn [x] body) data)
  defp parse_fn_fragment(op, rest) when op in [:filter, :map, :group_by] do
    {body, rest1} = parse_expression(rest)
    {data, rest2} = parse_expression(rest1)

    if body != nil and data != nil do
      fn_ast = {:list, [{:symbol, :fn}, {:vector, [{:symbol, :x}]}, body]}
      {{:list, [{:symbol, op}, fn_ast, data]}, rest2}
    else
      fallback_leaf(op, rest)
    end
  end

  # Reduce: consume fn-body + init + data
  defp parse_fn_fragment(:reduce, rest) do
    {body, rest1} = parse_expression(rest)
    {init, rest2} = parse_expression(rest1)
    {data, rest3} = parse_expression(rest2)

    if body != nil and init != nil and data != nil do
      fn_ast = {:list, [{:symbol, :fn}, {:vector, [{:symbol, :x}]}, body]}
      {{:list, [{:symbol, :reduce}, fn_ast, init, data]}, rest3}
    else
      fallback_leaf(:reduce, rest)
    end
  end

  # Wrappers: consume one expression -> (op expr)
  defp parse_fn_fragment(op, rest) when op in [:count, :first] do
    parse_unary_op(op, rest)
  end

  # Get: consume next as field key -> (get x key)
  defp parse_fn_fragment(:get, rest) do
    {key_expr, rest1} = parse_expression(rest)

    if key_expr != nil do
      {{:list, [{:symbol, :get}, {:symbol, :x}, key_expr]}, rest1}
    else
      fallback_leaf(:get, rest)
    end
  end

  # Set: consume one expression
  defp parse_fn_fragment(:set, rest), do: parse_unary_op(:set, rest)

  # Contains?: consume two expressions
  defp parse_fn_fragment(:contains?, rest), do: parse_binary_op(:contains?, rest)

  # Fn: consume one expression, wrap in (fn [x] ...)
  defp parse_fn_fragment(:fn, rest) do
    {expr, rest1} = parse_expression(rest)

    if expr != nil do
      {{:list, [{:symbol, :fn}, {:vector, [{:symbol, :x}]}, expr]}, rest1}
    else
      {nil, rest}
    end
  end

  # Let: consume two expressions -> (let [x expr1] expr2)
  defp parse_fn_fragment(:let, rest) do
    {e1, rest1} = parse_expression(rest)
    {e2, rest2} = parse_expression(rest1)

    if e1 != nil and e2 != nil do
      {{:list, [{:symbol, :let}, {:vector, [{:symbol, :x}, e1]}, e2]}, rest2}
    else
      fallback_leaf(:let, rest)
    end
  end

  # Logical connectives
  defp parse_connective(op, rest) when op in [:and, :or], do: parse_binary_op(op, rest)
  defp parse_connective(:not, rest), do: parse_unary_op(:not, rest)

  # Generic unary operator: consume one expression
  defp parse_unary_op(op, rest) do
    {expr, rest1} = parse_expression(rest)

    if expr != nil do
      {{:list, [{:symbol, op}, expr]}, rest1}
    else
      fallback_leaf(op, rest)
    end
  end

  # Generic binary operator: consume two expressions
  defp parse_binary_op(op, rest) do
    {e1, rest1} = parse_expression(rest)
    {e2, rest2} = parse_expression(rest1)

    if e1 != nil and e2 != nil do
      {{:list, [{:symbol, op}, e1, e2]}, rest2}
    else
      fallback_leaf(op, rest)
    end
  end

  # When a function can't get enough arguments, return as bare symbol
  defp fallback_leaf(op, rest), do: {{:symbol, op}, rest}
end
