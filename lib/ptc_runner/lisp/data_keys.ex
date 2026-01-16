defmodule PtcRunner.Lisp.DataKeys do
  @moduledoc """
  Static analysis to extract data keys accessed by a PTC-Lisp program.

  Walks the Core AST to find all `{:data, key}` nodes, which represent
  `data/xxx` access patterns in the source code.

  This enables context optimization by loading only the datasets actually
  needed by the program, reducing memory pressure during execution.

  ## Example

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("(count data/products)")
      iex> {:ok, core_ast} = PtcRunner.Lisp.Analyze.analyze(ast)
      iex> PtcRunner.Lisp.DataKeys.extract(core_ast)
      MapSet.new([:products])

  """

  @doc """
  Extracts all data keys accessed by a program.

  Returns a MapSet of atoms/strings representing the keys accessed via `data/xxx`.

  ## Examples

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("(+ (count data/foo) (count data/bar))")
      iex> {:ok, core_ast} = PtcRunner.Lisp.Analyze.analyze(ast)
      iex> keys = PtcRunner.Lisp.DataKeys.extract(core_ast)
      iex> Enum.sort(keys)
      [:bar, :foo]

  """
  @spec extract(term()) :: MapSet.t()
  def extract(ast) do
    do_extract(ast, MapSet.new())
  end

  @doc """
  Filters a context map to only include keys accessed by the program.

  Keys not present in the context are silently ignored (the program may
  reference data that doesn't exist, which will be handled at runtime).

  ## Examples

      iex> {:ok, ast} = PtcRunner.Lisp.Parser.parse("(count data/products)")
      iex> {:ok, core_ast} = PtcRunner.Lisp.Analyze.analyze(ast)
      iex> ctx = %{"products" => [1,2,3], "orders" => [4,5,6], "question" => "test"}
      iex> PtcRunner.Lisp.DataKeys.filter_context(core_ast, ctx)
      %{"products" => [1,2,3], "question" => "test"}

  """
  @spec filter_context(term(), map()) :: map()
  def filter_context(ast, ctx) when is_map(ctx) do
    # Extract data keys and normalize to strings for consistent lookup
    data_keys = extract(ast)

    # Convert to string set for consistent comparison
    string_keys = Enum.into(data_keys, MapSet.new(), &to_string/1)

    # Keep keys that are either:
    # 1. Accessed via data/xxx (in data_keys)
    # 2. Not collections (scalar metadata like "question", "fail", integers, etc.)
    # This filters out unused datasets (lists/maps) while preserving metadata
    Map.filter(ctx, fn {key, value} ->
      MapSet.member?(string_keys, to_string(key)) or not collection?(value)
    end)
  end

  # Check if a value is a collection that could be a large dataset
  defp collection?(value) when is_list(value), do: true
  defp collection?(%MapSet{}), do: true
  defp collection?(value) when is_map(value) and not is_struct(value), do: true
  defp collection?(_), do: false

  # Data access - the target of our extraction
  defp do_extract({:data, key}, acc) when is_atom(key), do: MapSet.put(acc, key)
  defp do_extract({:data, key}, acc) when is_binary(key), do: MapSet.put(acc, key)

  # Lists - recurse into each element
  defp do_extract(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn elem, a -> do_extract(elem, a) end)
  end

  # Tuples - recurse into each element (but not MapSet which is a struct)
  defp do_extract(%MapSet{}, acc), do: acc

  defp do_extract(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, fn elem, a -> do_extract(elem, a) end)
  end

  # Maps (but not structs) - recurse into keys and values
  defp do_extract(map, acc) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn {k, v}, a -> do_extract(v, do_extract(k, a)) end)
  end

  # Primitives and structs - no data access
  defp do_extract(_other, acc), do: acc
end
