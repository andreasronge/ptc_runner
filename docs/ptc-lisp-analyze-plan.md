# PTC-Lisp Analyze Layer Implementation Plan

This document specifies the validation and desugaring layer that transforms RawAST (from parser) into CoreAST (for interpreter).

**Status:** Draft v2 (incorporates review feedback)

## Overview

**Pipeline:**
```
source → Parser → RawAST → Analyze → CoreAST → Eval → result
```

The Analyze layer:
1. **Validates** form shapes (arity, required pieces)
2. **Desugars** syntactic sugar into core nodes
3. **Reports semantic errors** with structured error types

## 1. Core AST Definition

```elixir
defmodule PtcRunner.Lisp.CoreAST do
  @moduledoc "Core, validated AST for PTC-Lisp"

  @type literal ::
          nil | boolean() | number() | {:string, String.t()} | {:keyword, atom()}

  @type t ::
          literal
          # Collections
          | {:vector, [t()]}
          | {:map, [{t(), t()}]}
          # Variables and namespace access
          | {:var, atom()}                           # local / global symbol
          | {:ctx, atom()}                           # ctx/<key>
          | {:memory, atom()}                        # memory/<key>
          # Function call: f(args...)
          | {:call, t(), [t()]}
          # Let bindings: (let [p1 v1 p2 v2 ...] body)
          | {:let, [binding()], t()}
          # Conditionals
          | {:if, t(), t(), t()}                     # (if cond then else)
          # Anonymous function (simple params only, no destructuring)
          | {:fn, [simple_param()], t()}             # (fn [x y] body)
          # Short-circuit logic (special forms, not calls)
          | {:and, [t()]}
          | {:or, [t()]}
          # Predicates
          | {:where, field_path(), where_op(), t() | nil}
          | {:pred_combinator, :all_of | :any_of | :none_of, [t()]}
          # Tool call
          | {:call_tool, String.t(), t()}            # (call "tool" args-map)

  @type binding :: {:binding, pattern(), t()}

  @type pattern ::
          {:var, atom()}
          | {:destructure, {:keys, [atom()], keyword()}}  # {:keys [a b] :or {a default}}
          | {:destructure, {:as, atom(), pattern()}}      # {:keys [...] :as m}

  # fn params are restricted to simple symbols (no destructuring)
  @type simple_param :: {:var, atom()}

  @type field_path :: {:field, [field_segment()]}
  @type field_segment :: {:keyword, atom()} | {:string, String.t()}

  @type where_op :: :eq | :not_eq | :gt | :lt | :gte | :lte | :includes | :in | :truthy
end
```

### Design Decisions

1. **Desugared forms don't appear in CoreAST:**
   - `when` → `{:if, cond, body, nil}`
   - `cond` → nested `{:if, ...}`
   - `->`, `->>` → nested `{:call, ...}`

2. **Special forms that stay:**
   - `let`, `if`, `fn` — fundamental constructs
   - `and`, `or` — need short-circuit semantics
   - `where`, `all-of`, `any-of`, `none-of` — predicate builders

3. **Namespace symbols resolved:**
   - `ctx/input` → `{:ctx, :input}`
   - `memory/results` → `{:memory, :results}`
   - Other symbols → `{:var, name}`

### Key Eval Semantics (Preview)

These behaviors are handled in the Eval layer, not Analyze:

1. **`and`/`or` short-circuit:**
   - `(and)` → `true`, `(or)` → `nil`
   - `(and a b c)` → eval left-to-right, return first falsy or last value
   - `(or a b c)` → eval left-to-right, return first truthy or last value

2. **Empty predicate combinators:**
   - `(all-of)` → always true (vacuous truth)
   - `(any-of)` → always false
   - `(none-of)` → always true

3. **Keyword as function:**
   - `(:name user)` → `Map.get(user, :name)`
   - `(:name user default)` → `Map.get(user, :name, default)`

4. **`fn` closures capture environment:**
   - Multi-param supported: `(fn [acc x] body)`
   - Environment captured at definition time

---

## 2. Public API

```elixir
defmodule PtcRunner.Lisp.Analyze do
  @moduledoc "Validates and desugars RawAST into CoreAST"

  alias PtcRunner.Lisp.CoreAST

  @type error_reason ::
          {:invalid_form, String.t()}
          | {:invalid_arity, atom(), String.t()}
          | {:invalid_where_form, String.t()}
          | {:invalid_where_operator, atom()}
          | {:invalid_call_tool_name, any()}
          | {:invalid_cond_form, String.t()}
          | {:invalid_thread_form, atom(), String.t()}
          | {:unsupported_pattern, term()}

  @spec analyze(term()) :: {:ok, CoreAST.t()} | {:error, error_reason()}
  def analyze(raw_ast) do
    do_analyze(raw_ast)
  end
end
```

---

## 3. Implementation

### 3.1 Literals and Variables

```elixir
defp do_analyze(nil), do: {:ok, nil}
defp do_analyze(true), do: {:ok, true}
defp do_analyze(false), do: {:ok, false}
defp do_analyze(n) when is_integer(n) or is_float(n), do: {:ok, n}
defp do_analyze({:string, s}), do: {:ok, {:string, s}}
defp do_analyze({:keyword, k}), do: {:ok, {:keyword, k}}

# Collections
defp do_analyze({:vector, elems}) do
  with {:ok, elems2} <- analyze_list(elems) do
    {:ok, {:vector, elems2}}
  end
end

defp do_analyze({:map, pairs}) do
  with {:ok, pairs2} <- analyze_pairs(pairs) do
    {:ok, {:map, pairs2}}
  end
end

# Symbols
defp do_analyze({:symbol, name}), do: {:ok, {:var, name}}
defp do_analyze({:ns_symbol, :ctx, key}), do: {:ok, {:ctx, key}}
defp do_analyze({:ns_symbol, :memory, key}), do: {:ok, {:memory, key}}
```

### 3.2 Special Form Dispatch

```elixir
defp do_analyze({:list, [head | rest]} = list) do
  case head do
    # Core special forms
    {:symbol, :let}     -> analyze_let(rest)
    {:symbol, :if}      -> analyze_if(rest)
    {:symbol, :fn}      -> analyze_fn(rest)

    # Desugared forms
    {:symbol, :when}    -> analyze_when(rest)
    {:symbol, :cond}    -> analyze_cond(rest)
    {:symbol, :->}      -> analyze_thread(:'->', rest)
    {:symbol, :->>}     -> analyze_thread(:->>, rest)

    # Short-circuit logic
    {:symbol, :and}     -> analyze_and(rest)
    {:symbol, :or}      -> analyze_or(rest)

    # Predicates
    {:symbol, :where}   -> analyze_where(rest)
    {:symbol, :'all-of'}  -> analyze_pred_comb(:all_of, rest)
    {:symbol, :'any-of'}  -> analyze_pred_comb(:any_of, rest)
    {:symbol, :'none-of'} -> analyze_pred_comb(:none_of, rest)

    # Tool call
    {:symbol, :call}    -> analyze_call_tool(rest)

    # Comparison operators (strict 2-arity per spec section 8.4)
    {:symbol, op} when op in [:=, :'not=', :>, :<, :>=, :<=] ->
      analyze_comparison(op, rest)

    # Generic function call
    _ -> analyze_call(list)
  end
end

defp do_analyze({:list, []}) do
  {:error, {:invalid_form, "Empty list is not a valid expression"}}
end
```

### 3.3 `let` — Local Bindings

```elixir
defp analyze_let([bindings_ast, body_ast]) do
  with {:ok, bindings} <- analyze_bindings(bindings_ast),
       {:ok, body} <- do_analyze(body_ast) do
    {:ok, {:let, bindings, body}}
  end
end

defp analyze_let(_),
  do: {:error, {:invalid_arity, :let, "expected (let [bindings] body)"}}

defp analyze_bindings({:vector, elems}) do
  if rem(length(elems), 2) != 0 do
    {:error, {:invalid_form, "let bindings require even number of forms"}}
  else
    elems
    |> Enum.chunk_every(2)
    |> Enum.reduce_while({:ok, []}, fn [pattern_ast, value_ast], {:ok, acc} ->
      with {:ok, pattern} <- analyze_pattern(pattern_ast),
           {:ok, value} <- do_analyze(value_ast) do
        {:cont, {:ok, [{:binding, pattern, value} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end
end

defp analyze_bindings(_),
  do: {:error, {:invalid_form, "let bindings must be a vector"}}
```

### 3.4 Pattern Analysis (Destructuring)

```elixir
# Simple variable binding
defp analyze_pattern({:symbol, name}), do: {:ok, {:var, name}}

# Map destructuring: {:keys [a b]}
defp analyze_pattern({:map, pairs}) do
  analyze_destructure_map(pairs)
end

defp analyze_pattern(other),
  do: {:error, {:unsupported_pattern, other}}

defp analyze_destructure_map(pairs) do
  # Extract :keys, :or, :as from pairs
  keys_pair = Enum.find(pairs, fn {{:keyword, k}, _} -> k == :keys end)
  or_pair = Enum.find(pairs, fn {{:keyword, k}, _} -> k == :or end)
  as_pair = Enum.find(pairs, fn {{:keyword, k}, _} -> k == :as end)

  case keys_pair do
    {{:keyword, :keys}, {:vector, key_asts}} ->
      keys = Enum.map(key_asts, fn
        {:symbol, name} -> name
        {:keyword, k} -> k
      end)

      defaults = case or_pair do
        {{:keyword, :or}, {:map, default_pairs}} ->
          Enum.map(default_pairs, fn {{:keyword, k}, v} -> {k, v} end)
        nil -> []
      end

      base_pattern = {:destructure, {:keys, keys, defaults}}

      case as_pair do
        {{:keyword, :as}, {:symbol, as_name}} ->
          {:ok, {:destructure, {:as, as_name, base_pattern}}}
        nil ->
          {:ok, base_pattern}
      end

    _ ->
      {:error, {:unsupported_pattern, pairs}}
  end
end
```

### 3.5 `if` and `when`

```elixir
# if requires exactly 3 args (else is mandatory)
defp analyze_if([cond_ast, then_ast, else_ast]) do
  with {:ok, c} <- do_analyze(cond_ast),
       {:ok, t} <- do_analyze(then_ast),
       {:ok, e} <- do_analyze(else_ast) do
    {:ok, {:if, c, t, e}}
  end
end

defp analyze_if(_),
  do: {:error, {:invalid_arity, :if, "expected (if cond then else)"}}

# when desugars to if with nil else
defp analyze_when([cond_ast, body_ast]) do
  with {:ok, c} <- do_analyze(cond_ast),
       {:ok, b} <- do_analyze(body_ast) do
    {:ok, {:if, c, b, nil}}
  end
end

defp analyze_when(_),
  do: {:error, {:invalid_arity, :when, "expected (when cond body)"}}
```

### 3.6 `cond` → Nested `if`

```elixir
defp analyze_cond([]) do
  {:error, {:invalid_cond_form, "cond requires at least one test/result pair"}}
end

defp analyze_cond(args) do
  with {:ok, pairs, default} <- split_cond_args(args) do
    build_nested_if(pairs, default)
  end
end

defp split_cond_args(args) do
  # Check if last two forms are :else default
  case Enum.split(args, length(args) - 2) do
    {prefix, [{:keyword, :else}, default_ast]} ->
      validate_pairs(prefix, default_ast)

    _ ->
      # No :else clause, default to nil
      validate_pairs(args, nil)
  end
end

defp validate_pairs(args, default_ast) do
  if rem(length(args), 2) != 0 do
    {:error, {:invalid_cond_form, "cond requires even number of test/result forms"}}
  else
    pairs = args |> Enum.chunk_every(2) |> Enum.map(fn [c, r] -> {c, r} end)
    {:ok, pairs, default_ast}
  end
end

defp build_nested_if(pairs, default_ast) do
  with {:ok, default_core} <- maybe_analyze(default_ast) do
    pairs
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, default_core}, fn {c_ast, r_ast}, {:ok, acc} ->
      with {:ok, c} <- do_analyze(c_ast),
           {:ok, r} <- do_analyze(r_ast) do
        {:cont, {:ok, {:if, c, r, acc}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end

defp maybe_analyze(nil), do: {:ok, nil}
defp maybe_analyze(ast), do: do_analyze(ast)
```

### 3.7 `fn` — Anonymous Functions

```elixir
defp analyze_fn([params_ast, body_ast]) do
  with {:ok, params} <- analyze_fn_params(params_ast),
       {:ok, body} <- do_analyze(body_ast) do
    {:ok, {:fn, params, body}}
  end
end

defp analyze_fn(_),
  do: {:error, {:invalid_arity, :fn, "expected (fn [params] body)"}}

# Support multiple params: (fn [x y] body)
# NOTE: Destructuring is NOT allowed in fn params (only simple symbols)
# Use: (fn [m] (let [{:keys [a b]} m] ...)) instead
defp analyze_fn_params({:vector, param_asts}) do
  params =
    Enum.reduce_while(param_asts, {:ok, []}, fn ast, {:ok, acc} ->
      case analyze_simple_param(ast) do
        {:ok, pattern} -> {:cont, {:ok, [pattern | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)

  case params do
    {:ok, rev} -> {:ok, Enum.reverse(rev)}
    other -> other
  end
end

defp analyze_fn_params(_),
  do: {:error, {:invalid_form, "fn parameters must be a vector"}}

# Only simple symbols allowed as fn params (no destructuring)
defp analyze_simple_param({:symbol, name}), do: {:ok, {:var, name}}

defp analyze_simple_param(other),
  do: {:error, {:invalid_form,
    "fn parameters must be simple symbols, not destructuring patterns. " <>
    "Use (fn [m] (let [{:keys [a b]} m] ...)) instead. Got: #{inspect(other)}"}}
```

### 3.8 `and` / `or` — Short-Circuit Logic

```elixir
# and/or are special forms for short-circuit evaluation
defp analyze_and(args) do
  with {:ok, exprs} <- analyze_list(args) do
    {:ok, {:and, exprs}}
  end
end

defp analyze_or(args) do
  with {:ok, exprs} <- analyze_list(args) do
    {:ok, {:or, exprs}}
  end
end
```

### 3.9 Threading Macros → Nested Calls

```elixir
defp analyze_thread(kind, []) do
  {:error, {:invalid_thread_form, kind, "requires at least one expression"}}
end

defp analyze_thread(kind, [first | steps]) do
  with {:ok, acc} <- do_analyze(first) do
    thread_steps(kind, acc, steps)
  end
end

defp thread_steps(_kind, acc, []), do: {:ok, acc}

defp thread_steps(kind, acc, [step | rest]) do
  with {:ok, acc2} <- apply_thread_step(kind, acc, step) do
    thread_steps(kind, acc2, rest)
  end
end

# Step is a list: (f args...)
defp apply_thread_step(kind, acc, {:list, [f_ast | arg_asts]}) do
  with {:ok, f} <- do_analyze(f_ast),
       {:ok, args} <- analyze_list(arg_asts) do
    new_args = case kind do
      :'->' -> [acc | args]        # thread-first
      :->> -> args ++ [acc]        # thread-last
    end
    {:ok, {:call, f, new_args}}
  end
end

# Step is a symbol: f → (f acc)
defp apply_thread_step(_kind, acc, step_ast) do
  with {:ok, f} <- do_analyze(step_ast) do
    {:ok, {:call, f, [acc]}}
  end
end
```

### 3.10 `where` — Predicate Builder

```elixir
defp analyze_where(args) do
  case args do
    # Truthy check: (where :field)
    [field_ast] ->
      with {:ok, field_path} <- analyze_field_path(field_ast) do
        {:ok, {:where, field_path, :truthy, nil}}
      end

    # Comparison: (where :field op value)
    [field_ast, {:symbol, op}, value_ast] ->
      with {:ok, field_path} <- analyze_field_path(field_ast),
           {:ok, op_tag} <- classify_where_op(op),
           {:ok, value} <- do_analyze(value_ast) do
        {:ok, {:where, field_path, op_tag, value}}
      end

    _ ->
      {:error, {:invalid_where_form,
                "expected (where field) or (where field op value)"}}
  end
end

defp analyze_field_path({:keyword, k}) do
  {:ok, {:field, [{:keyword, k}]}}
end

defp analyze_field_path({:vector, elems}) do
  segments = Enum.map(elems, fn
    {:keyword, k} -> {:keyword, k}
    {:string, s} -> {:string, s}
  end)
  {:ok, {:field, segments}}
end

defp analyze_field_path(other) do
  {:error, {:invalid_where_form,
            "field must be keyword or vector, got: #{inspect(other)}"}}
end

defp classify_where_op(:=), do: {:ok, :eq}
defp classify_where_op(:'not='), do: {:ok, :not_eq}
defp classify_where_op(:>), do: {:ok, :gt}
defp classify_where_op(:<), do: {:ok, :lt}
defp classify_where_op(:>=), do: {:ok, :gte}
defp classify_where_op(:<=), do: {:ok, :lte}
defp classify_where_op(:includes), do: {:ok, :includes}
defp classify_where_op(:in), do: {:ok, :in}
defp classify_where_op(op), do: {:error, {:invalid_where_operator, op}}
```

### 3.11 Predicate Combinators

```elixir
# Allow empty: (all-of) → always true, (any-of) → always false
defp analyze_pred_comb(kind, args) do
  with {:ok, preds} <- analyze_list(args) do
    {:ok, {:pred_combinator, kind, preds}}
  end
end
```

### 3.12 `call` — Tool Invocation

```elixir
# (call "tool-name") — no args
defp analyze_call_tool([{:string, name}]) do
  {:ok, {:call_tool, name, {:map, []}}}
end

# (call "tool-name" args-map) — args must be a map
defp analyze_call_tool([{:string, name}, args_ast]) do
  with {:ok, args_core} <- do_analyze(args_ast) do
    case args_core do
      {:map, _} = args_map ->
        {:ok, {:call_tool, name, args_map}}

      other ->
        {:error, {:invalid_form, "call args must be a map, got: #{inspect(other)}"}}
    end
  end
end

# Invalid tool name
defp analyze_call_tool([other | _]) do
  {:error, {:invalid_call_tool_name,
            "tool name must be string literal, got: #{inspect(other)}"}}
end

defp analyze_call_tool(_) do
  {:error, {:invalid_arity, :call,
            "expected (call \"tool-name\") or (call \"tool-name\" args)"}}
end
```

### 3.13 Comparison Operators (Strict 2-Arity)

Per the specification (section 8.4), comparison operators are strictly 2-arity.
Chained comparisons like `(< 1 2 3)` are not supported.

```elixir
# Comparison operators require exactly 2 arguments
defp analyze_comparison(op, [left_ast, right_ast]) do
  with {:ok, left} <- do_analyze(left_ast),
       {:ok, right} <- do_analyze(right_ast) do
    {:ok, {:call, {:var, op}, [left, right]}}
  end
end

defp analyze_comparison(op, args) do
  {:error, {:invalid_arity, op,
            "comparison operators require exactly 2 arguments, got #{length(args)}. " <>
            "Use (and (#{op} a b) (#{op} b c)) for chained comparisons."}}
end
```

### 3.14 Generic Function Call

```elixir
# Everything else: (f arg1 arg2 ...)
defp analyze_call({:list, [f_ast | arg_asts]}) do
  with {:ok, f} <- do_analyze(f_ast),
       {:ok, args} <- analyze_list(arg_asts) do
    {:ok, {:call, f, args}}
  end
end
```

### 3.15 Helper Functions

```elixir
defp analyze_list(xs) do
  xs
  |> Enum.reduce_while({:ok, []}, fn x, {:ok, acc} ->
    case do_analyze(x) do
      {:ok, x2} -> {:cont, {:ok, [x2 | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
  |> case do
    {:ok, rev} -> {:ok, Enum.reverse(rev)}
    other -> other
  end
end

defp analyze_pairs(pairs) do
  pairs
  |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
    with {:ok, k2} <- do_analyze(k),
         {:ok, v2} <- do_analyze(v) do
      {:cont, {:ok, [{k2, v2} | acc]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
  |> case do
    {:ok, rev} -> {:ok, Enum.reverse(rev)}
    other -> other
  end
end
```

---

## 4. Error Reporting Summary

| Form | Error Type | Condition |
|------|------------|-----------|
| `where` | `:invalid_where_form` | Wrong arity or shape |
| `where` | `:invalid_where_operator` | Unknown operator |
| `all-of`, etc. | (none - empty allowed) | — |
| `let` | `:invalid_form` | Bindings not vector or odd count |
| `let` | `:unsupported_pattern` | Unknown destructuring form |
| `fn` | `:invalid_arity` | Not `(fn [params] body)` |
| `if` | `:invalid_arity` | Not exactly 3 args |
| `when` | `:invalid_arity` | Not exactly 2 args |
| `cond` | `:invalid_cond_form` | Empty or odd pair count |
| `call` | `:invalid_call_tool_name` | Non-string tool name |
| `->`, `->>` | `:invalid_thread_form` | No expressions |
| `=`, `>`, `<`, etc. | `:invalid_arity` | Not exactly 2 args (comparisons are strict 2-arity) |
| General | `:invalid_form` | Empty list, etc. |

---

## 5. Testing Strategy

```elixir
defmodule PtcRunner.Lisp.AnalyzeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "literals pass through" do
    test "nil, booleans, numbers" do
      assert {:ok, nil} = Analyze.analyze(nil)
      assert {:ok, true} = Analyze.analyze(true)
      assert {:ok, 42} = Analyze.analyze(42)
    end
  end

  describe "symbols become vars" do
    test "regular symbol" do
      assert {:ok, {:var, :filter}} = Analyze.analyze({:symbol, :filter})
    end

    test "ctx namespace" do
      assert {:ok, {:ctx, :input}} = Analyze.analyze({:ns_symbol, :ctx, :input})
    end

    test "memory namespace" do
      assert {:ok, {:memory, :results}} = Analyze.analyze({:ns_symbol, :memory, :results})
    end
  end

  describe "when desugars to if" do
    test "when becomes if with nil else" do
      raw = {:list, [{:symbol, :when}, true, 42]}
      assert {:ok, {:if, true, 42, nil}} = Analyze.analyze(raw)
    end
  end

  describe "cond desugars to nested if" do
    test "simple cond" do
      raw = {:list, [
        {:symbol, :cond},
        {:symbol, :a}, 1,
        {:symbol, :b}, 2,
        {:keyword, :else}, 3
      ]}
      assert {:ok, {:if, {:var, :a}, 1, {:if, {:var, :b}, 2, 3}}} = Analyze.analyze(raw)
    end
  end

  describe "threading desugars to nested calls" do
    test "thread-last" do
      # (->> x (f a) (g b)) → (g b (f a x))
      raw = {:list, [
        {:symbol, :->>},
        {:symbol, :x},
        {:list, [{:symbol, :f}, {:symbol, :a}]},
        {:list, [{:symbol, :g}, {:symbol, :b}]}
      ]}

      assert {:ok, {:call, {:var, :g}, [
        {:var, :b},
        {:call, {:var, :f}, [{:var, :a}, {:var, :x}]}
      ]}} = Analyze.analyze(raw)
    end
  end

  describe "where validation" do
    test "valid where with operator" do
      raw = {:list, [{:symbol, :where}, {:keyword, :status}, {:symbol, :=}, {:string, "active"}]}
      assert {:ok, {:where, {:field, [{:keyword, :status}]}, :eq, {:string, "active"}}} =
        Analyze.analyze(raw)
    end

    test "truthy check" do
      raw = {:list, [{:symbol, :where}, {:keyword, :active}]}
      assert {:ok, {:where, {:field, [{:keyword, :active}]}, :truthy, nil}} =
        Analyze.analyze(raw)
    end

    test "invalid operator" do
      raw = {:list, [{:symbol, :where}, {:keyword, :x}, {:symbol, :like}, {:string, "foo"}]}
      assert {:error, {:invalid_where_operator, :like}} = Analyze.analyze(raw)
    end
  end

  describe "predicate combinators" do
    test "empty all-of is allowed" do
      raw = {:list, [{:symbol, :'all-of'}]}
      assert {:ok, {:pred_combinator, :all_of, []}} = Analyze.analyze(raw)
    end
  end

  describe "call tool" do
    test "with args" do
      raw = {:list, [{:symbol, :call}, {:string, "get-users"}, {:map, []}]}
      assert {:ok, {:call_tool, "get-users", {:map, []}}} = Analyze.analyze(raw)
    end

    test "without args" do
      raw = {:list, [{:symbol, :call}, {:string, "get-users"}]}
      assert {:ok, {:call_tool, "get-users", {:map, []}}} = Analyze.analyze(raw)
    end

    test "non-string name rejected" do
      raw = {:list, [{:symbol, :call}, {:symbol, :'get-users'}]}
      assert {:error, {:invalid_call_tool_name, _}} = Analyze.analyze(raw)
    end
  end

  describe "comparison operators (strict 2-arity)" do
    test "valid 2-arity comparison" do
      raw = {:list, [{:symbol, :<}, 1, 2]}
      assert {:ok, {:call, {:var, :<}, [1, 2]}} = Analyze.analyze(raw)
    end

    test "all comparison operators accept exactly 2 args" do
      for op <- [:=, :'not=', :>, :<, :>=, :<=] do
        raw = {:list, [{:symbol, op}, {:symbol, :a}, {:symbol, :b}]}
        assert {:ok, {:call, {:var, ^op}, [{:var, :a}, {:var, :b}]}} = Analyze.analyze(raw)
      end
    end

    test "chained comparison (3 args) is rejected" do
      raw = {:list, [{:symbol, :<}, 1, 2, 3]}
      assert {:error, {:invalid_arity, :<, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 3"
    end

    test "single arg comparison is rejected" do
      raw = {:list, [{:symbol, :>}, 1]}
      assert {:error, {:invalid_arity, :>, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 1"
    end

    test "zero arg comparison is rejected" do
      raw = {:list, [{:symbol, :=}]}
      assert {:error, {:invalid_arity, :=, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 0"
    end
  end
end
```

---

## 6. Integration

Full pipeline:

```elixir
defmodule PtcRunner.Lisp do
  alias PtcRunner.Lisp.{Parser, Analyze, Eval}

  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})

    with {:ok, raw_ast} <- Parser.parse(source),
         {:ok, core_ast} <- Analyze.analyze(raw_ast),
         {:ok, result, new_memory} <- Eval.eval(core_ast, ctx, memory, tools) do
      apply_memory_contract(result, memory, new_memory)
    end
  end

  defp apply_memory_contract(result, old_memory, _new_memory) when not is_map(result) do
    {:ok, result, old_memory}
  end

  defp apply_memory_contract(result, old_memory, _new_memory) do
    case Map.pop(result, :result) do
      {nil, map_result} ->
        {:ok, map_result, Map.merge(old_memory, map_result)}

      {return_value, rest} ->
        {:ok, return_value, Map.merge(old_memory, rest)}
    end
  end
end
```

---

## 7. Next Steps

After implementing the Analyze layer:

1. **Eval layer** — Interpreter for CoreAST
   - How `where` becomes a closure
   - How predicate combinators work
   - Short-circuit `and`/`or` evaluation
   - Memory contract implementation

2. **Error formatting** — Convert error tuples to LLM-friendly messages

3. **Source locations** — Thread line/column through for better errors

---

## References

- [PTC-Lisp Specification](ptc-lisp-specification.md)
- [Parser Implementation Plan](ptc-lisp-parser-plan.md)
