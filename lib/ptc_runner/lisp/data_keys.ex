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

  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Parser

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

    # Convert to the same direct and hyphen/underscore spellings accepted by
    # runtime data lookup.
    string_keys =
      Enum.reduce(data_keys, MapSet.new(), fn key, keys ->
        key_string = to_string(key)

        keys
        |> MapSet.put(key_string)
        |> MapSet.put(normalize_separator(key_string))
      end)

    # Keep keys that are either:
    # 1. Accessed via data/xxx (in data_keys)
    # 2. Not collections (scalar metadata like "question", "fail", integers, etc.)
    # This filters out unused datasets (lists/maps) while preserving metadata
    Map.filter(ctx, fn {key, value} ->
      case context_key_string(key) do
        {:ok, key_string} ->
          MapSet.member?(string_keys, key_string) or not collection?(value)

        :error ->
          # Retain keys that cannot be rendered so the bounded public-input
          # validator can reject malformed wrapper keys inside the sandbox.
          true
      end
    end)
  end

  @doc false
  @spec prefilter_context(term(), map()) :: map()
  def prefilter_context(ast, ctx) when is_map(ctx) do
    # Never enumerate the host grant here: this pass runs before the bounded
    # setup worker starts. The Core AST is already symbol-bounded, so direct
    # lookups for the statically referenced data keys keep caller work bounded
    # while avoiding a sandbox copy of unrelated grants.
    ast
    |> extract()
    |> Enum.flat_map(&context_lookup_keys/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn key, filtered ->
      case Map.fetch(ctx, key) do
        {:ok, value} -> Map.put(filtered, key, value)
        :error -> filtered
      end
    end)
  end

  defp context_lookup_keys(key) when is_atom(key),
    do: context_lookup_keys(Atom.to_string(key))

  defp context_lookup_keys(<<39, name::binary>> = key) do
    symbol_keys =
      if SymbolRef.valid_name?(name),
        do: [%SymbolRef{name: name}, {:symbol_ref, name}],
        else: []

    ordinary_context_lookup_keys(key, key) ++ symbol_keys
  end

  defp context_lookup_keys(key) when is_binary(key),
    do: ordinary_context_lookup_keys(key, key)

  defp ordinary_context_lookup_keys(key, key_string) do
    normalized = normalize_separator(key_string)

    [key, key_string, LispKeyword.new(key_string)] ++
      existing_atom_key(key_string) ++
      if normalized == key_string,
        do: [],
        else: [normalized | existing_atom_key(normalized)]
  end

  defp existing_atom_key(key) do
    [String.to_existing_atom(key)]
  rescue
    ArgumentError -> []
  end

  # The normal public run path validates and normalizes wrappers before calling
  # this function. A direct caller that supplies a wrapper still gets fail-safe
  # retention instead of unbounded name inspection here.
  defp context_key_string(%{__struct__: SymbolRef}), do: :error

  defp context_key_string(%{__struct__: LispKeyword} = keyword) do
    if LispKeyword.valid?(keyword), do: {:ok, keyword.name}, else: :error
  end

  defp context_key_string({:symbol_ref, name}) when is_binary(name) do
    if SymbolRef.valid_name?(name), do: {:ok, "'" <> name}, else: :error
  end

  defp context_key_string(key) when is_binary(key), do: {:ok, key}
  defp context_key_string(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp context_key_string(key) when is_integer(key), do: {:ok, Integer.to_string(key)}
  defp context_key_string(key) when is_float(key), do: {:ok, Float.to_string(key)}

  defp context_key_string(key) when is_list(key) do
    {:ok, List.to_string(key)}
  rescue
    _exception -> :error
  end

  defp context_key_string(_key), do: :error

  defp normalize_separator(key), do: String.replace(key, "-", "_")

  # Check if a value is a collection that could be a large dataset
  defp collection?(value) when is_list(value), do: true
  defp collection?(%MapSet{}), do: true
  defp collection?(value) when is_map(value) and not is_struct(value), do: true
  defp collection?(_), do: false

  # Data access - the target of our extraction
  defp do_extract({:data, key}, acc) when is_atom(key), do: MapSet.put(acc, key)

  defp do_extract({:data, key}, acc) when is_binary(key),
    do: MapSet.put(acc, existing_atom_or(key))

  # Literal payloads are inert runtime values, even when their data happens to
  # have the shape of a Core AST node.
  defp do_extract({:literal, _value}, acc), do: acc

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

  @doc """
  Returns the sorted `data/<name>` source forms for the keys of `data` that can
  be written as a `data/<name>` reference.

  Names that cannot be parsed as that form are omitted. Every granted-name list
  the runtime publishes or prints comes from here: mission inventory entries and
  the mission and workflow missing-grant diagnostics all consume this rather
  than selecting forms independently, so the list a user is shown always matches
  the list that resolves.

  ## Examples

      iex> PtcRunner.Lisp.DataKeys.source_referenceable_forms(%{"b" => 1, "a" => 2})
      ["data/a", "data/b"]

      iex> PtcRunner.Lisp.DataKeys.source_referenceable_forms(%{"not a symbol" => 1})
      []

  """
  @spec source_referenceable_forms(map()) :: [binary()]
  def source_referenceable_forms(data) when is_map(data) and not is_struct(data) do
    data
    |> Map.keys()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case source_referenceable_form(name) do
        {:ok, form} -> [form]
        :skip -> []
      end
    end)
  end

  defp source_referenceable_form(name) when is_binary(name) do
    case Parser.parse("data/" <> name) do
      {:ok, {:ns_symbol, :data, parsed}} ->
        if to_string(parsed) == name, do: {:ok, "data/" <> name}, else: :skip

      _not_a_source_reference ->
        :skip
    end
  end

  defp source_referenceable_form(_name), do: :skip

  defp existing_atom_or(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
