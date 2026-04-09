defmodule PtcRunner.Evolve.Operators do
  @moduledoc """
  Genetic programming operators for PTC-Lisp ASTs.

  Provides mutation and crossover operators that work directly on parsed ASTs.
  All operators return `{:ok, new_ast}` or `{:error, reason}`.
  """

  alias PtcRunner.Evolve.Individual

  # Synonyms for point mutation on function symbols
  @symbol_synonyms %{
    filter: [:remove],
    remove: [:filter],
    +: [:-],
    -: [:+],
    *: [:/],
    /: [:*],
    >: [:<, :>=, :<=],
    <: [:>, :>=, :<=],
    >=: [:>, :<, :<=],
    <=: [:<, :>, :>=],
    first: [:last, :second],
    last: [:first],
    count: [:empty?],
    map: [:mapv, :filter],
    mapv: [:map],
    sort: [:reverse],
    reverse: [:sort],
    keys: [:vals],
    vals: [:keys],
    inc: [:dec],
    dec: [:inc]
  }

  # Common wrapping functions
  @wrap_fns [:count, :first, :last, :sort, :reverse, :keys, :vals, :str]

  # Maps external operator names (used by M) to internal mutation operator names
  @operator_mapping %{
    point_mutation: :point_literal,
    arg_swap: :arg_swap,
    wrap_form: :wrap,
    subtree_delete: :subtree_delete,
    subtree_dup: :subtree_dup,
    crossover: :point_symbol
  }

  @doc """
  Apply a random mutation to an individual, returning a new individual.

  Picks one of the cheap mutation operators at random and applies it.
  Returns `{:ok, new_individual}` or `{:error, reason}`.

  Options:
  - `:operator` — an explicit operator atom (from M's selection). Maps external names
    like `:point_mutation` to internal operators. If not provided, picks randomly.
  """
  @spec mutate(Individual.t(), keyword()) :: {:ok, Individual.t()} | {:error, term()}
  def mutate(individual, opts \\ [])

  def mutate(%Individual{ast: ast, id: parent_id, generation: gen}, opts) do
    operator =
      case Keyword.get(opts, :operator) do
        nil ->
          Enum.random([
            :point_literal,
            :point_symbol,
            :arg_swap,
            :subtree_delete,
            :subtree_dup,
            :wrap
          ])

        external_op ->
          Map.get(@operator_mapping, external_op, :point_literal)
      end

    case apply_mutation(ast, operator) do
      {:ok, new_ast} ->
        new_source = format_ast(new_ast)

        case Individual.from_source(new_source,
               parent_ids: [parent_id],
               generation: gen + 1,
               metadata: %{operator: operator}
             ) do
          {:ok, ind} -> {:ok, ind}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Subtree crossover between two individuals.

  Finds `{:list, ...}` nodes (function calls) in both parents that call the same
  function, then swaps a subtree between them. Falls back to mutation if no
  compatible crossover point exists.
  """
  @spec crossover(Individual.t(), Individual.t()) :: {:ok, Individual.t()} | {:error, term()}
  def crossover(%Individual{ast: ast_a, id: id_a}, %Individual{
        ast: ast_b,
        id: id_b,
        generation: gen
      }) do
    calls_a = collect_calls(ast_a)
    calls_b = collect_calls(ast_b)

    # Find function names that appear in both
    fns_a = MapSet.new(Enum.map(calls_a, &elem(&1, 0)))
    fns_b = MapSet.new(Enum.map(calls_b, &elem(&1, 0)))
    common_fns = MapSet.intersection(fns_a, fns_b) |> MapSet.to_list()

    if common_fns == [] do
      {:error, :no_compatible_crossover}
    else
      fn_name = Enum.random(common_fns)

      # Get a random subtree from B that is an arg to fn_name
      donor_subtrees =
        calls_b
        |> Enum.filter(fn {name, _path, _args} -> name == fn_name end)
        |> Enum.flat_map(fn {_name, _path, args} -> args end)

      if donor_subtrees == [] do
        {:error, :no_compatible_crossover}
      else
        donor = Enum.random(donor_subtrees)

        # Replace a random arg of fn_name in A with the donor
        new_ast = replace_random_arg(ast_a, fn_name, donor)

        new_source = format_ast(new_ast)

        Individual.from_source(new_source,
          parent_ids: [id_a, id_b],
          generation: gen + 1,
          metadata: %{operator: :crossover, crossover_fn: fn_name}
        )
      end
    end
  end

  # === Mutation Implementations ===

  defp apply_mutation(ast, :point_literal) do
    positions = collect_literals(ast)

    if positions == [] do
      {:error, :no_literals}
    else
      target = Enum.random(positions)
      new_val = mutate_literal(target)
      {:ok, replace_at_path(ast, path_to(ast, target), new_val)}
    end
  end

  defp apply_mutation(ast, :point_symbol) do
    positions = collect_function_symbols(ast)

    if positions == [] do
      {:error, :no_function_symbols}
    else
      {sym, path} = Enum.random(positions)
      synonyms = Map.get(@symbol_synonyms, sym, [])

      if synonyms == [] do
        {:error, :no_synonyms}
      else
        new_sym = Enum.random(synonyms)
        {:ok, replace_at_path(ast, path, {:symbol, new_sym})}
      end
    end
  end

  defp apply_mutation(ast, :arg_swap) do
    calls = collect_calls_with_paths(ast)
    multi_arg_calls = Enum.filter(calls, fn {_path, args} -> length(args) >= 2 end)

    if multi_arg_calls == [] do
      {:error, :no_multi_arg_calls}
    else
      {path, args} = Enum.random(multi_arg_calls)
      [i, j] = Enum.take_random(0..(length(args) - 1), 2) |> Enum.sort()

      swapped =
        args |> List.replace_at(i, Enum.at(args, j)) |> List.replace_at(j, Enum.at(args, i))

      {:ok, replace_call_args(ast, path, swapped)}
    end
  end

  defp apply_mutation(ast, :subtree_delete) do
    # Replace a random non-root subtree with a simple literal or symbol
    subtrees = collect_subtree_paths(ast) |> Enum.filter(fn p -> p != [] end)

    if subtrees == [] do
      {:error, :no_subtrees}
    else
      path = Enum.random(subtrees)
      replacement = Enum.random([0, 1, nil, true, {:keyword, :id}, {:string, ""}])
      {:ok, replace_at_path(ast, path, replacement)}
    end
  end

  defp apply_mutation(ast, :subtree_dup) do
    subtrees = collect_subtree_paths(ast) |> Enum.filter(fn p -> p != [] end)

    if length(subtrees) < 2 do
      {:error, :not_enough_subtrees}
    else
      [src_path, dst_path] = Enum.take_random(subtrees, 2)
      src_node = get_at_path(ast, src_path)
      {:ok, replace_at_path(ast, dst_path, src_node)}
    end
  end

  defp apply_mutation(ast, :wrap) do
    subtrees = collect_subtree_paths(ast) |> Enum.filter(fn p -> p != [] end)

    if subtrees == [] do
      {:error, :no_subtrees}
    else
      path = Enum.random(subtrees)
      node = get_at_path(ast, path)
      wrapper = Enum.random(@wrap_fns)
      wrapped = {:list, [{:symbol, wrapper}, node]}
      {:ok, replace_at_path(ast, path, wrapped)}
    end
  end

  # === AST Traversal Helpers ===

  defp collect_literals(ast), do: collect_literals(ast, []) |> List.flatten()

  defp collect_literals(x, _path) when is_number(x), do: [x]
  defp collect_literals({:string, _} = x, _path), do: [x]
  defp collect_literals({:keyword, _} = x, _path), do: [x]

  defp collect_literals({:vector, items}, path),
    do:
      Enum.with_index(items)
      |> Enum.flat_map(fn {item, i} -> collect_literals(item, path ++ [{:vector, i}]) end)

  defp collect_literals({:list, items}, path),
    do:
      Enum.with_index(items)
      |> Enum.flat_map(fn {item, i} -> collect_literals(item, path ++ [{:list, i}]) end)

  defp collect_literals({:map, pairs}, path),
    do:
      Enum.with_index(pairs)
      |> Enum.flat_map(fn {{k, v}, i} ->
        collect_literals(k, path ++ [{:map_key, i}]) ++
          collect_literals(v, path ++ [{:map_val, i}])
      end)

  defp collect_literals(_, _path), do: []

  defp mutate_literal(x) when is_integer(x), do: x + Enum.random([-2, -1, 1, 2])
  defp mutate_literal(x) when is_float(x), do: x * (1.0 + (:rand.uniform() - 0.5) * 0.2)
  defp mutate_literal({:string, s}), do: {:string, s <> "_mut"}

  defp mutate_literal({:keyword, _}),
    do:
      {:keyword,
       Enum.random([:id, :name, :price, :status, :category, :total, :department, :salary])}

  defp mutate_literal(_), do: 0

  defp collect_function_symbols(ast), do: do_collect_fn_syms(ast, [])

  defp do_collect_fn_syms({:list, [{:symbol, name} | args]}, path) do
    children =
      args
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {arg, i} -> do_collect_fn_syms(arg, path ++ [{:list, i}]) end)

    [{name, path ++ [{:list, 0}]} | children]
  end

  defp do_collect_fn_syms({:list, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_fn_syms(item, path ++ [{:list, i}]) end)
  end

  defp do_collect_fn_syms({:vector, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_fn_syms(item, path ++ [{:vector, i}]) end)
  end

  defp do_collect_fn_syms(_, _), do: []

  defp collect_calls(ast), do: do_collect_calls(ast, [])

  defp do_collect_calls({:list, [{:symbol, name} | args]}, path) do
    children =
      args
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {arg, i} -> do_collect_calls(arg, path ++ [{:list, i}]) end)

    [{name, path, args} | children]
  end

  defp do_collect_calls({:list, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_calls(item, path ++ [{:list, i}]) end)
  end

  defp do_collect_calls({:vector, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_calls(item, path ++ [{:vector, i}]) end)
  end

  defp do_collect_calls(_, _), do: []

  defp collect_calls_with_paths(ast), do: do_collect_cwp(ast, [])

  defp do_collect_cwp({:list, [{:symbol, _name} | args] = _items}, path) do
    children =
      args
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {arg, i} -> do_collect_cwp(arg, path ++ [{:list, i}]) end)

    [{path, args} | children]
  end

  defp do_collect_cwp({:list, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_cwp(item, path ++ [{:list, i}]) end)
  end

  defp do_collect_cwp({:vector, items}, path) do
    Enum.with_index(items)
    |> Enum.flat_map(fn {item, i} -> do_collect_cwp(item, path ++ [{:vector, i}]) end)
  end

  defp do_collect_cwp(_, _), do: []

  defp collect_subtree_paths(ast), do: do_collect_paths(ast, [])

  defp do_collect_paths({:list, items}, path) do
    children =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> do_collect_paths(item, path ++ [{:list, i}]) end)

    [path | children]
  end

  defp do_collect_paths({:vector, items}, path) do
    children =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, i} -> do_collect_paths(item, path ++ [{:vector, i}]) end)

    [path | children]
  end

  defp do_collect_paths({:map, pairs}, path) do
    children =
      pairs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{k, v}, i} ->
        do_collect_paths(k, path ++ [{:map_key, i}]) ++
          do_collect_paths(v, path ++ [{:map_val, i}])
      end)

    [path | children]
  end

  defp do_collect_paths(_, path), do: [path]

  # === Path-based AST manipulation ===

  defp get_at_path(node, []), do: node

  defp get_at_path({:list, items}, [{:list, idx} | rest]) do
    get_at_path(Enum.at(items, idx), rest)
  end

  defp get_at_path({:vector, items}, [{:vector, idx} | rest]) do
    get_at_path(Enum.at(items, idx), rest)
  end

  defp get_at_path(_, _), do: nil

  defp replace_at_path(_node, [], replacement), do: replacement

  defp replace_at_path({:list, items}, [{:list, idx} | rest], replacement) do
    new_items =
      List.replace_at(items, idx, replace_at_path(Enum.at(items, idx), rest, replacement))

    {:list, new_items}
  end

  defp replace_at_path({:vector, items}, [{:vector, idx} | rest], replacement) do
    new_items =
      List.replace_at(items, idx, replace_at_path(Enum.at(items, idx), rest, replacement))

    {:vector, new_items}
  end

  defp replace_at_path({:map, pairs}, [{:map_key, idx} | rest], replacement) do
    {_k, v} = Enum.at(pairs, idx)

    new_pairs =
      List.replace_at(
        pairs,
        idx,
        {replace_at_path(Enum.at(pairs, idx) |> elem(0), rest, replacement), v}
      )

    {:map, new_pairs}
  end

  defp replace_at_path({:map, pairs}, [{:map_val, idx} | rest], replacement) do
    {k, _v} = Enum.at(pairs, idx)

    new_pairs =
      List.replace_at(
        pairs,
        idx,
        {k, replace_at_path(Enum.at(pairs, idx) |> elem(1), rest, replacement)}
      )

    {:map, new_pairs}
  end

  defp replace_at_path(node, _, _), do: node

  defp replace_call_args(ast, [], new_args) do
    case ast do
      {:list, [fn_sym | _old_args]} -> {:list, [fn_sym | new_args]}
      other -> other
    end
  end

  defp replace_call_args({:list, items}, [{:list, idx} | rest], new_args) do
    new_items =
      List.replace_at(items, idx, replace_call_args(Enum.at(items, idx), rest, new_args))

    {:list, new_items}
  end

  defp replace_call_args(node, _, _), do: node

  defp replace_random_arg(ast, fn_name, donor) do
    do_replace_random_arg(ast, fn_name, donor, :rand.uniform())
  end

  defp do_replace_random_arg({:list, [{:symbol, name} | args]}, fn_name, donor, rand)
       when args != [] do
    if name == fn_name and rand < 0.5 do
      idx = :rand.uniform(length(args)) - 1
      new_args = List.replace_at(args, idx, donor)
      {:list, [{:symbol, name} | new_args]}
    else
      {:list,
       [{:symbol, name} | Enum.map(args, &do_replace_random_arg(&1, fn_name, donor, rand))]}
    end
  end

  defp do_replace_random_arg({:list, items}, fn_name, donor, rand) do
    {:list, Enum.map(items, &do_replace_random_arg(&1, fn_name, donor, rand))}
  end

  defp do_replace_random_arg({:vector, items}, fn_name, donor, rand) do
    {:vector, Enum.map(items, &do_replace_random_arg(&1, fn_name, donor, rand))}
  end

  defp do_replace_random_arg(node, _fn_name, _donor, _rand), do: node

  # Use path_to to find the path to a specific node (by identity)
  defp path_to(ast, target), do: do_path_to(ast, target, [])

  defp do_path_to(node, target, path) when node == target, do: path

  defp do_path_to({:list, items}, target, path) do
    Enum.with_index(items)
    |> Enum.find_value(fn {item, i} -> do_path_to(item, target, path ++ [{:list, i}]) end)
  end

  defp do_path_to({:vector, items}, target, path) do
    Enum.with_index(items)
    |> Enum.find_value(fn {item, i} -> do_path_to(item, target, path ++ [{:vector, i}]) end)
  end

  defp do_path_to({:map, pairs}, target, path) do
    Enum.with_index(pairs)
    |> Enum.find_value(fn {{k, v}, i} ->
      do_path_to(k, target, path ++ [{:map_key, i}]) ||
        do_path_to(v, target, path ++ [{:map_val, i}])
    end)
  end

  defp do_path_to(_, _, _), do: nil

  @doc """
  Format an AST back to PTC-Lisp source code.
  """
  @spec format_ast(term()) :: String.t()
  def format_ast(ast) do
    do_format(ast)
  end

  defp do_format(nil), do: "nil"
  defp do_format(true), do: "true"
  defp do_format(false), do: "false"
  defp do_format(x) when is_integer(x), do: Integer.to_string(x)
  defp do_format(x) when is_float(x), do: Float.to_string(x)
  defp do_format({:string, s}), do: ~s("#{s}")
  defp do_format({:keyword, k}), do: ":#{k}"
  defp do_format({:symbol, s}), do: Atom.to_string(s)
  defp do_format({:ns_symbol, ns, name}), do: "#{ns}/#{name}"
  defp do_format({:turn_history, n}), do: "*#{n}"

  defp do_format({:vector, items}) do
    inner = Enum.map_join(items, " ", &do_format/1)
    "[#{inner}]"
  end

  defp do_format({:set, items}) do
    inner = Enum.map_join(items, " ", &do_format/1)
    "\#{#{inner}}"
  end

  defp do_format({:map, pairs}) do
    inner =
      Enum.map_join(pairs, " ", fn {k, v} -> "#{do_format(k)} #{do_format(v)}" end)

    "{#{inner}}"
  end

  defp do_format({:list, items}) do
    inner = Enum.map_join(items, " ", &do_format/1)
    "(#{inner})"
  end

  defp do_format(other), do: inspect(other)
end
