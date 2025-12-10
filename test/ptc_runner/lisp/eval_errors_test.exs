defmodule PtcRunner.Lisp.EvalErrorsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.{Env, Eval}

  describe "error propagation in nested structures" do
    test "error in vector propagates" do
      # Vector with unbound variable inside
      vector_ast = {:vector, [1, 2, {:var, :unbound}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(vector_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in map key propagates" do
      # Map with unbound variable as key
      map_ast = {:map, [{{:var, :unbound}, 1}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(map_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in map value propagates" do
      # Map with unbound variable as value
      map_ast = {:map, [{{:keyword, :key}, {:var, :unbound}}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(map_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in nested vector propagates" do
      # Nested vector with unbound variable in inner vector
      nested = {:vector, [{:vector, [1, {:var, :x}]}]}

      assert {:error, {:unbound_var, :x}} =
               Eval.eval(nested, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "error propagation in let bindings" do
    test "error in binding value expression propagates" do
      # Binding where the value expression contains unbound variable
      bindings = [{:binding, {:var, :x}, {:var, :undefined}}]
      body = {:var, :x}

      assert {:error, {:unbound_var, :undefined}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in subsequent binding value uses previous bindings" do
      # First binding succeeds, second uses first, then encounters error
      bindings = [
        {:binding, {:var, :x}, 10},
        {:binding, {:var, :y}, {:var, :missing}}
      ]

      body = {:var, :y}

      assert {:error, {:unbound_var, :missing}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in let body does not prevent binding evaluation" do
      # Binding succeeds but body references undefined variable
      bindings = [{:binding, {:var, :x}, 5}]
      body = {:var, :not_bound}

      assert {:error, {:unbound_var, :not_bound}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "error propagation in function calls" do
    test "error in function position propagates" do
      # Unbound variable in function position
      call_ast = {:call, {:var, :unknown_func}, [1]}

      assert {:error, {:unbound_var, :unknown_func}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in function arguments propagates" do
      # Unbound variable in argument position
      env = Env.initial()
      call_ast = {:call, {:var, :+}, [1, {:var, :undefined}]}

      assert {:error, {:unbound_var, :undefined}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "error in first of multiple arguments propagates" do
      env = Env.initial()
      call_ast = {:call, {:var, :+}, [{:var, :x}, 2, 3]}

      assert {:error, {:unbound_var, :x}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "error propagation in closures" do
    test "closure with arity mismatch returns error" do
      # Create closure expecting 2 params via let, then call with wrong arity
      closure_def = {:fn, [{:var, :x}, {:var, :y}], {:call, {:var, :+}, [{:var, :x}, {:var, :y}]}}
      bindings = [{:binding, {:var, :add_two}, closure_def}]
      body = {:call, {:var, :add_two}, [5]}

      env = Env.initial()

      assert {:error, {:arity_mismatch, 2, 1}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end

    test "closure with arity mismatch (too many args)" do
      # Create closure expecting 1 param via let, then call with wrong arity
      closure_def = {:fn, [{:var, :x}], {:var, :x}}
      bindings = [{:binding, {:var, :identity}, closure_def}]
      call_ast = {:call, {:var, :identity}, [5, 10, 15]}
      body = call_ast

      env = Env.initial()

      assert {:error, {:arity_mismatch, 1, 3}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end

    test "error in closure body propagates" do
      # Closure that references undefined variable in body
      closure_def =
        {:fn, [{:var, :x}], {:call, {:var, :+}, [{:var, :x}, {:var, :undefined_in_closure}]}}

      bindings = [{:binding, {:var, :bad_fn}, closure_def}]
      call_ast = {:call, {:var, :bad_fn}, [5]}
      body = call_ast

      env = Env.initial()

      assert {:error, {:unbound_var, :undefined_in_closure}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "error propagation in keyword function calls" do
    test "invalid keyword call with too many args" do
      map = %{name: "Alice"}
      # Keyword called with too many arguments
      call_ast = {:call, {:keyword, :name}, [{:var, :m}, {:string, "default"}, 42]}

      assert {:error, {:invalid_keyword_call, :name, _}} =
               Eval.eval(call_ast, %{}, %{}, %{m: map}, &dummy_tool/2)
    end

    test "invalid keyword call with no args" do
      # Keyword called with no arguments
      call_ast = {:call, {:keyword, :key}, []}

      assert {:error, {:invalid_keyword_call, :key, []}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "invalid keyword call with non-map arg" do
      # Keyword called with non-map, non-nil argument
      call_ast = {:call, {:keyword, :key}, [42]}

      assert {:error, {:invalid_keyword_call, :key, [42]}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  defp dummy_tool(_name, _args), do: :ok
end
