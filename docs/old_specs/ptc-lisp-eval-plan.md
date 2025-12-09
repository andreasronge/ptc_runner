# PTC-Lisp Eval Layer Implementation Plan

This document specifies the interpreter that evaluates CoreAST nodes.

**Status:** Draft v3 (aligned with Spec v0.3.2, strict binary ops, vector-only collections)

## Overview

**Pipeline:**
```
source → Parser → RawAST → Analyze → CoreAST → Eval → result
```

The Eval layer:
1. **Evaluates** CoreAST nodes recursively
2. **Resolves** variables from lexical environment
3. **Applies** builtins and user functions
4. **Builds** predicate closures from `where` nodes
5. **Handles** short-circuit logic for `and`/`or`

---

## 1. Core Types and Signature

```elixir
defmodule PtcRunner.Lisp.Eval do
  @moduledoc "Evaluates CoreAST into values"

  alias PtcRunner.Lisp.CoreAST

  @type env :: %{atom() => term()}
  @type tool_executor :: (String.t(), map() -> term())

  @type value ::
          nil | boolean() | number() | String.t()
          | atom()  # keywords
          | list()  # vectors become lists
          | map()
          | function()  # closures and builtins
          | {:closure, [atom()], CoreAST.t(), env()}

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor()) ::
          {:ok, value(), map()} | {:error, term()}

  def eval(ast, ctx, memory, env, tool_executor) do
    do_eval(ast, ctx, memory, env, tool_executor)
  end
end
```

---

## 2. Literals and Collections

```elixir
# Literals pass through
defp do_eval(nil, _ctx, memory, _env, _tool_exec), do: {:ok, nil, memory}
defp do_eval(true, _ctx, memory, _env, _tool_exec), do: {:ok, true, memory}
defp do_eval(false, _ctx, memory, _env, _tool_exec), do: {:ok, false, memory}
defp do_eval(n, _ctx, memory, _env, _tool_exec) when is_number(n), do: {:ok, n, memory}
defp do_eval({:string, s}, _ctx, memory, _env, _tool_exec), do: {:ok, s, memory}
defp do_eval({:keyword, k}, _ctx, memory, _env, _tool_exec), do: {:ok, k, memory}

# Vectors: evaluate all elements
defp do_eval({:vector, elems}, ctx, memory, env, tool_exec) do
  {values, memory2} =
    Enum.map_reduce(elems, memory, fn elem, mem ->
      {:ok, v, mem2} = do_eval(elem, ctx, mem, env, tool_exec)
      {v, mem2}
    end)

  {:ok, values, memory2}
end

# Maps: evaluate all keys and values
defp do_eval({:map, pairs}, ctx, memory, env, tool_exec) do
  {evaluated_pairs, memory2} =
    Enum.map_reduce(pairs, memory, fn {k_ast, v_ast}, mem ->
      {:ok, k, mem2} = do_eval(k_ast, ctx, mem, env, tool_exec)
      {:ok, v, mem3} = do_eval(v_ast, ctx, mem2, env, tool_exec)
      {{k, v}, mem3}
    end)

  {:ok, Map.new(evaluated_pairs), memory2}
end
```

---

## 3. Variable and Namespace Access

```elixir
# Local/global variable from environment
defp do_eval({:var, name}, _ctx, memory, env, _tool_exec) do
  case Map.fetch(env, name) do
    {:ok, value} -> {:ok, value, memory}
    :error -> {:error, {:unbound_var, name}}
  end
end

# Context access: ctx/input → ctx[:input]
defp do_eval({:ctx, key}, ctx, memory, _env, _tool_exec) do
  {:ok, Map.get(ctx, key), memory}
end

# Memory access: memory/results → memory[:results]
defp do_eval({:memory, key}, _ctx, memory, _env, _tool_exec) do
  {:ok, Map.get(memory, key), memory}
end
```

---

## 4. `let` — Local Bindings

```elixir
defp do_eval({:let, bindings, body}, ctx, memory, env, tool_exec) do
  {new_env, memory2} =
    Enum.reduce(bindings, {env, memory}, fn {:binding, pattern, value_ast}, {acc_env, acc_mem} ->
      {:ok, value, mem2} = do_eval(value_ast, ctx, acc_mem, acc_env, tool_exec)
      new_bindings = match_pattern(pattern, value)
      {Map.merge(acc_env, new_bindings), mem2}
    end)

  do_eval(body, ctx, memory2, new_env, tool_exec)
end

# Pattern matching for let bindings
defp match_pattern({:var, name}, value) do
  %{name => value}
end

defp match_pattern({:destructure, {:keys, keys, defaults}}, value) when is_map(value) do
  Enum.reduce(keys, %{}, fn key, acc ->
    default = Keyword.get(defaults, key)
    Map.put(acc, key, Map.get(value, key, default))
  end)
end

defp match_pattern({:destructure, {:as, as_name, inner_pattern}}, value) do
  inner_bindings = match_pattern(inner_pattern, value)
  Map.put(inner_bindings, as_name, value)
end
```

---

## 5. `if` — Conditional

```elixir
defp do_eval({:if, cond_ast, then_ast, else_ast}, ctx, memory, env, tool_exec) do
  {:ok, cond_val, memory2} = do_eval(cond_ast, ctx, memory, env, tool_exec)

  if truthy?(cond_val) do
    do_eval(then_ast, ctx, memory2, env, tool_exec)
  else
    do_eval(else_ast, ctx, memory2, env, tool_exec)
  end
end

defp truthy?(nil), do: false
defp truthy?(false), do: false
defp truthy?(_), do: true
```

---

## 6. `and` / `or` — Short-Circuit Logic

Clojure semantics: return values, not coerced booleans.

```elixir
defp do_eval({:and, exprs}, ctx, memory, env, tool_exec) do
  do_eval_and(exprs, ctx, memory, env, tool_exec)
end

defp do_eval_and([], _ctx, memory, _env, _tool_exec), do: {:ok, true, memory}

defp do_eval_and([e | rest], ctx, memory, env, tool_exec) do
  {:ok, value, memory2} = do_eval(e, ctx, memory, env, tool_exec)

  if truthy?(value) do
    do_eval_and(rest, ctx, memory2, env, tool_exec)
  else
    # Short-circuit: return falsy value
    {:ok, value, memory2}
  end
end

defp do_eval({:or, exprs}, ctx, memory, env, tool_exec) do
  do_eval_or(exprs, ctx, memory, env, tool_exec)
end

defp do_eval_or([], _ctx, memory, _env, _tool_exec), do: {:ok, nil, memory}

defp do_eval_or([e | rest], ctx, memory, env, tool_exec) do
  {:ok, value, memory2} = do_eval(e, ctx, memory, env, tool_exec)

  if truthy?(value) do
    # Short-circuit: return truthy value
    {:ok, value, memory2}
  else
    do_eval_or(rest, ctx, memory2, env, tool_exec)
  end
end
```

**Examples:**
- `(or memory/query-count 0)` → returns count if truthy, else 0
- `(and user (:active user))` → returns false/nil if user is nil, else the active value

---

## 7. `fn` — Closure Creation

```elixir
defp do_eval({:fn, params, body}, _ctx, memory, env, _tool_exec) do
  param_names =
    Enum.map(params, fn
      {:var, name} -> name
    end)

  # Capture the current environment (lexical scoping)
  {:ok, {:closure, param_names, body, env}, memory}
end
```

---

## 8. Function Calls

### 8.1 Call Dispatch

```elixir
defp do_eval({:call, fun_ast, arg_asts}, ctx, memory, env, tool_exec) do
  {:ok, fun_val, memory1} = do_eval(fun_ast, ctx, memory, env, tool_exec)

  {arg_vals, memory2} =
    Enum.map_reduce(arg_asts, memory1, fn arg_ast, mem ->
      {:ok, v, mem2} = do_eval(arg_ast, ctx, mem, env, tool_exec)
      {v, mem2}
    end)

  apply_fun(fun_val, arg_vals, ctx, memory2, tool_exec)
end
```

### 8.2 Keyword as Function

```elixir
# (:key map) → Map.get(map, :key)
# (:key map default) → Map.get(map, :key, default)
defp apply_fun(k, args, _ctx, memory, _tool_exec) when is_atom(k) do
  case args do
    [m] when is_map(m) ->
      {:ok, Map.get(m, k), memory}

    [m, default] when is_map(m) ->
      {:ok, Map.get(m, k, default), memory}

    [nil] ->
      {:ok, nil, memory}

    [nil, default] ->
      {:ok, default, memory}

    _ ->
      {:error, {:invalid_keyword_call, k, args}}
  end
end
```

### 8.3 Closure Application

```elixir
defp apply_fun({:closure, param_names, body, closure_env}, args, ctx, memory, tool_exec) do
  if length(param_names) != length(args) do
    {:error, {:arity_mismatch, length(param_names), length(args)}}
  else
    bindings = Enum.zip(param_names, args) |> Map.new()
    new_env = Map.merge(closure_env, bindings)
    do_eval(body, ctx, memory, new_env, tool_exec)
  end
end
```

### 8.4 Builtin Functions (with Variadic Support)

Builtins are stored in env with descriptors:
- `{:normal, fun}` — fixed-arity function
- `{:variadic, fun2, identity}` — binary function + identity for reduce
- `{:variadic_nonempty, fun2}` — variadic but requires at least 1 arg (for `max`, `min`)

```elixir
# Normal builtins: {:normal, fun}
defp apply_fun({:normal, fun}, args, _ctx, memory, _tool_exec) when is_function(fun) do
  {:ok, apply(fun, args), memory}
end

# Variadic builtins: {:variadic, fun2, identity}
# Handles (+ 1 2 3), (* 2 3 4), etc.
defp apply_fun({:variadic, fun2, identity}, args, _ctx, memory, _tool_exec)
     when is_function(fun2, 2) do
  result =
    case args do
      [] -> identity
      [x] -> x
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fun2)
    end

  {:ok, result, memory}
end

# Variadic requiring at least one arg: {:variadic_nonempty, fun2}
# Handles (max 1 2 3), (min 1 2), etc. — errors on zero args
defp apply_fun({:variadic_nonempty, _fun2}, [], _ctx, _memory, _tool_exec) do
  {:error, {:arity_error, "requires at least 1 argument"}}
end

defp apply_fun({:variadic_nonempty, fun2}, args, _ctx, memory, _tool_exec)
     when is_function(fun2, 2) do
  result =
    case args do
      [x] -> x
      [x, y] -> fun2.(x, y)
      [h | t] -> Enum.reduce(t, h, fun2)
    end

  {:ok, result, memory}
end

# Plain function value (from user code or closures that escape)
defp apply_fun(fun, args, _ctx, memory, _tool_exec) when is_function(fun) do
  {:ok, apply(fun, args), memory}
end

# Fallback: not callable
defp apply_fun(other, _args, _ctx, _memory, _tool_exec) do
  {:error, {:not_callable, other}}
end
```

**Variadic design rationale:**
- Stores binary function + identity in env (e.g., `{:variadic, &Kernel.+/2, 0}`)
- Generic handler in `apply_fun` reduces args with the binary function
- Extensible: add new variadic builtins without touching Eval logic
- No awkward wrapper functions needed
- `{:variadic_nonempty, fun2}` for functions like `max`/`min` that need at least one arg

---

## 9. `where` — Predicate Builder

### 9.1 Core Evaluation

```elixir
defp do_eval({:where, field_path, op, value_ast}, ctx, memory, env, tool_exec) do
  # Evaluate the comparison value (if not truthy check)
  {:ok, value, memory2} =
    case value_ast do
      nil -> {:ok, nil, memory}
      _ -> do_eval(value_ast, ctx, memory, env, tool_exec)
    end

  accessor = build_field_accessor(field_path)

  fun =
    case op do
      :truthy   -> fn row -> truthy?(accessor.(row)) end
      :eq       -> fn row -> safe_eq(accessor.(row), value) end
      :not_eq   -> fn row -> not safe_eq(accessor.(row), value) end
      :gt       -> fn row -> safe_cmp(accessor.(row), value, :>) end
      :lt       -> fn row -> safe_cmp(accessor.(row), value, :<) end
      :gte      -> fn row -> safe_cmp(accessor.(row), value, :>=) end
      :lte      -> fn row -> safe_cmp(accessor.(row), value, :<=) end
      :includes -> fn row -> safe_includes(accessor.(row), value) end
      :in       -> fn row -> safe_in(accessor.(row), value) end
    end

  {:ok, fun, memory2}
end

defp build_field_accessor({:field, segments}) do
  path =
    Enum.map(segments, fn
      {:keyword, k} -> k
      {:string, s} -> s
    end)

  fn row -> get_in(row, path) end
end
```

### 9.2 Nil-Safe Comparison Helpers

Inside `where`, comparisons with nil are handled specially:
- **Equality** (`=`, `not=`): `nil = nil` is `true` (allows explicit nil matching)
- **Ordering** (`>`, `<`, etc.): Any nil operand returns `false` (safe filtering)

```elixir
# Equality: nil = nil is true (supports explicit nil matching)
defp safe_eq(nil, nil), do: true
defp safe_eq(nil, _), do: false
defp safe_eq(_, nil), do: false
defp safe_eq(a, b), do: a == b

defp safe_cmp(nil, _, _op), do: false
defp safe_cmp(_, nil, _op), do: false
defp safe_cmp(a, b, :>), do: a > b
defp safe_cmp(a, b, :<), do: a < b
defp safe_cmp(a, b, :>=), do: a >= b
defp safe_cmp(a, b, :<=), do: a <= b

# `in` operator: field value is member of collection
defp safe_in(nil, _coll), do: false
defp safe_in(value, coll) when is_list(coll), do: value in coll
defp safe_in(_, _), do: false

# `includes` operator: collection includes value
defp safe_includes(nil, _value), do: false
defp safe_includes(coll, value) when is_list(coll), do: value in coll
defp safe_includes(coll, value) when is_binary(coll) and is_binary(value) do
  String.contains?(coll, value)
end
defp safe_includes(_, _), do: false
```

---

## 10. Predicate Combinators

```elixir
defp do_eval({:pred_combinator, kind, pred_asts}, ctx, memory, env, tool_exec) do
  {pred_fns, memory2} =
    Enum.map_reduce(pred_asts, memory, fn p_ast, mem ->
      {:ok, f, mem2} = do_eval(p_ast, ctx, mem, env, tool_exec)
      {f, mem2}
    end)

  fun =
    case {kind, pred_fns} do
      # Empty cases (per spec)
      {:all_of, []} -> fn _row -> true end
      {:any_of, []} -> fn _row -> false end
      {:none_of, []} -> fn _row -> true end

      # Normal cases
      {:all_of, fns} ->
        fn row -> Enum.all?(fns, & &1.(row)) end

      {:any_of, fns} ->
        fn row -> Enum.any?(fns, & &1.(row)) end

      {:none_of, fns} ->
        fn row -> Enum.all?(fns, fn f -> not f.(row) end) end
    end

  {:ok, fun, memory2}
end
```

---

## 11. Tool Calls

```elixir
defp do_eval({:call_tool, tool_name, args_ast}, ctx, memory, env, tool_exec) do
  {:ok, args_map, memory2} = do_eval(args_ast, ctx, memory, env, tool_exec)

  # Call the tool executor provided by the host
  result = tool_exec.(tool_name, args_map)

  {:ok, result, memory2}
end
```

---

## 12. Runtime Builtins

### 12.1 Runtime Module

```elixir
defmodule PtcRunner.Lisp.Runtime do
  @moduledoc "Built-in functions for PTC-Lisp"

  # ============================================================
  # Collection Operations
  # ============================================================

  def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)
  def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)
  def find(pred, coll) when is_list(coll), do: Enum.find(coll, pred)

  def map(f, coll) when is_list(coll), do: Enum.map(coll, f)
  def mapv(f, coll) when is_list(coll), do: Enum.map(coll, f)
  def pluck(key, coll) when is_list(coll), do: Enum.map(coll, &Map.get(&1, key))

  def sort(coll) when is_list(coll), do: Enum.sort(coll)

  def sort_by(key, coll) when is_list(coll) and is_atom(key) do
    Enum.sort_by(coll, &Map.get(&1, key))
  end

  def sort_by(key, comp, coll) when is_list(coll) and is_atom(key) and is_function(comp) do
    Enum.sort_by(coll, &Map.get(&1, key), comp)
  end

  def reverse(coll) when is_list(coll), do: Enum.reverse(coll)

  def first(coll) when is_list(coll), do: List.first(coll)
  def last(coll) when is_list(coll), do: List.last(coll)
  def nth(coll, idx) when is_list(coll), do: Enum.at(coll, idx)
  def take(n, coll) when is_list(coll), do: Enum.take(coll, n)
  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)
  def take_while(pred, coll) when is_list(coll), do: Enum.take_while(coll, pred)
  def drop_while(pred, coll) when is_list(coll), do: Enum.drop_while(coll, pred)
  def distinct(coll) when is_list(coll), do: Enum.uniq(coll)

  # concat2 is used for variadic concat: (concat c1 c2 ...)
  def concat2(a, b), do: Enum.concat(a || [], b || [])
  def into(to, from) when is_list(to), do: Enum.into(from, to)
  def flatten(coll) when is_list(coll), do: List.flatten(coll)
  def zip(c1, c2) when is_list(c1) and is_list(c2), do: Enum.zip(c1, c2)
  def interleave(c1, c2) when is_list(c1) and is_list(c2), do: Enum.zip(c1, c2) |> Enum.flat_map(fn {a, b} -> [a, b] end)

  def count(coll) when is_list(coll) or is_map(coll) or is_binary(coll), do: Enum.count(coll)
  def empty?(coll) when is_list(coll) or is_map(coll) or is_binary(coll), do: Enum.empty?(coll)

  def reduce(f, init, coll) when is_list(coll), do: Enum.reduce(coll, init, f)

  def sum_by(key, coll) when is_list(coll) do
    coll
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def avg_by(key, coll) when is_list(coll) do
    values = coll |> Enum.map(&Map.get(&1, key)) |> Enum.reject(&is_nil/1)
    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def min_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(Map.get(&1, key))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &Map.get(&1, key))
    end
  end

  def max_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(Map.get(&1, key))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &Map.get(&1, key))
    end
  end

  def group_by(key, coll) when is_list(coll), do: Enum.group_by(coll, &Map.get(&1, key))

  def some(pred, coll) when is_list(coll), do: Enum.any?(coll, pred)
  def every?(pred, coll) when is_list(coll), do: Enum.all?(coll, pred)
  def not_any?(pred, coll) when is_list(coll), do: not Enum.any?(coll, pred)
  def contains?(coll, key) when is_map(coll), do: Map.has_key?(coll, key)
  def contains?(coll, val) when is_list(coll), do: val in coll

  # ============================================================
  # Map Operations
  # ============================================================

  def get(m, k) when is_map(m), do: Map.get(m, k)
  def get(m, k, default) when is_map(m), do: Map.get(m, k, default)
  def get(nil, _k), do: nil
  def get(nil, _k, default), do: default

  def get_in(m, path) when is_map(m), do: Kernel.get_in(m, path)
  def get_in(m, path, default) when is_map(m) do
    case Kernel.get_in(m, path) do
      nil -> default
      val -> val
    end
  end

  def assoc(m, k, v), do: Map.put(m, k, v)
  def assoc_in(m, path, v), do: put_in(m, path, v)
  def update(m, k, f), do: Map.update!(m, k, f)
  def update_in(m, path, f), do: Kernel.update_in(m, path, f)
  def dissoc(m, k), do: Map.delete(m, k)
  def merge(m1, m2), do: Map.merge(m1, m2)
  def select_keys(m, ks), do: Map.take(m, ks)
  def keys(m), do: Map.keys(m)
  def vals(m), do: Map.values(m)

  # ============================================================
  # Arithmetic
  # ============================================================

  def add(args), do: Enum.sum(args)
  def subtract([x]), do: -x
  def subtract([x | rest]), do: x - Enum.sum(rest)
  def multiply(args), do: Enum.reduce(args, 1, &*/2)
  def divide(x, y), do: x / y
  def mod(x, y), do: rem(x, y)
  def inc(x), do: x + 1
  def dec(x), do: x - 1
  def abs(x), do: Kernel.abs(x)
  def max(args), do: Enum.max(args)
  def min(args), do: Enum.min(args)

  # ============================================================
  # Comparison (for direct use, not inside where)
  # ============================================================

  # Comparison functions are provided by Kernel (binary only).
  # No variadic comparison in Runtime.
  def not_eq(x, y), do: x != y

  # ============================================================
  # Logic (non-short-circuit versions for completeness)
  # ============================================================

  def not_(x), do: not truthy?(x)

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # ============================================================
  # Type Predicates
  # ============================================================

  def nil?(x), do: is_nil(x)
  def some?(x), do: not is_nil(x)
  def boolean?(x), do: is_boolean(x)
  def number?(x), do: is_number(x)
  def string?(x), do: is_binary(x)
  def keyword?(x), do: is_atom(x) and not is_nil(x) and not is_boolean(x)
  def vector?(x), do: is_list(x)
  def map?(x), do: is_map(x)
  def coll?(x), do: is_list(x)  # Only vectors, not maps

  # ============================================================
  # Numeric Predicates
  # ============================================================

  def zero?(x), do: x == 0
  def pos?(x), do: x > 0
  def neg?(x), do: x < 0
  def even?(x), do: rem(x, 2) == 0
  def odd?(x), do: rem(x, 2) != 0
end
```

### 12.2 Initial Environment (with Descriptors)

Bindings use descriptors to distinguish normal vs variadic functions:

```elixir
defmodule PtcRunner.Lisp.Env do
  @moduledoc "Builds the initial environment with builtins"

  alias PtcRunner.Lisp.Runtime

  @type binding :: {:normal, function()} | {:variadic, function(), term()}
  @type env :: %{atom() => binding()}

  @spec initial() :: env()
  def initial do
    builtin_bindings() |> Map.new()
  end

  defp builtin_bindings do
    [
      # ============================================================
      # Collection operations (normal arity)
      # ============================================================
      {:filter, {:normal, &Runtime.filter/2}},
      {:remove, {:normal, &Runtime.remove/2}},
      {:find, {:normal, &Runtime.find/2}},
      {:map, {:normal, &Runtime.map/2}},
      {:mapv, {:normal, &Runtime.mapv/2}},
      {:pluck, {:normal, &Runtime.pluck/2}},
      {:sort, {:normal, &Runtime.sort/1}},
      {:"sort-by", {:normal, &Runtime.sort_by/2}},   # (sort-by :key coll)
      # Note: sort-by/3 with comparator uses multi-arity dispatch in Runtime
      {:reverse, {:normal, &Runtime.reverse/1}},
      {:first, {:normal, &Runtime.first/1}},
      {:last, {:normal, &Runtime.last/1}},
      {:nth, {:normal, &Runtime.nth/2}},
      {:take, {:normal, &Runtime.take/2}},
      {:drop, {:normal, &Runtime.drop/2}},
      {:"take-while", {:normal, &Runtime.take_while/2}},
      {:"drop-while", {:normal, &Runtime.drop_while/2}},
      {:distinct, {:normal, &Runtime.distinct/1}},
      {:concat, {:variadic, &Runtime.concat2/2, []}}, # (concat c1 c2 ...)
      {:into, {:normal, &Runtime.into/2}},
      {:flatten, {:normal, &Runtime.flatten/1}},
      {:zip, {:normal, &Runtime.zip/2}},
      {:interleave, {:normal, &Runtime.interleave/2}},
      {:count, {:normal, &Runtime.count/1}},
      {:"empty?", {:normal, &Runtime.empty?/1}},
      {:reduce, {:normal, &Runtime.reduce/3}},
      {:"sum-by", {:normal, &Runtime.sum_by/2}},
      {:"avg-by", {:normal, &Runtime.avg_by/2}},
      {:"min-by", {:normal, &Runtime.min_by/2}},
      {:"max-by", {:normal, &Runtime.max_by/2}},
      {:"group-by", {:normal, &Runtime.group_by/2}},
      {:some, {:normal, &Runtime.some/2}},
      {:"every?", {:normal, &Runtime.every?/2}},
      {:"not-any?", {:normal, &Runtime.not_any?/2}},
      {:"contains?", {:normal, &Runtime.contains?/2}},

      # ============================================================
      # Map operations
      # ============================================================
      {:get, {:normal, &Runtime.get/2}},
      {:"get-in", {:normal, &Runtime.get_in/2}},
      {:assoc, {:normal, &Runtime.assoc/3}},
      {:"assoc-in", {:normal, &Runtime.assoc_in/3}},
      {:dissoc, {:normal, &Runtime.dissoc/2}},
      {:merge, {:variadic, &Runtime.merge/2, %{}}},
      {:"select-keys", {:normal, &Runtime.select_keys/2}},
      {:keys, {:normal, &Runtime.keys/1}},
      {:vals, {:normal, &Runtime.vals/1}},

      # ============================================================
      # Arithmetic — variadic with identity
      # ============================================================
      {:+, {:variadic, &Kernel.+/2, 0}},
      {:-, {:variadic, &Kernel.-/2, 0}},  # (- x) = -x handled specially
      {:*, {:variadic, &Kernel.*/2, 1}},
      {:/, {:normal, &Kernel.//2}},       # division is binary only
      {:mod, {:normal, &Runtime.mod/2}},
      {:inc, {:normal, &Runtime.inc/1}},
      {:dec, {:normal, &Runtime.dec/1}},
      {:abs, {:normal, &Runtime.abs/1}},
      {:max, {:variadic_nonempty, &Kernel.max/2}}, # (max x y ...) requires 1+ args
      {:min, {:variadic_nonempty, &Kernel.min/2}}, # (min x y ...) requires 1+ args

      # ============================================================
      # Comparison — normal (binary)
      # ============================================================
      {:=, {:normal, &Kernel.==/2}},
      {:"not=", {:normal, &Kernel.!=/2}},
      {:>, {:normal, &Kernel.>/2}},
      {:<, {:normal, &Kernel.</2}},
      {:>=, {:normal, &Kernel.>=/2}},
      {:<=, {:normal, &Kernel.<=/2}},

      # ============================================================
      # Logic
      # ============================================================
      {:not, {:normal, &Runtime.not_/1}},

      # ============================================================
      # Type predicates
      # ============================================================
      {:"nil?", {:normal, &is_nil/1}},
      {:"some?", {:normal, fn x -> not is_nil(x) end}},
      {:"boolean?", {:normal, &is_boolean/1}},
      {:"number?", {:normal, &is_number/1}},
      {:"string?", {:normal, &is_binary/1}},
      {:"keyword?", {:normal, fn x -> is_atom(x) and x not in [nil, true, false] end}},
      {:"vector?", {:normal, &is_list/1}},
      {:"map?", {:normal, &is_map/1}},
      {:"coll?", {:normal, &is_list/1}},

      # ============================================================
      # Numeric predicates
      # ============================================================
      {:"zero?", {:normal, fn x -> x == 0 end}},
      {:"pos?", {:normal, fn x -> x > 0 end}},
      {:"neg?", {:normal, fn x -> x < 0 end}},
      {:"even?", {:normal, fn x -> rem(x, 2) == 0 end}},
      {:"odd?", {:normal, fn x -> rem(x, 2) != 0 end}},
    ]
  end
end
```

**Note on `-` (subtraction):**
- `(-)` → 0 (identity)
- `(- x)` → should be `-x` (negation), but variadic gives `x`
- `(- x y z)` → `x - y - z` (correct via reduce)

For proper unary minus, either:
1. Special-case in `apply_fun` when args length is 1
2. Or treat `(- x)` as `(- 0 x)` in Analyze

Option 1 is cleaner:

```elixir
# Special handling for unary minus in apply_fun
defp apply_fun({:variadic, fun2, _identity}, [x], _ctx, memory, _tool_exec)
     when fun2 == (&Kernel.-/2) do
  {:ok, -x, memory}
end
```

---

## 13. Memory Contract (Top-Level Only)

The memory contract is applied **only** at the top level, not during recursive evaluation.

### Return Shape

The public `run/2` function returns a 4-tuple on success:

```
{:ok, result, memory_delta, new_memory}
```

| Field | Description |
|-------|-------------|
| `result` | The value returned to the caller |
| `memory_delta` | Map of keys that changed (for logging/debugging) |
| `new_memory` | Complete memory state after merge |

**Note:** The LLM-facing API in `ptc-lisp-llm-guide.md` may wrap this with metrics.

```elixir
defmodule PtcRunner.Lisp do
  @moduledoc "Main entry point for PTC-Lisp execution"

  alias PtcRunner.Lisp.{Parser, Analyze, Eval, Env}

  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})

    tool_executor = fn name, args ->
      case Map.fetch(tools, name) do
        {:ok, fun} -> fun.(args)
        :error -> raise "Unknown tool: #{name}"
      end
    end

    with {:ok, raw_ast} <- Parser.parse(source),
         {:ok, core_ast} <- Analyze.analyze(raw_ast),
         {:ok, value, _eval_memory} <- Eval.eval(core_ast, ctx, memory, Env.initial(), tool_executor) do
      apply_memory_contract(value, memory)
    end
  end

  # Non-map result: no memory update
  defp apply_memory_contract(value, memory) when not is_map(value) do
    {:ok, value, %{}, memory}  # {result, memory_delta, new_memory}
  end

  # Map result: check for :result key
  defp apply_memory_contract(value, memory) when is_map(value) do
    {result_value, rest} = Map.pop(value, :result)
    new_memory = Map.merge(memory, rest)

    case result_value do
      nil ->
        # Map without :result → merge into memory, map is returned
        {:ok, value, rest, new_memory}

      _ ->
        # Map with :result → merge rest into memory, :result value returned
        {:ok, result_value, rest, new_memory}
    end
  end
end
```

---

## 14. Testing Strategy

```elixir
defmodule PtcRunner.Lisp.EvalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "where predicates" do
    test "equality check" do
      source = ~s/(filter (where :status = "active") ctx/users)/
      ctx = %{users: [%{status: "active"}, %{status: "inactive"}]}

      assert {:ok, [%{status: "active"}], _, _} = Lisp.run(source, context: ctx)
    end

    test "nil-safe comparison" do
      source = ~s/(filter (where :age > 18) ctx/users)/
      ctx = %{users: [%{age: 20}, %{age: nil}, %{name: "no-age"}]}

      assert {:ok, [%{age: 20}], _, _} = Lisp.run(source, context: ctx)
    end

    test "truthy check" do
      source = ~s/(filter (where :active) ctx/users)/
      ctx = %{users: [%{active: true}, %{active: false}, %{active: nil}]}

      assert {:ok, [%{active: true}], _, _} = Lisp.run(source, context: ctx)
    end
  end

  describe "predicate combinators" do
    test "all-of combines predicates" do
      source = ~s/(filter (all-of (where :a = 1) (where :b = 2)) ctx/items)/
      ctx = %{items: [%{a: 1, b: 2}, %{a: 1, b: 3}, %{a: 2, b: 2}]}

      assert {:ok, [%{a: 1, b: 2}], _, _} = Lisp.run(source, context: ctx)
    end

    test "empty all-of is always true" do
      source = ~s/(filter (all-of) ctx/items)/
      ctx = %{items: [%{a: 1}, %{a: 2}]}

      assert {:ok, [%{a: 1}, %{a: 2}], _, _} = Lisp.run(source, context: ctx)
    end
  end

  describe "short-circuit logic" do
    test "or returns first truthy" do
      source = ~s/(or memory/count 0)/
      assert {:ok, 0, _, _} = Lisp.run(source, memory: %{})
      assert {:ok, 5, _, _} = Lisp.run(source, memory: %{count: 5})
    end

    test "and returns first falsy" do
      source = ~s/(and ctx/user (:active ctx/user))/
      assert {:ok, nil, _, _} = Lisp.run(source, context: %{user: nil})
      assert {:ok, true, _, _} = Lisp.run(source, context: %{user: %{active: true}})
    end
  end

  describe "fn closures" do
    test "captures environment" do
      source = """
      (let [threshold 100]
        (filter (fn [x] (> (:price x) threshold)) ctx/products))
      """
      ctx = %{products: [%{price: 50}, %{price: 150}]}

      assert {:ok, [%{price: 150}], _, _} = Lisp.run(source, context: ctx)
    end

    test "multi-param fn" do
      source = ~s/(reduce (fn [acc x] (+ acc (:amount x))) 0 ctx/items)/
      ctx = %{items: [%{amount: 10}, %{amount: 20}]}

      assert {:ok, 30, _, _} = Lisp.run(source, context: ctx)
    end
  end

  describe "keyword as function" do
    test "single arg" do
      source = ~s/(:name ctx/user)/
      assert {:ok, "Alice", _, _} = Lisp.run(source, context: %{user: %{name: "Alice"}})
    end

    test "with default" do
      source = ~s/(:missing ctx/user "default")/
      assert {:ok, "default", _, _} = Lisp.run(source, context: %{user: %{}})
    end
  end

  describe "memory contract" do
    test "non-map result leaves memory unchanged" do
      source = ~s/(count ctx/items)/
      assert {:ok, 3, %{}, %{}} = Lisp.run(source, context: %{items: [1, 2, 3]})
    end

    test "map without :result merges into memory" do
      source = ~s/{:cached-count (count ctx/items)}/
      {:ok, result, delta, new_memory} = Lisp.run(source, context: %{items: [1, 2, 3]})

      assert result == %{:"cached-count" => 3}
      assert delta == %{:"cached-count" => 3}
      assert new_memory == %{:"cached-count" => 3}
    end

    test "map with :result extracts return value" do
      source = ~s/{:result "done", :count 5}/
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == "done"
      assert delta == %{count: 5}
      assert new_memory == %{count: 5}
    end
  end
end
```

---

## 15. Error Handling

Runtime errors should be structured for LLM feedback:

```elixir
@type runtime_error ::
        {:unbound_var, atom()}
        | {:not_callable, term()}
        | {:arity_mismatch, expected :: integer(), got :: integer()}
        | {:type_error, expected :: String.t(), got :: term()}
        | {:tool_error, tool_name :: String.t(), reason :: term()}
        | {:invalid_keyword_call, atom(), [term()]}
```

---

## 16. Complete Document Set

After implementing this layer:

| Document | Purpose |
|----------|---------|
| `ptc-lisp-specification.md` | Language spec |
| `ptc-lisp-llm-guide.md` | LLM prompt reference |
| `ptc-lisp-parser-plan.md` | Parser implementation |
| `ptc-lisp-analyze-plan.md` | Validation/desugar layer |
| `ptc-lisp-eval-plan.md` | Interpreter (this doc) |

---

## References

- [PTC-Lisp Specification](ptc-lisp-specification.md)
- [Parser Implementation Plan](ptc-lisp-parser-plan.md)
- [Analyze Layer Plan](ptc-lisp-analyze-plan.md)
