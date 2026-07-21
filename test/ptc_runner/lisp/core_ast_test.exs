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

  test "accepts migrated Java String nodes and references" do
    node = {:java_instance, :string_contains, {:var, :s}, [{:string, "x"}]}

    assert :ok = CoreAST.validate(node)
    assert :ok = CoreAST.validate({:java_ref, :string_contains})
  end
end
