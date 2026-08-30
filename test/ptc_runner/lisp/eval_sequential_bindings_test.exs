defmodule PtcRunner.Lisp.EvalSequentialBindingsTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.{Env, Eval}

  @forms [:let, :loop]

  for form <- @forms do
    describe "#{form} initial bindings" do
      @tag form: form
      test "later bindings see earlier bindings", %{form: form} do
        bindings = [
          {:binding, {:var, :x}, 5},
          {:binding, {:var, :y}, {:call, {:var, :+}, [{:var, :x}, 3]}}
        ]

        assert {:ok, 8, _ctx} = eval(form, bindings, {:var, :y})
      end

      @tag form: form
      test "destructuring matches the evaluated binding value", %{form: form} do
        pattern = {:destructure, {:seq, [{:var, :first}, {:var, :second}]}}
        value_ast = {:call, {:var, :vector}, [1, 2]}
        body = {:vector, [{:var, :first}, {:var, :second}]}

        assert {:ok, [1, 2], _ctx} = eval(form, [{:binding, pattern, value_ast}], body)
      end

      @tag form: form
      test "binding expressions retain their effects", %{form: form} do
        value_ast = {:do, [{:call, {:var, :println}, [{:string, "binding effect"}]}, 42]}

        assert {:ok, 42, ctx} =
                 eval(form, [{:binding, {:var, :value}, value_ast}], {:var, :value})

        assert ctx.effects.prints == ["binding effect"]
      end

      @tag form: form
      test "destructuring failure retains the failing expression context", %{form: form} do
        pattern = {:destructure, {:keys, [:value], []}}
        value_ast = {:do, [{:call, {:var, :println}, [{:string, "before failure"}]}, 42]}

        assert {:error, {:destructure_error, _message}, ctx} =
                 eval(form, [{:binding, pattern, value_ast}], {:var, :value})

        assert ctx.effects.prints == ["before failure"]
      end
    end
  end

  defp eval(form, bindings, body) do
    Eval.eval_with_context({form, bindings, body}, %{}, %{}, Env.initial(), &dummy_tool/2)
  end
end
