defmodule PtcRunner.TestSupport.LispGeneratorsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcRunner.Lisp.{Formatter, Parser}
  alias PtcRunner.TestSupport.LispGenerators, as: Gen

  describe "primitive generators" do
    property "gen_integer produces integers" do
      check all(n <- Gen.gen_integer()) do
        assert is_integer(n)
        assert n >= -1_000_000 and n <= 1_000_000
      end
    end

    property "gen_float produces valid floats (no NaN)" do
      check all(f <- Gen.gen_float()) do
        assert is_float(f)
        # NaN check: f == f is false only for NaN
        assert f == f
      end
    end

    property "gen_string produces valid string AST" do
      check all(str <- Gen.gen_string()) do
        assert {:string, s} = str
        assert is_binary(s)
      end
    end

    property "gen_keyword produces valid keyword AST" do
      check all(kw <- Gen.gen_keyword()) do
        assert {:keyword, k} = kw
        assert is_atom(k)
      end
    end

    property "gen_identifier produces valid identifiers" do
      check all(id <- Gen.gen_identifier()) do
        assert is_binary(id)
        assert String.length(id) > 0
        # First character should be a-z
        assert String.first(id) in String.split("abcdefghijklmnopqrstuvwxyz", "")
      end
    end

    property "gen_nil produces nil" do
      check all(n <- Gen.gen_nil()) do
        assert n == nil
      end
    end

    property "gen_boolean produces booleans" do
      check all(b <- Gen.gen_boolean()) do
        assert is_boolean(b)
      end
    end
  end

  describe "symbol generators" do
    property "gen_builtin_symbol produces symbols" do
      check all(sym <- Gen.gen_builtin_symbol()) do
        assert {:symbol, s} = sym
        assert is_atom(s)
      end
    end

    property "gen_ctx_access produces ns_symbol with :ctx namespace" do
      check all(access <- Gen.gen_ctx_access()) do
        assert {:ns_symbol, :ctx, key} = access
        assert is_atom(key)
      end
    end

    property "gen_variable_from_scope with empty scope produces builtin" do
      check all(var <- Gen.gen_variable_from_scope([])) do
        assert {:symbol, _} = var
      end
    end

    property "gen_variable_from_scope with scope can produce scoped variables" do
      scope = [:x, :y, :z]

      check all(var <- Gen.gen_variable_from_scope(scope)) do
        assert {:symbol, v} = var
        assert is_atom(v)
      end
    end
  end

  describe "collection generators" do
    property "gen_vector with depth 0 produces empty vector" do
      check all(vec <- Gen.gen_vector(0, [])) do
        assert {:vector, []} = vec
      end
    end

    property "gen_vector with depth > 0 produces vector" do
      check all(vec <- Gen.gen_vector(1, [])) do
        assert {:vector, elems} = vec
        assert is_list(elems)
      end
    end

    property "gen_map with depth 0 produces empty map" do
      check all(map <- Gen.gen_map(0, [])) do
        assert {:map, []} = map
      end
    end

    property "gen_map with depth > 0 produces map with keyword keys" do
      check all(map <- Gen.gen_map(1, [])) do
        assert {:map, pairs} = map
        assert is_list(pairs)

        Enum.each(pairs, fn {k, _v} ->
          assert {:keyword, _} = k
        end)
      end
    end
  end

  describe "expression generator" do
    property "gen_expr with depth 0 produces leaf expressions" do
      check all(expr <- Gen.gen_expr(0)) do
        # Should be a leaf: literal, symbol, or ctx access
        refute match?({:list, _}, expr)
        refute match?({:vector, _}, expr)
        refute match?({:map, _}, expr)
      end
    end

    property "gen_expr produces formattable AST" do
      check all(expr <- Gen.gen_expr(2)) do
        source = Formatter.format(expr)
        assert is_binary(source)
        assert String.length(source) > 0
      end
    end

    property "gen_leaf_expr produces non-recursive expressions" do
      check all(expr <- Gen.gen_leaf_expr([])) do
        refute match?({:list, _}, expr)
        refute match?({:vector, [_ | _]}, expr)
        refute match?({:map, [_ | _]}, expr)
      end
    end
  end

  describe "special forms" do
    property "gen_if produces valid if structure" do
      check all(if_expr <- Gen.gen_if(1, [])) do
        assert {:list, [{:symbol, :if}, _cond, _then, _else]} = if_expr
      end
    end

    property "gen_let produces valid let structure" do
      check all(let_expr <- Gen.gen_let(1, [])) do
        assert {:list, [{:symbol, :let}, {:vector, _bindings}, _body]} = let_expr
      end
    end

    property "gen_fn produces valid fn structure" do
      check all(fn_expr <- Gen.gen_fn(1, [])) do
        assert {:list, [{:symbol, :fn}, {:vector, _params}, _body]} = fn_expr
      end
    end

    property "gen_arithmetic_call produces valid arithmetic structure" do
      check all(arith <- Gen.gen_arithmetic_call(1, [])) do
        assert {:list, [{:symbol, op} | args]} = arith
        assert op in [:+, :-, :*]
        assert is_list(args)
      end
    end

    property "gen_comparison produces valid comparison structure" do
      check all(cmp <- Gen.gen_comparison(1, [])) do
        assert {:list, [{:symbol, op}, _left, _right]} = cmp
        assert op in [:=, :"not=", :>, :<, :>=, :<=]
      end
    end

    property "gen_and produces valid and structure" do
      check all(and_expr <- Gen.gen_and(1, [])) do
        assert {:list, [{:symbol, :and} | args]} = and_expr
        assert is_list(args)
        assert length(args) >= 1
      end
    end

    property "gen_or produces valid or structure" do
      check all(or_expr <- Gen.gen_or(1, [])) do
        assert {:list, [{:symbol, :or} | args]} = or_expr
        assert is_list(args)
        assert length(args) >= 1
      end
    end

    property "gen_where produces valid where structure" do
      check all(where_expr <- Gen.gen_where(1)) do
        assert {:list, [{:symbol, :where} | _rest]} = where_expr
      end
    end

    property "gen_tool_call produces valid tool call structure" do
      check all(tool_call <- Gen.gen_tool_call(1, [])) do
        assert {:list, [{:symbol, :call}, {:string, _name}, {:map, _args}]} = tool_call
      end
    end
  end

  describe "roundtrip integration" do
    property "generated AST roundtrips through format -> parse" do
      check all(expr <- Gen.gen_expr(2)) do
        source = Formatter.format(expr)
        assert {:ok, _parsed} = Parser.parse(source)
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

  # Helper for AST equivalence with float precision tolerance
  defp ast_equivalent?(a, b) when is_float(a) and is_float(b) do
    abs(a - b) < 1.0e-9
  end

  defp ast_equivalent?({tag, children1}, {tag, children2}) when is_list(children1) do
    length(children1) == length(children2) and
      Enum.zip(children1, children2) |> Enum.all?(fn {c1, c2} -> ast_equivalent?(c1, c2) end)
  end

  defp ast_equivalent?({tag, v1}, {tag, v2}), do: ast_equivalent?(v1, v2)
  defp ast_equivalent?(a, b), do: a == b
end
