# PTC-Lisp Property-Based Testing Plan

This document specifies property-based testing infrastructure for the PTC-Lisp interpreter.

**Status:** Draft v2 (aligned with Spec v0.3.2)

## Raw AST Reference

The parser produces these exact AST node types (from `lib/ptc_runner/lisp/ast.ex`):

| Node Type | Raw AST Structure | Example Input | Example AST |
|-----------|------------------|---------------|-------------|
| Nil | `nil` | `nil` | `nil` |
| Boolean | `true` \| `false` | `true` | `true` |
| Integer | `integer()` | `42` | `42` |
| Float | `float()` | `3.14` | `3.14` |
| String | `{:string, String.t()}` | `"hello"` | `{:string, "hello"}` |
| Keyword | `{:keyword, atom()}` | `:name` | `{:keyword, :name}` |
| Symbol | `{:symbol, atom()}` | `filter` | `{:symbol, :filter}` |
| NS Symbol | `{:ns_symbol, :ctx\|:memory, atom()}` | `ctx/input` | `{:ns_symbol, :ctx, :input}` |
| Vector | `{:vector, [t()]}` | `[1 2]` | `{:vector, [1, 2]}` |
| Map | `{:map, [{t(), t()}]}` | `{:a 1}` | `{:map, [{{:keyword, :a}, 1}]}` |
| List/Call | `{:list, [t()]}` | `(+ 1 2)` | `{:list, [{:symbol, :+}, 1, 2]}` |

**String escape sequences** (from parser): `\\`, `\"`, `\n`, `\t`, `\r`

## Supported Language Features (for generator reference)

**Special Forms:** `let`, `if`, `when`, `cond`, `fn`, `and`, `or`, `->`, `->>`, `where`, `all-of`, `any-of`, `none-of`, `call`

**Built-in Functions:**
- Collections: `filter`, `remove`, `find`, `map`, `mapv`, `pluck`, `select-keys`, `sort`, `sort-by`, `reverse`, `first`, `last`, `nth`, `take`, `drop`, `take-while`, `drop-while`, `distinct`, `concat`, `into`, `flatten`, `interleave`, `zip`, `count`, `empty?`, `sum-by`, `avg-by`, `min-by`, `max-by`, `group-by`, `reduce`, `some`, `every?`, `not-any?`, `contains?`
- Maps: `get`, `get-in`, `assoc`, `assoc-in`, `update`, `update-in`, `dissoc`, `merge`, `keys`, `vals`
- Arithmetic: `+`, `-`, `*`, `/`, `mod`, `inc`, `dec`, `abs`, `max`, `min`
- Comparison: `=`, `not=`, `<`, `>`, `<=`, `>=`
- Type predicates: `nil?`, `some?`, `boolean?`, `number?`, `string?`, `keyword?`, `vector?`, `map?`, `coll?`, `zero?`, `pos?`, `neg?`, `even?`, `odd?`
- Logic: `not`

**Where operators:** `=`, `not=`, `>`, `<`, `>=`, `<=`, `includes`, `in`, (truthy check)

## Existing Test Infrastructure

The codebase already has test support files in `test/support/`:
- `llm_benchmark.ex` - Benchmarking utility for comparing LLM models
- `ptc_lisp_benchmark.ex` - Phase 1 evaluation for LLM generation of PTC-Lisp programs
- `llm_client.ex` - LLM client for E2E testing

**Note:** The new generators module follows the existing pattern of placing test utilities in `test/support/`.

---

## Overview

Property-based testing (PBT) systematically explores the expression space of PTC-Lisp to catch edge cases that hand-written tests miss. This uses StreamData, the standard Elixir PBT library (pure Elixir/Erlang).

**Strategy:** Generate valid Raw AST nodes, serialize them to source code, then test properties.

**Benefits:**
1. Catches edge cases hand-written tests miss
2. Validates parser/formatter roundtrip
3. Ensures evaluation determinism
4. Tests arithmetic and collection invariants
5. Validates type predicate consistency

---

## 1. Dependencies

Add StreamData to `mix.exs`:

```elixir
defp deps do
  [
    # ... existing deps ...
    {:stream_data, "~> 1.1", only: [:test, :dev]}
  ]
end
```

---

## 2. AST Formatter Module

Create `lib/ptc_runner/lisp/formatter.ex` to serialize Raw AST back to source code.

```elixir
defmodule PtcRunner.Lisp.Formatter do
  @moduledoc """
  Serialize PTC-Lisp AST to source code string.

  Used for:
  - Property-based testing (roundtrip: AST -> source -> parse -> AST)
  - Debugging (pretty-print generated ASTs)
  """

  @doc "Format an AST node as PTC-Lisp source code"
  @spec format(term()) :: String.t()
  def format(nil), do: "nil"
  def format(true), do: "true"
  def format(false), do: "false"
  def format(n) when is_integer(n), do: Integer.to_string(n)

  def format(n) when is_float(n) do
    # Ensure consistent float formatting
    :erlang.float_to_binary(n, [:compact, decimals: 10])
  end

  def format({:string, s}), do: ~s("#{escape_string(s)}")
  def format({:keyword, k}), do: ":#{k}"
  def format({:symbol, name}), do: Atom.to_string(name)
  def format({:ns_symbol, ns, key}), do: "#{ns}/#{key}"

  def format({:vector, elems}) do
    "[#{format_list(elems)}]"
  end

  def format({:map, pairs}) do
    "{#{format_pairs(pairs)}}"
  end

  def format({:list, elems}) do
    "(#{format_list(elems)})"
  end

  # --- Helpers ---

  defp format_list(elems) do
    Enum.map_join(elems, " ", &format/1)
  end

  defp format_pairs(pairs) do
    pairs
    |> Enum.map(fn {k, v} -> "#{format(k)} #{format(v)}" end)
    |> Enum.join(" ")
  end

  defp escape_string(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end
end
```

---

## 3. Test Generator Module

Create `test/support/lisp_generators.ex` with StreamData generators.

### 3.1 Literal Generators

```elixir
defmodule PtcRunner.TestSupport.LispGenerators do
  @moduledoc """
  StreamData generators for PTC-Lisp AST nodes.

  Generates valid Raw AST that can be serialized and parsed.
  """

  use ExUnitProperties

  # ============================================================
  # Primitive Literals
  # ============================================================

  @doc "Generate nil literal"
  def gen_nil, do: constant(nil)

  @doc "Generate boolean literal"
  def gen_boolean, do: boolean()

  @doc "Generate integer literal (bounded to avoid overflow)"
  def gen_integer, do: integer(-1_000_000..1_000_000)

  @doc "Generate float literal (bounded, avoiding special values)"
  def gen_float do
    float(min: -1.0e6, max: 1.0e6)
    # Filter out NaN: NaN != NaN is true, so `not (f != f)` is false for NaN
    |> filter(fn f -> not (f != f) end)
  end

  @doc "Generate simple alphanumeric string literal"
  def gen_string do
    string(:alphanumeric, max_length: 30)
    |> map(&{:string, &1})
  end

  @doc "Generate string literal with escape sequences for roundtrip testing"
  def gen_string_with_escapes do
    # Mix of regular characters and escape sequences
    bind(list_of(gen_string_segment(), min_length: 1, max_length: 5), fn segments ->
      constant({:string, Enum.join(segments)})
    end)
  end

  defp gen_string_segment do
    frequency([
      {5, string(:alphanumeric, min_length: 1, max_length: 10)},
      {1, constant("\n")},
      {1, constant("\t")},
      {1, constant("\r")},
      {1, constant("\\")},
      {1, constant("\"")}
    ])
  end

  @doc "Generate keyword (simple identifier)"
  # Note: String.to_atom/1 is safe here because gen_identifier produces bounded strings
  # from a fixed character set, so no atom table exhaustion risk
  def gen_keyword do
    gen_identifier()
    |> map(&{:keyword, String.to_atom(&1)})
  end

  @doc "Generate a valid identifier string"
  def gen_identifier do
    bind(string(?a..?z, length: 1), fn first ->
      bind(string([?a..?z, ?0..?9, ?_], max_length: 10), fn rest ->
        constant(first <> rest)
      end)
    end)
  end
end
```

### 3.2 Symbol and Variable Generators

```elixir
  # ============================================================
  # Symbols and Variables
  # ============================================================

  @doc "Generate a builtin function symbol"
  def gen_builtin_symbol do
    # Common builtins that are safe to call
    member_of([
      {:symbol, :+}, {:symbol, :-}, {:symbol, :*},
      {:symbol, :first}, {:symbol, :last}, {:symbol, :count},
      {:symbol, :reverse}, {:symbol, :sort}, {:symbol, :distinct},
      {:symbol, :empty?}, {:symbol, :nil?}, {:symbol, :number?},
      {:symbol, :inc}, {:symbol, :dec}, {:symbol, :abs},
      {:symbol, :not}, {:symbol, :keys}, {:symbol, :vals}
    ])
  end

  @doc "Generate a variable symbol from scope"
  def gen_variable_from_scope([]), do: gen_builtin_symbol()
  def gen_variable_from_scope(scope) do
    frequency([
      {3, member_of(scope) |> map(&{:symbol, &1})},
      {1, gen_builtin_symbol()}
    ])
  end

  @doc "Generate a context namespace access"
  def gen_ctx_access do
    gen_identifier()
    |> map(&{:ns_symbol, :ctx, String.to_atom(&1)})
  end
```

### 3.3 Collection Generators

```elixir
  # ============================================================
  # Collections (with depth control)
  # ============================================================

  @doc "Generate a vector of expressions"
  def gen_vector(depth, scope) when depth <= 0 do
    constant({:vector, []})
  end

  def gen_vector(depth, scope) do
    list_of(gen_expr(depth - 1, scope), max_length: 4)
    |> map(&{:vector, &1})
  end

  @doc "Generate a map with keyword keys"
  def gen_map(depth, scope) when depth <= 0 do
    constant({:map, []})
  end

  def gen_map(depth, scope) do
    list_of(
      tuple({gen_keyword(), gen_expr(depth - 1, scope)}),
      max_length: 3
    )
    |> map(&{:map, &1})
  end
```

### 3.4 Expression Generator (Main Entry Point)

```elixir
  # ============================================================
  # Expression Generator
  # ============================================================

  @doc "Generate a leaf expression (no recursion)"
  def gen_leaf_expr(scope) do
    frequency([
      {3, gen_nil()},
      {3, gen_boolean()},
      {4, gen_integer()},
      {2, gen_float()},
      {3, gen_string()},
      {3, gen_keyword()},
      {2, gen_variable_from_scope(scope)},
      {2, gen_ctx_access()}
    ])
  end

  @doc "Generate any expression with depth control"
  def gen_expr(depth, scope \\ [])

  def gen_expr(depth, scope) when depth <= 0 do
    gen_leaf_expr(scope)
  end

  def gen_expr(depth, scope) do
    frequency([
      {5, gen_leaf_expr(scope)},
      {2, gen_vector(depth - 1, scope)},
      {2, gen_map(depth - 1, scope)},
      {2, gen_if(depth - 1, scope)},
      {2, gen_let(depth - 1, scope)},
      {1, gen_fn(depth - 1, scope)},
      {2, gen_arithmetic_call(depth - 1, scope)},
      {1, gen_comparison(depth - 1, scope)},
      {1, gen_and(depth - 1, scope)},
      {1, gen_or(depth - 1, scope)},
      {1, gen_where(depth - 1)},
      {1, gen_tool_call(depth - 1, scope)}
    ])
  end
```

### 3.5 Special Form Generators

```elixir
  # ============================================================
  # Special Forms
  # ============================================================

  @doc "Generate if expression (3 branches required)"
  def gen_if(depth, scope) do
    tuple({gen_expr(depth, scope), gen_expr(depth, scope), gen_expr(depth, scope)})
    |> map(fn {cond_expr, then_expr, else_expr} ->
      {:list, [{:symbol, :if}, cond_expr, then_expr, else_expr]}
    end)
  end

  @doc "Generate let expression with scope extension"
  def gen_let(depth, scope) do
    bind(integer(1..3), fn binding_count ->
      bind(gen_bindings(binding_count, depth, scope), fn {bindings_ast, new_scope} ->
        bind(gen_expr(depth, new_scope), fn body ->
          constant({:list, [{:symbol, :let}, {:vector, bindings_ast}, body]})
        end)
      end)
    end)
  end

  defp gen_bindings(count, depth, scope) do
    gen_bindings(count, depth, scope, [], scope)
  end

  defp gen_bindings(0, _depth, _scope, acc_bindings, acc_scope) do
    constant({Enum.reverse(acc_bindings), acc_scope})
  end

  defp gen_bindings(count, depth, scope, acc_bindings, acc_scope) do
    bind(gen_identifier(), fn name ->
      name_atom = String.to_atom(name)
      bind(gen_expr(depth, acc_scope), fn value_expr ->
        gen_bindings(
          count - 1,
          depth,
          scope,
          [{:symbol, name_atom}, value_expr | acc_bindings],
          [name_atom | acc_scope]
        )
      end)
    end)
  end

  @doc "Generate fn expression"
  def gen_fn(depth, scope) do
    bind(list_of(gen_identifier(), min_length: 0, max_length: 3), fn param_names ->
      param_atoms = Enum.map(param_names, &String.to_atom/1)
      new_scope = param_atoms ++ scope
      params_ast = Enum.map(param_atoms, &{:symbol, &1})

      bind(gen_expr(depth, new_scope), fn body ->
        constant({:list, [{:symbol, :fn}, {:vector, params_ast}, body]})
      end)
    end)
  end

  @doc "Generate arithmetic call"
  def gen_arithmetic_call(depth, scope) do
    bind(member_of([:+, :-, :*]), fn op ->
      bind(list_of(gen_expr(depth, scope), min_length: 1, max_length: 4), fn args ->
        constant({:list, [{:symbol, op} | args]})
      end)
    end)
  end

  @doc "Generate comparison (strict 2-arity)"
  def gen_comparison(depth, scope) do
    bind(member_of([:=, :"not=", :>, :<, :>=, :<=]), fn op ->
      tuple({gen_expr(depth, scope), gen_expr(depth, scope)})
      |> map(fn {left, right} ->
        {:list, [{:symbol, op}, left, right]}
      end)
    end)
  end

  @doc "Generate and/or expressions"
  def gen_and(depth, scope) do
    # min_length: 1 to avoid generating (and) with no args
    list_of(gen_expr(depth, scope), min_length: 1, max_length: 4)
    |> map(&{:list, [{:symbol, :and} | &1]})
  end

  def gen_or(depth, scope) do
    # min_length: 1 to avoid generating (or) with no args
    list_of(gen_expr(depth, scope), min_length: 1, max_length: 4)
    |> map(&{:list, [{:symbol, :or} | &1]})
  end

  @doc "Generate where predicate"
  def gen_where(depth) do
    frequency([
      {3, gen_where_truthy()},
      {3, gen_where_comparison(depth)},
      {2, gen_where_with_path(depth)}
    ])
  end

  defp gen_where_truthy do
    gen_where_field()
    |> map(&{:list, [{:symbol, :where}, &1]})
  end

  defp gen_where_comparison(depth) do
    bind(gen_where_field(), fn field ->
      bind(gen_where_operator(), fn op ->
        bind(gen_where_value(op), fn value ->
          constant({:list, [{:symbol, :where}, field, {:symbol, op}, value]})
        end)
      end)
    end)
  end

  defp gen_where_with_path(depth) do
    # Generate (where [:key1 :key2] op value) for nested access
    bind(list_of(gen_keyword(), min_length: 2, max_length: 3), fn path_keywords ->
      path = {:vector, path_keywords}
      bind(gen_where_operator(), fn op ->
        bind(gen_where_value(op), fn value ->
          constant({:list, [{:symbol, :where}, path, {:symbol, op}, value]})
        end)
      end)
    end)
  end

  defp gen_where_field do
    # Simple keyword field (most common case)
    gen_keyword()
  end

  defp gen_where_operator do
    # All where operators from spec Section 7.1
    member_of([:=, :"not=", :>, :<, :>=, :<=, :includes, :in])
  end

  defp gen_where_value(op) when op in [:includes, :in] do
    # `includes` checks if collection contains value
    # `in` checks if value is in a collection
    frequency([
      {2, gen_leaf_expr([])},
      {1, list_of(gen_leaf_expr([]), min_length: 1, max_length: 3) |> map(&{:vector, &1})}
    ])
  end

  defp gen_where_value(_op) do
    gen_leaf_expr([])
  end

  @doc "Generate tool call with mocked tool"
  def gen_tool_call(depth, scope) do
    bind(gen_identifier(), fn tool_name ->
      bind(gen_map(depth, scope), fn args_map ->
        constant({:list, [{:symbol, :call}, {:string, tool_name}, args_map]})
      end)
    end)
  end
```

---

## 4. Property Tests

Create `test/ptc_runner/lisp/property_test.exs`.

### 4.1 Setup and Helpers

```elixir
defmodule PtcRunner.Lisp.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.Lisp.{Parser, Formatter}
  alias PtcRunner.TestSupport.LispGenerators, as: Gen

  @moduletag :property

  # Mock tool executor for property tests
  defp mock_tool_executor(name, args) do
    # Return a simple value based on tool name hash
    %{tool: name, args: args, result: :erlang.phash2(name)}
  end
```

### 4.2 Property: Roundtrip Parsing

```elixir
  describe "roundtrip parsing" do
    property "parse(format(ast)) produces equivalent AST" do
      check all ast <- Gen.gen_expr(3) do
        source = Formatter.format(ast)

        case Parser.parse(source) do
          {:ok, parsed} ->
            assert ast_equivalent?(ast, parsed),
              "Roundtrip failed:\nOriginal: #{inspect(ast)}\nSource: #{source}\nParsed: #{inspect(parsed)}"

          {:error, reason} ->
            flunk("Parse failed for source: #{source}\nReason: #{inspect(reason)}")
        end
      end
    end

    # AST equivalence allowing for float precision differences
    defp ast_equivalent?(a, b) when is_float(a) and is_float(b) do
      abs(a - b) < 1.0e-9
    end

    defp ast_equivalent?({tag, children1}, {tag, children2}) when is_list(children1) do
      length(children1) == length(children2) and
        Enum.zip(children1, children2) |> Enum.all?(fn {c1, c2} -> ast_equivalent?(c1, c2) end)
    end

    defp ast_equivalent?({tag, v1}, {tag, v2}), do: ast_equivalent?(v1, v2)
    defp ast_equivalent?(a, b), do: a == b

    property "string escape sequences roundtrip correctly" do
      check all str_ast <- Gen.gen_string_with_escapes() do
        source = Formatter.format(str_ast)

        case Parser.parse(source) do
          {:ok, parsed} ->
            assert ast_equivalent?(str_ast, parsed),
              "String roundtrip failed:\nOriginal: #{inspect(str_ast)}\nSource: #{source}\nParsed: #{inspect(parsed)}"

          {:error, reason} ->
            flunk("Parse failed for escaped string: #{source}\nReason: #{inspect(reason)}")
        end
      end
    end
  end
```

### 4.3 Property: Valid Programs Don't Crash

```elixir
  describe "evaluation safety" do
    property "valid programs evaluate without crashes" do
      check all ast <- Gen.gen_expr(2) do
        source = Formatter.format(ast)
        ctx = %{items: [1, 2, 3], user: %{name: "test", active: true}}

        result = PtcRunner.Lisp.run(source,
          context: ctx,
          tools: %{"test_tool" => &mock_tool_executor/2}
        )

        # Should return {:ok, _, _, _} or {:error, _}, never crash
        assert match?({:ok, _, _, _}, result) or match?({:error, _}, result),
          "Unexpected result for source: #{source}\nResult: #{inspect(result)}"
      end
    end
  end
```

### 4.4 Property: Evaluation Determinism

```elixir
  describe "determinism" do
    property "same input always produces same output" do
      check all ast <- Gen.gen_expr(2) do
        source = Formatter.format(ast)
        ctx = %{x: 42, items: [1, 2, 3]}
        tools = %{"tool" => fn _ -> "fixed" end}

        result1 = PtcRunner.Lisp.run(source, context: ctx, tools: tools)
        result2 = PtcRunner.Lisp.run(source, context: ctx, tools: tools)

        assert result1 == result2,
          "Non-deterministic evaluation for: #{source}"
      end
    end
  end
```

### 4.5 Property: Arithmetic Identities

```elixir
  describe "arithmetic identities" do
    property "x + 0 = x" do
      check all n <- one_of([Gen.gen_integer(), Gen.gen_float()]) do
        source = "(+ #{n} 0)"
        assert {:ok, result, _, _} = PtcRunner.Lisp.run(source)
        assert_numbers_equal(result, n)
      end
    end

    property "x * 1 = x" do
      check all n <- one_of([Gen.gen_integer(), Gen.gen_float()]) do
        source = "(* #{n} 1)"
        assert {:ok, result, _, _} = PtcRunner.Lisp.run(source)
        assert_numbers_equal(result, n)
      end
    end

    property "x - x = 0" do
      check all n <- Gen.gen_integer() do
        source = "(- #{n} #{n})"
        assert {:ok, 0, _, _} = PtcRunner.Lisp.run(source)
      end
    end

    defp assert_numbers_equal(a, b) when is_float(a) or is_float(b) do
      assert abs(a - b) < 1.0e-9, "Expected #{b}, got #{a}"
    end

    defp assert_numbers_equal(a, b), do: assert(a == b)
  end
```

### 4.6 Property: Collection Invariants

```elixir
  describe "collection invariants" do
    property "count(filter(pred, xs)) <= count(xs)" do
      check all items <- list_of(map_of(atom(:alphanumeric), integer(), max_length: 3), max_length: 10) do
        ctx = %{items: items}
        source = "(<= (count (filter (where :a) ctx/items)) (count ctx/items))"

        case PtcRunner.Lisp.run(source, context: ctx) do
          {:ok, true, _, _} -> :ok
          {:ok, false, _, _} -> flunk("filter increased count")
          {:error, _} -> :ok  # Type errors are acceptable
        end
      end
    end

    property "map preserves count" do
      check all items <- list_of(integer(), max_length: 20) do
        ctx = %{items: items}
        source = "(= (count ctx/items) (count (map inc ctx/items)))"
        assert {:ok, true, _, _} = PtcRunner.Lisp.run(source, context: ctx)
      end
    end

    property "reverse(reverse(xs)) = xs" do
      check all items <- list_of(integer(), max_length: 20) do
        ctx = %{items: items}
        source = "(= ctx/items (reverse (reverse ctx/items)))"
        assert {:ok, true, _, _} = PtcRunner.Lisp.run(source, context: ctx)
      end
    end
  end
```

### 4.7 Property: Type Predicates

```elixir
  describe "type predicates" do
    property "exactly one type predicate is true for primitives" do
      # Note: PTC-Lisp context values are Elixir values, not AST nodes
      # So strings in context are plain binaries, not {:string, s} tuples
      check all value <- one_of([
        constant(nil),
        boolean(),
        integer(),
        float(),
        string(:alphanumeric, max_length: 20)  # Plain Elixir string for context
      ]) do
        ctx = %{v: value}

        predicates = ["nil?", "boolean?", "number?", "string?"]

        results = Enum.map(predicates, fn pred ->
          case PtcRunner.Lisp.run("(#{pred} ctx/v)", context: ctx) do
            {:ok, result, _, _} -> result
            _ -> false
          end
        end)

        true_count = Enum.count(results, & &1)
        assert true_count == 1,
          "Expected exactly 1 true predicate for #{inspect(value)}, got #{true_count}: #{inspect(Enum.zip(predicates, results))}"
      end
    end
  end
```

### 4.8 Property: Short-Circuit Logic

```elixir
  describe "short-circuit logic" do
    property "and with false short-circuits" do
      check all exprs <- list_of(Gen.gen_leaf_expr([]), min_length: 1, max_length: 3) do
        # Build: (and expr1 false (call "should-not-run" {}))
        formatted_exprs = Enum.map_join(exprs, " ", &Formatter.format/1)
        source = "(and #{formatted_exprs} false (call \"should-not-run\" {}))"

        # Use a tool that would fail if called
        tools = %{"should-not-run" => fn _ -> raise "Tool should not be called!" end}

        result = PtcRunner.Lisp.run(source, tools: tools)

        # Should not crash (tool not called due to short-circuit)
        assert match?({:ok, _, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "or with truthy short-circuits" do
      check all n <- integer(1..1000) do
        source = "(or #{n} (call \"should-not-run\" {}))"
        tools = %{"should-not-run" => fn _ -> raise "Tool should not be called!" end}

        assert {:ok, ^n, _, _} = PtcRunner.Lisp.run(source, tools: tools)
      end
    end
  end
end
```

---

## 5. Implementation Checklist

### Phase 1: Infrastructure
- [ ] Add `stream_data` dependency to mix.exs
- [ ] Create `lib/ptc_runner/lisp/formatter.ex`
- [ ] Create `test/support/lisp_generators.ex`
- [ ] Verify formatter produces valid syntax for all AST types

### Phase 2: Basic Properties
- [ ] Implement roundtrip property test
- [ ] Implement evaluation safety property
- [ ] Implement determinism property

### Phase 3: Domain Properties
- [ ] Implement arithmetic identity properties
- [ ] Implement collection invariant properties
- [ ] Implement type predicate properties
- [ ] Implement short-circuit logic properties

### Phase 4: Integration
- [ ] Add property tests to CI (may need separate job due to runtime)
- [ ] Document any edge cases discovered
- [ ] Fix any bugs found

---

## 6. Testing Strategy

### Run Property Tests

```bash
# Run all property tests
mix test test/ptc_runner/lisp/property_test.exs

# Run with more iterations (thorough)
mix test test/ptc_runner/lisp/property_test.exs --seed 0

# Run specific property
mix test test/ptc_runner/lisp/property_test.exs --only roundtrip
```

### Configuration

Default: 100 iterations per property (fast feedback during development).

For CI, consider:
```elixir
# In test/test_helper.exs
if System.get_env("CI") do
  ExUnitProperties.configure(max_runs: 300)
end
```

---

## 7. Design Decisions

1. **Tool calls**: Include `call` (tool invocation) in generated programs with mocked tool executor
2. **Memory operations**: Exclude `memory/` namespace from generators for simpler testing
3. **Iteration count**: 100 iterations per property (StreamData default, fast feedback)
4. **Depth control**: Max depth 2-3 to avoid explosively large programs
5. **Scope tracking**: Generators track bound variables to produce well-scoped programs
6. **Division excluded**: `/` is not generated in `gen_arithmetic_call` to avoid divide-by-zero errors
7. **Simple special forms only**: `when`, `cond`, threading macros (`->`, `->>`) excluded for initial simplicity
8. **Predicate combinators excluded**: `all-of`, `any-of`, `none-of` not generated initially
9. **Formatter in lib/**: Placed in `lib/` (not `test/support/`) for potential future use in debugging/REPL
10. **String generators**: Both `gen_string` (alphanumeric) and `gen_string_with_escapes` (includes `\n`, `\t`, `\r`, `\"`, `\\`) are provided; escape sequences are tested in dedicated roundtrip property
11. **Where operators**: All spec operators covered including `includes` and `in`; vector paths supported for nested access

---

## 8. Future Enhancements

Once basic property tests are stable, consider adding:

### Additional Generators
- `gen_when(depth, scope)` - Generate `(when cond body)` expressions
- `gen_cond(depth, scope)` - Generate multi-branch `(cond c1 r1 c2 r2 :else default)`
- `gen_thread_last(depth, scope)` - Generate `(->> val (f1) (f2))` pipelines
- `gen_thread_first(depth, scope)` - Generate `(-> val (f1) (f2))` pipelines
- `gen_predicate_combinator(depth)` - Generate `(all-of pred1 pred2)`, `(any-of ...)`, `(none-of ...)`

### Shrinking Helpers
- Custom shrinkers for better failure messages
- `shrink_ast/1` to produce minimal counterexamples

### Additional Properties
- `property "first(concat(xs, ys)) = first(xs) when xs non-empty"`
- `property "sort(sort(xs)) = sort(xs)"` (idempotence)
- `property "count(distinct(xs)) <= count(xs)"`
- Division property with non-zero denominator: `x / 1 = x`

### CI Considerations
- Run property tests in separate CI job if they become slow
- Use `--include property` flag to run only property tests
- Consider matrix testing with different iteration counts

---

## 9. File Structure

```
lib/
  ptc_runner/
    lisp/
      formatter.ex         # NEW: AST -> source serializer

test/
  support/
    lisp_generators.ex     # NEW: StreamData generators
  ptc_runner/
    lisp/
      property_test.exs    # NEW: Property-based tests
```

---

## References

- [PTC-Lisp Specification](ptc-lisp-specification.md)
- [Parser Implementation Plan](ptc-lisp-parser-plan.md)
- [Analyzer Plan](ptc-lisp-analyze-plan.md)
- [Eval Plan](ptc-lisp-eval-plan.md)
- [StreamData Documentation](https://hexdocs.pm/stream_data)
