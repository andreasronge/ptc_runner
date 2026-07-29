defmodule PtcRunner.Lisp.CoreASTTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.CoreAST

  test "validates every Java node recursively" do
    ast =
      {:do,
       [
         {:java_static, :boolean_parse_boolean, [{:string, "true"}]},
         {:java_static, :double_parse_double, [{:string, "1.0"}]},
         {:java_field, :double_nan},
         {:java_new, :date_new, [0]},
         {:java_dot, :is_before, {:var, :value}, [{:var, :other}]},
         {:java_ref, :boolean_parse_boolean},
         {:java_ref, :double_parse_double}
       ]}

    assert :ok = CoreAST.validate(ast)
  end

  test "rejects malformed Java nodes with a bounded path" do
    assert {:error, {:invalid_core_ast, [0, 0], {:java_ref, "open-name"}}} =
             CoreAST.validate(
               {:vector,
                [
                  {:java_static, :boolean_parse_boolean,
                   [
                     {:java_ref, "open-name"}
                   ]}
                ]}
             )

    assert {:error, {:invalid_core_ast, [], {:java_static, :boolean_parse_boolean, :not_a_list}}} =
             CoreAST.validate({:java_static, :boolean_parse_boolean, :not_a_list})

    assert {:error, {:invalid_core_ast, [], {:java_ref, :unknown_reference}}} =
             CoreAST.validate({:java_ref, :unknown_reference})
  end

  test "accepts admitted Java String nodes and references" do
    node = {:java_instance, :string_contains, {:var, :s}, [{:string, "x"}]}

    assert :ok = CoreAST.validate(node)
    assert :ok = CoreAST.validate({:java_ref, :string_contains})
  end

  test "rejects malformed quoted-symbol nodes" do
    for name <- ["", "server/tool x", <<255>>] do
      assert {:error, {:invalid_core_ast, [], {:symbol_ref, ^name}}} =
               CoreAST.validate({:symbol_ref, name})
    end
  end

  test "requires prelude references to be exact namespaced symbols" do
    for node <- [
          {:prelude_ref, "nil"},
          {:prelude_ref, "crm"},
          {:prelude_ref, "crm/get/user"},
          {:prelude_ref, "-1/x"},
          {:prelude_call, "true", []}
        ] do
      assert {:error, {:invalid_core_ast, [], ^node}} = CoreAST.validate(node)
    end

    assert :ok = CoreAST.validate({:prelude_ref, "crm/get-user"})
    assert :ok = CoreAST.validate({:prelude_call, "crm/get-user", [1]})
  end

  test "accepts only exact tool runtime-callable nodes" do
    assert :ok = CoreAST.validate({:runtime_callable, :tool, "echo"})
    assert :ok = CoreAST.validate({:runtime_callable, :tool, "server/echo"})

    for node <- [
          {:runtime_callable, :data, "echo"},
          {:runtime_callable, "tool", "echo"},
          {:runtime_callable, :tool, "echo value"}
        ] do
      assert {:error, {:invalid_core_ast, [], ^node}} = CoreAST.validate(node)
    end
  end

  test "requires data and tool nodes to have exact nonempty qualified names" do
    assert :ok = CoreAST.validate({:data, "input"})
    assert :ok = CoreAST.validate({:tool_call, "server/echo", []})

    for node <- [{:data, ""}, {:tool_call, "", []}] do
      assert {:error, {:invalid_core_ast, [], ^node}} = CoreAST.validate(node)
    end
  end

  test "rejects improper lists instead of raising" do
    malformed = [1 | 2]

    assert {:error, {:invalid_core_ast, [], ^malformed}} =
             CoreAST.validate({:vector, malformed})

    assert {:error, {:invalid_core_ast, [0], ^malformed}} =
             CoreAST.validate({:fn, malformed, 1})

    assert {:error, {:invalid_core_ast, [0], ^malformed}} =
             CoreAST.validate({:let, malformed, 1})

    map = {:map, [{1, 2} | 3]}
    assert {:error, {:invalid_core_ast, [], ^map}} = CoreAST.validate(map)
  end

  test "rejects improper lists nested inside destructuring patterns" do
    malformed = [{:var, :head} | {:var, :tail}]
    pattern = {:destructure, {:seq, malformed}}

    assert {:error, {:invalid_core_ast, _path, ^malformed}} =
             CoreAST.validate({:fn, [pattern], {:var, :head}})
  end
end
