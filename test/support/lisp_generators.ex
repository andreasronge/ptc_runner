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
    # Filter out NaN: NaN is the only value where v != v is true
    |> filter(fn v -> v == v end)
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

  # Reserved words that cannot be used as identifiers (they have special
  # string interpolation behavior that breaks formatting)
  @reserved_words ~w(nil true false)

  @doc "Generate a valid identifier string"
  def gen_identifier do
    bind(string(?a..?z, length: 1), fn first ->
      bind(string([?a..?z, ?0..?9, ?_], max_length: 10), fn rest ->
        constant(first <> rest)
      end)
    end)
    |> filter(&(&1 not in @reserved_words))
  end

  # ============================================================
  # Symbols and Variables
  # ============================================================

  @doc "Generate a builtin function symbol"
  def gen_builtin_symbol do
    # Common builtins that are safe to call
    member_of([
      {:symbol, :+},
      {:symbol, :-},
      {:symbol, :*},
      {:symbol, :first},
      {:symbol, :last},
      {:symbol, :count},
      {:symbol, :reverse},
      {:symbol, :sort},
      {:symbol, :distinct},
      {:symbol, :empty?},
      {:symbol, :nil?},
      {:symbol, :number?},
      {:symbol, :inc},
      {:symbol, :dec},
      {:symbol, :abs},
      {:symbol, :not},
      {:symbol, :keys},
      {:symbol, :vals}
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

  # ============================================================
  # Collections (with depth control)
  # ============================================================

  @doc "Generate a vector of expressions"
  def gen_vector(depth, _scope) when depth <= 0 do
    constant({:vector, []})
  end

  def gen_vector(depth, scope) do
    list_of(gen_expr(depth - 1, scope), max_length: 4)
    |> map(&{:vector, &1})
  end

  @doc "Generate a map with keyword keys"
  def gen_map(depth, _scope) when depth <= 0 do
    constant({:map, []})
  end

  def gen_map(depth, scope) do
    list_of(
      tuple({gen_keyword(), gen_expr(depth - 1, scope)}),
      max_length: 3
    )
    |> map(&{:map, &1})
  end

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

  defp gen_where_comparison(_depth) do
    bind(gen_where_field(), fn field ->
      bind(gen_where_operator(), fn op ->
        bind(gen_where_value(op), fn value ->
          constant({:list, [{:symbol, :where}, field, {:symbol, op}, value]})
        end)
      end)
    end)
  end

  defp gen_where_with_path(_depth) do
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
end
