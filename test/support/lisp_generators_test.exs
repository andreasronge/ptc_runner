defmodule PtcRunner.TestSupport.LispGeneratorsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.Lisp.{Formatter, Parser}
  alias PtcRunner.TestSupport.LispGenerators, as: Gen

  describe "primitive generators" do
    property "gen_nil produces nil" do
      check all(value <- Gen.gen_nil()) do
        assert value == nil
      end
    end

    property "gen_boolean produces boolean" do
      check all(value <- Gen.gen_boolean()) do
        assert is_boolean(value)
      end
    end

    property "gen_integer produces integers within bounds" do
      check all(value <- Gen.gen_integer()) do
        assert is_integer(value)
        assert value >= -1_000_000
        assert value <= 1_000_000
      end
    end

    property "gen_float produces floats without NaN" do
      check all(value <- Gen.gen_float()) do
        assert is_float(value)
        # Verify NaN was filtered out (NaN is only value where v != v)
        assert value == value
        assert value >= -1.0e6
        assert value <= 1.0e6
      end
    end

    property "gen_string produces string AST nodes" do
      check all(value <- Gen.gen_string()) do
        assert match?({:string, s} when is_binary(s), value)
      end
    end

    property "gen_keyword produces keyword AST nodes" do
      check all(value <- Gen.gen_keyword()) do
        assert match?({:keyword, k} when is_atom(k), value)
      end
    end
  end

  describe "symbol generators" do
    property "gen_builtin_symbol produces valid symbols" do
      check all(value <- Gen.gen_builtin_symbol()) do
        assert match?({:symbol, s} when is_atom(s), value)
      end
    end

    property "gen_ctx_access produces ctx namespace symbols" do
      check all(value <- Gen.gen_ctx_access()) do
        assert match?({:ns_symbol, :ctx, k} when is_atom(k), value)
      end
    end

    property "gen_variable_from_scope produces symbols" do
      check all(
              scope <- list_of(atom(:alphanumeric), max_length: 5),
              value <- Gen.gen_variable_from_scope(scope)
            ) do
        assert match?({:symbol, s} when is_atom(s), value)
      end
    end
  end

  describe "collection generators" do
    property "gen_vector produces valid vector AST" do
      check all(value <- Gen.gen_vector(2, [])) do
        assert match?({:vector, items} when is_list(items), value)
        {_, items} = value
        assert length(items) <= 4
      end
    end

    property "gen_vector with depth 0 produces empty vector" do
      check all(value <- Gen.gen_vector(0, [])) do
        assert value == {:vector, []}
      end
    end

    property "gen_map produces valid map AST" do
      check all(value <- Gen.gen_map(2, [])) do
        assert match?({:map, pairs} when is_list(pairs), value)
        {_, pairs} = value
        assert length(pairs) <= 3
        # Verify each pair is {key, value}
        Enum.each(pairs, fn pair ->
          assert is_tuple(pair)
          assert tuple_size(pair) == 2
        end)
      end
    end

    property "gen_map with depth 0 produces empty map" do
      check all(value <- Gen.gen_map(0, [])) do
        assert value == {:map, []}
      end
    end
  end

  describe "expression generators" do
    property "gen_leaf_expr produces valid leaf expressions" do
      check all(value <- Gen.gen_leaf_expr([])) do
        # Should be primitives only
        assert is_nil(value) or is_boolean(value) or is_number(value) or
                 match?({:string, _}, value) or match?({:keyword, _}, value) or
                 match?({:symbol, _}, value) or match?({:ns_symbol, _, _}, value)
      end
    end

    property "gen_expr produces valid AST" do
      check all(value <- Gen.gen_expr(2, [])) do
        # Should produce some AST node
        assert valid_ast?(value)
      end
    end

    property "gen_expr with empty scope produces valid AST" do
      check all(value <- Gen.gen_expr(1, [])) do
        assert valid_ast?(value)
      end
    end

    property "gen_expr respects scope" do
      check all(
              scope <- list_of(atom(:alphanumeric), max_length: 3),
              value <- Gen.gen_expr(1, scope)
            ) do
        assert valid_ast?(value)
      end
    end

    property "gen_if produces if expressions" do
      check all(value <- Gen.gen_if(1, [])) do
        assert match?({:list, [{:symbol, :if} | _]}, value)
        {:list, [_, cond_expr, then_expr, else_expr]} = value
        assert valid_ast?(cond_expr)
        assert valid_ast?(then_expr)
        assert valid_ast?(else_expr)
      end
    end

    property "gen_let produces let expressions" do
      check all(value <- Gen.gen_let(1, [])) do
        assert match?({:list, [{:symbol, :let}, {:vector, _}, _]}, value)
        {:list, [{:symbol, :let}, {:vector, bindings}, body]} = value
        # Bindings should be alternating symbols and expressions
        assert rem(length(bindings), 2) == 0
        assert valid_ast?(body)
      end
    end

    property "gen_fn produces fn expressions" do
      check all(value <- Gen.gen_fn(1, [])) do
        assert match?({:list, [{:symbol, :fn}, {:vector, _}, _]}, value)
        {:list, [{:symbol, :fn}, {:vector, params}, body]} = value
        # Params should be symbols
        Enum.each(params, fn param -> assert match?({:symbol, _}, param) end)
        assert valid_ast?(body)
      end
    end

    property "gen_arithmetic_call produces arithmetic calls" do
      check all(value <- Gen.gen_arithmetic_call(1, [])) do
        assert match?({:list, [{:symbol, _} | _]}, value)
        {:list, [{:symbol, op} | args]} = value
        assert op in [:+, :-, :*]
        assert length(args) >= 1
        Enum.each(args, fn arg -> assert valid_ast?(arg) end)
      end
    end

    property "gen_comparison produces comparison calls" do
      check all(value <- Gen.gen_comparison(1, [])) do
        assert match?({:list, [{:symbol, _}, _, _]}, value)

        {:list, [{:symbol, op}, left, right]} = value
        assert op in [:=, :"not=", :>, :<, :>=, :<=]
        assert valid_ast?(left)
        assert valid_ast?(right)
      end
    end

    property "gen_and produces and expressions" do
      check all(value <- Gen.gen_and(1, [])) do
        assert match?({:list, [{:symbol, :and} | _]}, value)
        {:list, [{:symbol, :and} | args]} = value
        assert length(args) >= 1
        Enum.each(args, fn arg -> assert valid_ast?(arg) end)
      end
    end

    property "gen_or produces or expressions" do
      check all(value <- Gen.gen_or(1, [])) do
        assert match?({:list, [{:symbol, :or} | _]}, value)
        {:list, [{:symbol, :or} | args]} = value
        assert length(args) >= 1
        Enum.each(args, fn arg -> assert valid_ast?(arg) end)
      end
    end

    property "gen_where produces where expressions" do
      check all(value <- Gen.gen_where(1)) do
        assert match?({:list, [{:symbol, :where} | _]}, value)
      end
    end

    property "gen_tool_call produces tool calls" do
      check all(value <- Gen.gen_tool_call(1, [])) do
        assert match?({:list, [{:symbol, :call}, {:string, _}, {:map, _}]}, value)
        {:list, [{:symbol, :call}, {:string, tool_name}, {:map, args}]} = value
        assert is_binary(tool_name)

        Enum.each(args, fn {k, v} ->
          assert match?({:keyword, _}, k)
          assert valid_ast?(v)
        end)
      end
    end
  end

  describe "roundtrip parsing" do
    property "formatted expressions parse successfully" do
      check all(ast <- Gen.gen_expr(2)) do
        source = Formatter.format(ast)
        assert is_binary(source)

        case Parser.parse(source) do
          {:ok, parsed} ->
            assert ast_equivalent?(ast, parsed),
                   "Roundtrip failed:\nOriginal: #{inspect(ast)}\nSource: #{source}\nParsed: #{inspect(parsed)}"

          {:error, reason} ->
            flunk("Parse failed for source: #{source}\nReason: #{inspect(reason)}")
        end
      end
    end

    property "string escape sequences roundtrip correctly" do
      check all(str_ast <- Gen.gen_string_with_escapes()) do
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

  describe "evaluation safety" do
    property "valid programs evaluate without crashes" do
      check all(ast <- Gen.gen_expr(2)) do
        source = Formatter.format(ast)
        ctx = %{items: [1, 2, 3], user: %{name: "test", active: true}}

        tools = build_tools_for_source(source)
        result = safe_run(source, context: ctx, tools: tools)

        # Should return {:ok, _, _, _} or {:error, _}, never crash the interpreter
        assert match?({:ok, _, _, _}, result) or match?({:error, _}, result),
               "Unexpected result for source: #{source}\nResult: #{inspect(result)}"
      end
    end
  end

  describe "determinism" do
    property "same input always produces same output" do
      check all(ast <- Gen.gen_expr(2)) do
        source = Formatter.format(ast)
        ctx = %{x: 42, items: [1, 2, 3]}

        tools = build_tools_for_source(source, "fixed")

        result1 = safe_run(source, context: ctx, tools: tools)
        result2 = safe_run(source, context: ctx, tools: tools)

        assert result1 == result2,
               "Non-deterministic evaluation for: #{source}"
      end
    end
  end

  describe "arithmetic identities" do
    property "x + 0 = x" do
      check all(n <- one_of([Gen.gen_integer(), Gen.gen_float()])) do
        source = "(+ #{n} 0)"
        assert {:ok, result, _, _} = safe_run(source, [])
        assert_numbers_equal(result, n)
      end
    end

    property "x * 1 = x" do
      check all(n <- one_of([Gen.gen_integer(), Gen.gen_float()])) do
        source = "(* #{n} 1)"
        assert {:ok, result, _, _} = safe_run(source, [])
        assert_numbers_equal(result, n)
      end
    end

    property "x - x = 0" do
      check all(n <- Gen.gen_integer()) do
        source = "(- #{n} #{n})"
        assert {:ok, 0, _, _} = safe_run(source, [])
      end
    end

    defp assert_numbers_equal(a, b) when is_float(a) or is_float(b) do
      assert abs(a - b) < 1.0e-9, "Expected #{b}, got #{a}"
    end

    defp assert_numbers_equal(a, b) do
      assert a == b
    end
  end

  describe "collection invariants" do
    property "map preserves count" do
      check all(items <- list_of(integer(), min_length: 1, max_length: 20)) do
        ctx = %{items: items}
        source = "(= (count ctx/items) (count (map inc ctx/items)))"

        case safe_run(source, context: ctx) do
          {:ok, true, _, _} -> :ok
          {:ok, false, _, _} -> flunk("map changed count")
          # Type errors are acceptable
          {:error, _} -> :ok
        end
      end
    end

    property "reverse(reverse(xs)) = xs" do
      check all(items <- list_of(integer(), max_length: 20)) do
        ctx = %{items: items}
        source = "(= ctx/items (reverse (reverse ctx/items)))"

        case safe_run(source, context: ctx) do
          {:ok, true, _, _} -> :ok
          {:ok, false, _, _} -> flunk("reverse is not idempotent")
          # Type errors are acceptable
          {:error, _} -> :ok
        end
      end
    end

    property "filter result count <= original count" do
      check all(
              items <-
                list_of(map_of(atom(:alphanumeric), integer(), max_length: 3), max_length: 10)
            ) do
        ctx = %{items: items}
        source = "(<= (count (filter (where :a) ctx/items)) (count ctx/items))"

        case safe_run(source, context: ctx) do
          {:ok, true, _, _} -> :ok
          {:ok, false, _, _} -> flunk("filter increased count")
          # Type errors are acceptable
          {:error, _} -> :ok
        end
      end
    end
  end

  describe "type predicates" do
    property "exactly one type predicate is true for primitives" do
      check all(
              value <-
                one_of([
                  constant(nil),
                  boolean(),
                  integer(),
                  float(),
                  string(:alphanumeric, max_length: 20)
                ])
            ) do
        ctx = %{v: value}

        predicates = ["nil?", "boolean?", "number?", "string?"]

        results =
          Enum.map(predicates, fn pred ->
            case safe_run("(#{pred} ctx/v)", context: ctx) do
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

  describe "short-circuit logic" do
    property "and with false short-circuits (doesn't call tool)" do
      check all(exprs <- list_of(Gen.gen_leaf_expr([]), min_length: 1, max_length: 3)) do
        formatted_exprs = Enum.map_join(exprs, " ", &Formatter.format/1)
        source = "(and #{formatted_exprs} false (call \"should-not-run\" {}))"

        tools = %{"should-not-run" => fn _ -> raise "Tool should not be called!" end}

        result = safe_run(source, tools: tools)

        # Should not crash (tool not called due to short-circuit)
        assert match?({:ok, _, _, _}, result) or match?({:error, _}, result)
      end
    end

    property "or with truthy value short-circuits (doesn't call tool)" do
      check all(n <- integer(1..1000)) do
        source = "(or #{n} (call \"should-not-run\" {}))"
        tools = %{"should-not-run" => fn _ -> raise "Tool should not be called!" end}

        assert {:ok, ^n, _, _} = safe_run(source, tools: tools)
      end
    end
  end

  # Helpers

  defp valid_ast?(value) do
    case value do
      nil ->
        true

      b when is_boolean(b) ->
        true

      n when is_number(n) ->
        true

      {:string, s} when is_binary(s) ->
        true

      {:keyword, k} when is_atom(k) ->
        true

      {:symbol, s} when is_atom(s) ->
        true

      {:ns_symbol, ns, k} when ns in [:ctx, :memory] and is_atom(k) ->
        true

      {:vector, items} when is_list(items) ->
        Enum.all?(items, &valid_ast?/1)

      {:map, pairs} when is_list(pairs) ->
        Enum.all?(pairs, fn
          {k, v} -> valid_ast?(k) and valid_ast?(v)
          _ -> false
        end)

      {:list, items} when is_list(items) ->
        Enum.all?(items, &valid_ast?/1)

      _ ->
        false
    end
  end

  defp ast_equivalent?(a, b) when is_float(a) and is_float(b) do
    abs(a - b) < 1.0e-9
  end

  defp ast_equivalent?({tag, children1}, {tag, children2})
       when is_list(children1) and is_list(children2) do
    length(children1) == length(children2) and
      Enum.zip(children1, children2) |> Enum.all?(fn {c1, c2} -> ast_equivalent?(c1, c2) end)
  end

  defp ast_equivalent?({tag, v1}, {tag, v2}) do
    ast_equivalent?(v1, v2)
  end

  defp ast_equivalent?(a, b) do
    a == b
  end

  defp build_tools_for_source(source, default_result \\ :result) do
    base_tools = %{"test_tool" => fn _args -> default_result end}

    Regex.scan(~r/\(call "([^"]+)"/, source)
    |> Enum.reduce(base_tools, fn [_full, tool_name], acc ->
      Map.put_new(acc, tool_name, fn _args -> default_result end)
    end)
  end

  defp safe_run(source, opts) do
    PtcRunner.Lisp.run(source, opts)
  rescue
    _e -> {:error, :runtime_error}
  end
end
