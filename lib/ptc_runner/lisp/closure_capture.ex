defmodule PtcRunner.Lisp.ClosureCapture do
  @moduledoc """
  Scope-aware helpers for determining which names a closure body references.
  """

  alias PtcRunner.Lisp.CoreAST

  # Collects the free `{:var, _}` names in a CoreAST subtree, normalized to
  # strings. Known binding forms are handled with their lexical scope; any
  # unrecognized tuple/list/map is still recursed into so a future AST node
  # cannot silently cause a referenced var to be missed.
  @spec referenced_vars(term(), CoreAST.fn_params(), [CoreAST.name()]) :: MapSet.t(String.t())
  def referenced_vars(ast, params, extra_bound_names \\ []) do
    initial_bound =
      params
      |> bound_names_from_params()
      |> MapSet.union(normalize_name_set(extra_bound_names))

    collect_free_var_refs(ast, MapSet.new(), initial_bound)
  end

  defp collect_free_var_refs({:var, name}, acc, bound) do
    name = to_string(name)

    if MapSet.member?(bound, name) do
      acc
    else
      MapSet.put(acc, name)
    end
  end

  defp collect_free_var_refs({:let, bindings, body}, acc, bound) do
    collect_free_refs_in_bindings(bindings, body, acc, bound)
  end

  defp collect_free_var_refs({:loop, bindings, body}, acc, bound) do
    collect_free_refs_in_bindings(bindings, body, acc, bound)
  end

  defp collect_free_var_refs({:fn, params, body}, acc, bound) do
    collect_free_var_refs(body, acc, MapSet.union(bound, bound_names_from_params(params)))
  end

  defp collect_free_var_refs({:fn, name, params, body}, acc, bound) do
    inner_bound =
      bound
      |> MapSet.union(bound_names_from_params(params))
      |> MapSet.put(to_string(name))

    collect_free_var_refs(body, acc, inner_bound)
  end

  defp collect_free_var_refs(tuple, acc, bound) when is_tuple(tuple) do
    collect_free_var_refs(Tuple.to_list(tuple), acc, bound)
  end

  defp collect_free_var_refs(list, acc, bound) when is_list(list) do
    Enum.reduce(list, acc, &collect_free_var_refs(&1, &2, bound))
  end

  defp collect_free_var_refs(map, acc, bound) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, acc, fn {k, v}, inner ->
      v
      |> collect_free_var_refs(collect_free_var_refs(k, inner, bound), bound)
    end)
  end

  defp collect_free_var_refs(_other, acc, _bound), do: acc

  defp collect_free_refs_in_bindings(bindings, body, acc, bound) do
    {acc, bound} =
      Enum.reduce(bindings, {acc, bound}, fn {:binding, pattern, value_ast},
                                             {inner_acc, inner_bound} ->
        inner_acc = collect_free_var_refs(value_ast, inner_acc, inner_bound)
        inner_bound = MapSet.union(inner_bound, bound_names_from_pattern(pattern))
        {inner_acc, inner_bound}
      end)

    collect_free_var_refs(body, acc, bound)
  end

  defp bound_names_from_params(params) when is_list(params) do
    params
    |> Enum.flat_map(&names_from_pattern/1)
    |> normalize_name_set()
  end

  defp bound_names_from_params({:variadic, leading, rest_pattern}) do
    (Enum.flat_map(leading, &names_from_pattern/1) ++ names_from_pattern(rest_pattern))
    |> normalize_name_set()
  end

  defp bound_names_from_pattern(pattern) do
    pattern
    |> names_from_pattern()
    |> normalize_name_set()
  end

  defp names_from_pattern({:var, name}), do: [name]
  defp names_from_pattern({:destructure, {:keys, keys, _defaults}}), do: keys

  defp names_from_pattern({:destructure, {:map, keys, renames, _defaults}}) do
    keys ++
      Enum.flat_map(renames, fn {target_pattern, _source_key} ->
        names_from_pattern(target_pattern)
      end)
  end

  defp names_from_pattern({:destructure, {:as, name, inner}}),
    do: [name | names_from_pattern(inner)]

  defp names_from_pattern({:destructure, {:seq, patterns}}),
    do: Enum.flat_map(patterns, &names_from_pattern/1)

  defp names_from_pattern({:destructure, {:seq_rest, leading, rest}}) do
    Enum.flat_map(leading, &names_from_pattern/1) ++ names_from_pattern(rest)
  end

  defp names_from_pattern(_other), do: []

  defp normalize_name_set(names) do
    names
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end
end
