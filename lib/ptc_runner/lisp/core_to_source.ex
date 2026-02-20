defmodule PtcRunner.Lisp.CoreToSource do
  @moduledoc """
  Convert Core AST (the analyzed/desugared representation) back to PTC-Lisp source strings.

  This is distinct from `PtcRunner.Lisp.Formatter` which handles raw parser AST.
  CoreToSource works with the intermediate representation produced by the analyzer
  and stored inside closures.

  ## Use Cases

  - Serializing closures for archive persistence
  - Novelty comparison between memory designs
  - Debugging Core AST output
  """

  alias PtcRunner.Lisp.Formatter

  @doc """
  Convert a Core AST node to a PTC-Lisp source string.

  ## Examples

      iex> PtcRunner.Lisp.CoreToSource.format({:var, :x})
      "x"

      iex> PtcRunner.Lisp.CoreToSource.format({:string, "hello"})
      ~S("hello")

      iex> PtcRunner.Lisp.CoreToSource.format({:call, {:var, :+}, [1, 2]})
      "(+ 1 2)"
  """
  @spec format(term()) :: String.t()

  # Literals
  def format(nil), do: "nil"
  def format(true), do: "true"
  def format(false), do: "false"
  def format(n) when is_integer(n), do: Integer.to_string(n)

  def format(n) when is_float(n) do
    :erlang.float_to_binary(n, [:compact, decimals: 15])
  end

  def format(:infinity), do: "##Inf"
  def format(:negative_infinity), do: "##-Inf"
  def format(:nan), do: "##NaN"

  def format({:string, s}), do: ~s("#{escape_string(s)}")
  def format({:keyword, k}), do: ":#{k}"

  # Delegate {:literal, v} to Formatter (used for compile-time constants)
  def format({:literal, v}), do: Formatter.format(v)

  # Raw runtime values (from step.memory, not Core AST)
  def format(s) when is_binary(s), do: ~s("#{escape_string(s)}")
  def format(list) when is_list(list), do: "[#{format_list(list)}]"

  def format(map) when is_map(map) and not is_struct(map) do
    inner =
      Enum.map_join(map, " ", fn {k, v} -> "#{format_map_key(k)} #{format(v)}" end)

    "{#{inner}}"
  end

  # Variables and data access
  def format({:var, name}), do: Atom.to_string(name)
  def format({:data, key}), do: "data/#{key}"

  # Collections
  def format({:vector, elems}) do
    "[#{format_list(elems)}]"
  end

  def format({:map, pairs}) do
    inner =
      Enum.map_join(pairs, " ", fn {k, v} -> "#{format(k)} #{format(v)}" end)

    "{#{inner}}"
  end

  def format({:set, elems}) do
    "\#{#{format_list(elems)}}"
  end

  # Let bindings
  def format({:let, bindings, body}) do
    bindings_str =
      Enum.map_join(bindings, " ", fn {:binding, pattern, value} ->
        "#{format_pattern(pattern)} #{format(value)}"
      end)

    "(let [#{bindings_str}] #{format(body)})"
  end

  # Anonymous function
  def format({:fn, params, body}) do
    "(fn [#{format_params(params)}] #{format(body)})"
  end

  # Loop with tail recursion
  def format({:loop, bindings, body}) do
    bindings_str =
      Enum.map_join(bindings, " ", fn {:binding, pattern, value} ->
        "#{format_pattern(pattern)} #{format(value)}"
      end)

    "(loop [#{bindings_str}] #{format(body)})"
  end

  # Function call
  def format({:call, {:var, name}, args}) do
    "(#{name} #{format_list(args)})"
  end

  def format({:call, target, args}) do
    "(#{format(target)} #{format_list(args)})"
  end

  # Tool call
  def format({:tool_call, name, args}) do
    "(tool/#{name} #{format_list(args)})"
  end

  # Def
  def format({:def, name, value, _meta}) do
    "(def #{name} #{format(value)})"
  end

  # Control flow
  def format({:if, condition, then_branch, else_branch}) do
    "(if #{format(condition)} #{format(then_branch)} #{format(else_branch)})"
  end

  def format({:do, exprs}) do
    "(do #{format_list(exprs)})"
  end

  def format({:and, exprs}) do
    "(and #{format_list(exprs)})"
  end

  def format({:or, exprs}) do
    "(or #{format_list(exprs)})"
  end

  # Control signals
  def format({:return, value}) do
    "(return #{format(value)})"
  end

  def format({:fail, value}) do
    "(fail #{format(value)})"
  end

  # Recur
  def format({:recur, args}) do
    "(recur #{format_list(args)})"
  end

  # Task operations
  def format({:task, id, body}) when is_binary(id) do
    "(task #{format({:string, id})} #{format(body)})"
  end

  def format({:task_dynamic, id_expr, body}) do
    "(task-dynamic #{format(id_expr)} #{format(body)})"
  end

  def format({:step_done, id, summary}) do
    "(step-done #{format(id)} #{format(summary)})"
  end

  def format({:task_reset, id}) do
    "(task-reset #{format(id)})"
  end

  # Budget and turn history
  def format({:budget_remaining}) do
    "(budget-remaining)"
  end

  def format({:turn_history, n}) do
    "(turn-history #{format(n)})"
  end

  # Predicates
  def format({:where, {:field, segments}, op, nil}) do
    "(where #{format_field_path(segments)} #{format_where_op(op)})"
  end

  def format({:where, {:field, segments}, op, value}) do
    "(where #{format_field_path(segments)} #{format_where_op(op)} #{format(value)})"
  end

  def format({:pred_combinator, kind, predicates}) do
    name =
      case kind do
        :all_of -> "all-of"
        :any_of -> "any-of"
        :none_of -> "none-of"
      end

    "(#{name} #{format_list(predicates)})"
  end

  # Parallel operations
  def format({:pmap, fn_expr, coll_expr}) do
    "(pmap #{format(fn_expr)} #{format(coll_expr)})"
  end

  def format({:pcalls, fn_exprs}) do
    "(pcalls #{format_list(fn_exprs)})"
  end

  # Juxt
  def format({:juxt, fns}) do
    "(juxt #{format_list(fns)})"
  end

  # --- Closure serialization ---

  @doc """
  Serialize a closure tuple to PTC-Lisp source string.

  Drops the captured environment intentionally — forces pure functions
  or use of `def`/memory namespace for state.

  ## Examples

      iex> closure = {:closure, [{:var, :x}], {:call, {:var, :+}, [{:var, :x}, 1]}, %{}, [], %{}}
      iex> PtcRunner.Lisp.CoreToSource.serialize_closure(closure)
      "(fn [x] (+ x 1))"
  """
  @spec serialize_closure(tuple()) :: String.t()
  def serialize_closure({:closure, params, body, _env, _history, _meta}) do
    format({:fn, params, body})
  end

  @doc """
  Serialize all closures in a memory namespace to source strings.

  Returns a map of `{name => source_string}` for each closure value in memory.
  Non-closure values are skipped.

  ## Examples

      iex> memory = %{f: {:closure, [{:var, :x}], {:var, :x}, %{}, [], %{}}, count: 5}
      iex> PtcRunner.Lisp.CoreToSource.serialize_namespace(memory)
      %{f: "(fn [x] x)"}
  """
  @spec serialize_namespace(map()) :: map()
  def serialize_namespace(memory) when is_map(memory) do
    memory
    |> Enum.filter(fn {_k, v} -> match?({:closure, _, _, _, _, _}, v) end)
    |> Map.new(fn {k, v} -> {k, serialize_closure(v)} end)
  end

  @doc """
  Export an entire memory namespace as PTC-Lisp source.

  Serializes all entries — closures become `(def name (fn [...] ...))`,
  non-closure values become `(def name value)`. Multiple top-level forms
  are emitted without a `do` wrapper (the parser handles them natively).

  ## Examples

      iex> memory = %{x: 5, f: {:closure, [{:var, :n}], {:call, {:var, :+}, [{:var, :n}, 1]}, %{}, [], %{}}}
      iex> source = PtcRunner.Lisp.CoreToSource.export_namespace(memory)
      iex> source =~ "def x"
      true
      iex> source =~ "def f"
      true
  """
  @spec export_namespace(map()) :: String.t()
  def export_namespace(memory) when is_map(memory) do
    entries =
      memory
      |> Enum.reject(fn {k, _v} -> internal_key?(k) end)
      |> Enum.to_list()

    sorted = topo_sort_entries(entries)

    Enum.map_join(sorted, "\n", fn
      {k, {:closure, _, _, _, _, _} = closure} ->
        "(def #{k} #{serialize_closure(closure)})"

      {k, v} ->
        "(def #{k} #{format(v)})"
    end)
  end

  # Topological sort: non-closures first, then closures ordered by dependencies.
  defp topo_sort_entries(entries) do
    {non_closures, closures} =
      Enum.split_with(entries, fn {_k, v} -> !match?({:closure, _, _, _, _, _}, v) end)

    ns_keys = MapSet.new(Enum.map(entries, fn {k, _} -> k end))
    # Build dependency graph: closure -> set of namespace keys it references
    deps =
      Map.new(closures, fn {k, {:closure, _params, body, _env, _h, _m}} ->
        {k, collect_var_refs(body) |> MapSet.intersection(ns_keys) |> MapSet.delete(k)}
      end)

    sorted_closures = topo_sort(closures, deps, [], MapSet.new())
    non_closures ++ sorted_closures
  end

  defp topo_sort([], _deps, acc, _visited), do: Enum.reverse(acc)

  defp topo_sort(remaining, deps, acc, visited) do
    # Find entries with no unvisited dependencies
    {ready, blocked} =
      Enum.split_with(remaining, fn {k, _v} ->
        Map.get(deps, k, MapSet.new()) |> MapSet.subset?(visited)
      end)

    case ready do
      [] ->
        # Cycle or all remaining — emit in any order
        Enum.reverse(acc) ++ remaining

      _ ->
        new_visited = Enum.reduce(ready, visited, fn {k, _}, vs -> MapSet.put(vs, k) end)
        topo_sort(blocked, deps, Enum.reverse(ready) ++ acc, new_visited)
    end
  end

  defp collect_var_refs(ast, acc \\ MapSet.new())
  defp collect_var_refs({:var, name}, acc), do: MapSet.put(acc, name)
  defp collect_var_refs({:data, _key}, acc), do: acc
  defp collect_var_refs({:string, _}, acc), do: acc
  defp collect_var_refs({:keyword, _}, acc), do: acc
  defp collect_var_refs({:literal, _}, acc), do: acc

  defp collect_var_refs({:call, target, args}, acc) do
    acc = collect_var_refs(target, acc)
    Enum.reduce(args, acc, &collect_var_refs/2)
  end

  defp collect_var_refs({:tool_call, _name, args}, acc) do
    Enum.reduce(args, acc, &collect_var_refs/2)
  end

  defp collect_var_refs({:fn, _params, body}, acc), do: collect_var_refs(body, acc)
  defp collect_var_refs({:fn, _params, _guards, body}, acc), do: collect_var_refs(body, acc)

  defp collect_var_refs({:if, c, t, e}, acc) do
    acc = collect_var_refs(c, acc)
    acc = collect_var_refs(t, acc)
    collect_var_refs(e, acc)
  end

  defp collect_var_refs({:let, bindings, body}, acc) do
    acc = Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_var_refs(val, a) end)
    collect_var_refs(body, acc)
  end

  defp collect_var_refs({:loop, bindings, body}, acc) do
    acc = Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_var_refs(val, a) end)
    collect_var_refs(body, acc)
  end

  defp collect_var_refs({:recur, args}, acc), do: Enum.reduce(args, acc, &collect_var_refs/2)
  defp collect_var_refs({:do, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_var_refs/2)
  defp collect_var_refs({:or, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_var_refs/2)
  defp collect_var_refs({:and, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_var_refs/2)
  defp collect_var_refs({:vector, elems}, acc), do: Enum.reduce(elems, acc, &collect_var_refs/2)
  defp collect_var_refs({:set, elems}, acc), do: Enum.reduce(elems, acc, &collect_var_refs/2)
  defp collect_var_refs({:return, val}, acc), do: collect_var_refs(val, acc)
  defp collect_var_refs({:fail, val}, acc), do: collect_var_refs(val, acc)

  defp collect_var_refs({:map, pairs}, acc) do
    Enum.reduce(pairs, acc, fn {k, v}, a ->
      a = collect_var_refs(k, a)
      collect_var_refs(v, a)
    end)
  end

  defp collect_var_refs({:def, _name, val, _meta}, acc), do: collect_var_refs(val, acc)

  defp collect_var_refs({:pmap, fn_expr, coll_expr}, acc) do
    acc = collect_var_refs(fn_expr, acc)
    collect_var_refs(coll_expr, acc)
  end

  defp collect_var_refs({:pcalls, fn_exprs}, acc) do
    Enum.reduce(fn_exprs, acc, &collect_var_refs/2)
  end

  defp collect_var_refs({:juxt, fns}, acc) do
    Enum.reduce(fns, acc, &collect_var_refs/2)
  end

  defp collect_var_refs({:step_done, id, summary}, acc) do
    acc = collect_var_refs(id, acc)
    collect_var_refs(summary, acc)
  end

  defp collect_var_refs({:task_reset, id}, acc), do: collect_var_refs(id, acc)
  defp collect_var_refs({:task, _id, body}, acc), do: collect_var_refs(body, acc)

  defp collect_var_refs({:task_dynamic, id_expr, body}, acc) do
    acc = collect_var_refs(id_expr, acc)
    collect_var_refs(body, acc)
  end

  defp collect_var_refs({:variadic, _leading, _rest}, acc), do: acc
  defp collect_var_refs({:binding, _pat, val}, acc), do: collect_var_refs(val, acc)
  defp collect_var_refs(_other, acc), do: acc

  defp internal_key?(key) when is_atom(key) do
    name = Atom.to_string(key)
    String.starts_with?(name, "_") or String.starts_with?(name, "__ptc_")
  end

  defp internal_key?(_), do: false

  # --- Helpers ---

  defp format_list(elems) do
    Enum.map_join(elems, " ", &format/1)
  end

  defp format_params(params) when is_list(params) do
    Enum.map_join(params, " ", &format_pattern/1)
  end

  defp format_params({:variadic, leading, rest_pattern}) do
    leading_str = Enum.map_join(leading, " ", &format_pattern/1)

    if leading_str == "" do
      "& #{format_pattern(rest_pattern)}"
    else
      "#{leading_str} & #{format_pattern(rest_pattern)}"
    end
  end

  defp format_pattern({:var, name}), do: Atom.to_string(name)

  defp format_pattern({:destructure, {:keys, keys, defaults}}) do
    keys_str = Enum.map_join(keys, " ", &Atom.to_string/1)

    case defaults do
      [] ->
        "{:keys [#{keys_str}]}"

      _ ->
        defaults_str =
          Enum.map_join(defaults, " ", fn {k, v} -> "#{k} #{format(v)}" end)

        "{:keys [#{keys_str}] :or {#{defaults_str}}}"
    end
  end

  defp format_pattern({:destructure, {:map, _keys, renames, defaults}}) do
    renames_str =
      Enum.map_join(renames, " ", fn {local, key} -> "#{local} :#{key}" end)

    case defaults do
      [] ->
        "{#{renames_str}}"

      _ ->
        defaults_str =
          Enum.map_join(defaults, " ", fn {k, v} -> "#{k} #{format(v)}" end)

        "{#{renames_str} :or {#{defaults_str}}}"
    end
  end

  defp format_pattern({:destructure, {:as, name, inner}}) do
    "#{format_pattern(inner)} :as #{name}"
  end

  defp format_pattern({:destructure, {:seq, patterns}}) do
    "[#{Enum.map_join(patterns, " ", &format_pattern/1)}]"
  end

  defp format_pattern({:destructure, {:seq_rest, leading, rest}}) do
    leading_str = Enum.map_join(leading, " ", &format_pattern/1)
    "[#{leading_str} & #{format_pattern(rest)}]"
  end

  # Runtime map keys: strings stay as strings, atoms become keywords
  defp format_map_key(k) when is_binary(k), do: ~s("#{escape_string(k)}")
  defp format_map_key(k) when is_atom(k), do: ":#{k}"
  defp format_map_key(k), do: format(k)

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end

  defp format_field_path(segments) do
    Enum.map_join(segments, ".", fn
      {:keyword, k} -> ":#{k}"
      {:string, s} -> ~s("#{escape_string(s)}")
    end)
  end

  defp format_where_op(:eq), do: "="
  defp format_where_op(:not_eq), do: "!="
  defp format_where_op(:gt), do: ">"
  defp format_where_op(:lt), do: "<"
  defp format_where_op(:gte), do: ">="
  defp format_where_op(:lte), do: "<="
  defp format_where_op(:includes), do: "includes"
  defp format_where_op(:in), do: "in"
  defp format_where_op(:truthy), do: "truthy"
end
