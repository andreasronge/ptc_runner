defmodule PtcRunner.Lisp.EvalErrorsTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

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

  describe "destructuring errors in let bindings" do
    test "map pattern with list value returns error" do
      # Destructure {:keys [:a]} with list value [1, 2, 3]
      pattern = {:destructure, {:keys, [:a], []}}
      bindings = [{:binding, pattern, {:vector, [1, 2, 3]}}]
      body = {:var, :a}

      assert {:error, {:destructure_error, msg}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)

      assert msg =~ "expected map"
    end

    test "seq pattern with map value returns error" do
      # Destructure [a b] with map value
      pattern = {:destructure, {:seq, [{:var, :a}, {:var, :b}]}}
      bindings = [{:binding, pattern, {:map, [{{:keyword, :x}, 1}]}}]
      body = {:var, :a}

      assert {:error, {:destructure_error, msg}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)

      assert msg =~ "expected list"
    end

    test "seq pattern with fewer elements binds nil for missing (Clojure behavior)" do
      # Destructure [a b c] with only 2-element list - c binds to nil
      pattern = {:destructure, {:seq, [{:var, :a}, {:var, :b}, {:var, :c}]}}
      bindings = [{:binding, pattern, {:vector, [1, 2]}}]
      body = {:vector, [{:var, :a}, {:var, :b}, {:var, :c}]}

      assert {:ok, [1, 2, nil], %{}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "nested destructuring with insufficient elements binds nil (Clojure behavior)" do
      # Destructure [[a b]] where inner list has only 1 element - b binds to nil
      inner_pattern = {:destructure, {:seq, [{:var, :a}, {:var, :b}]}}
      pattern = {:destructure, {:seq, [inner_pattern]}}
      # [[1]] - inner has only 1 element, b binds to nil
      bindings = [{:binding, pattern, {:vector, [{:vector, [1]}]}}]
      body = {:vector, [{:var, :a}, {:var, :b}]}

      assert {:ok, [1, nil], %{}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test ":as binding with failing inner pattern returns error" do
      # Pattern: {:as :all {:keys [:x]}} with a list value [1, 2, 3]
      # The :as binding should work, but the inner {:keys [:x]} should fail on a list
      pattern = {:destructure, {:as, :all, {:destructure, {:keys, [:x], []}}}}
      bindings = [{:binding, pattern, {:vector, [1, 2, 3]}}]
      body = {:var, :all}

      assert {:error, {:destructure_error, msg}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)

      assert msg =~ "expected map"
    end
  end

  describe "destructuring errors in closure application" do
    setup do
      {:ok, %{env: Env.initial()}}
    end

    test "closure with seq pattern on map returns error", %{env: env} do
      # (fn [[k v]] k) applied to a map (which iterates as [key, value] pairs)
      # This simulates: (map (fn [amount] amount) [{:amount 100} {:amount 200}])
      # where the closure expects a simple value but gets a map

      # Closure with destructuring pattern [a]
      closure_def = {:fn, [{:destructure, {:seq, [{:var, :a}]}}], {:var, :a}}
      bindings = [{:binding, {:var, :get_first}, closure_def}]
      # Apply to a map - should fail because maps aren't lists
      call_ast = {:call, {:var, :get_first}, [{:map, [{{:keyword, :x}, 1}]}]}
      body = call_ast

      assert {:error, {:destructure_error, msg}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "expected list"
    end

    test "closure with map pattern on list returns error", %{env: env} do
      # Closure expecting map destructuring {:keys [:amount]}
      closure_def = {:fn, [{:destructure, {:keys, [:amount], []}}], {:var, :amount}}
      bindings = [{:binding, {:var, :get_amount}, closure_def}]
      # Apply to a list - should fail
      call_ast = {:call, {:var, :get_amount}, [{:vector, [1, 2, 3]}]}
      body = call_ast

      assert {:error, {:destructure_error, msg}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "expected map"
    end
  end

  describe "arithmetic errors in variadic functions" do
    test "division with nil operand returns type_error" do
      # (/ 10 nil) should return type error, not :badarith
      env = Env.initial()
      call_ast = {:call, {:var, :/}, [10, nil]}

      assert {:error, {:type_error, msg, [10, nil]}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "nil"
    end

    test "addition with nil operand returns type_error" do
      # (+ 1 nil) should return type error, not :badarith
      env = Env.initial()
      call_ast = {:call, {:var, :+}, [1, nil]}

      assert {:error, {:type_error, msg, [1, nil]}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "nil"
    end

    test "unary minus with nil returns type_error" do
      # (- nil) should return type error, not :badarith
      env = Env.initial()
      call_ast = {:call, {:var, :-}, [nil]}

      assert {:error, {:type_error, msg, nil}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "expected number"
      assert msg =~ "nil"
    end

    test "multiplication with nil operand returns type_error" do
      # (* 5 nil) should return type error, not :badarith
      env = Env.initial()
      call_ast = {:call, {:var, :*}, [5, nil]}

      assert {:error, {:type_error, msg, [5, nil]}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "nil"
    end
  end

  describe "destructuring errors in higher-order functions" do
    setup do
      {:ok, %{env: Env.initial()}}
    end

    test "map with closure that fails destructuring returns type_error", %{env: env} do
      # (map (fn [[a b]] a) [1 2 3])
      # Each element is a number, not a list, so [a b] destructuring fails
      closure_def = {:fn, [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}], {:var, :a}}

      call_ast =
        {:call, {:var, :map}, [closure_def, {:vector, [1, 2, 3]}]}

      assert {:error, {:type_error, msg, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "destructure error"
      assert msg =~ "expected list"
    end

    test "filter with closure that fails destructuring returns type_error", %{env: env} do
      # (filter (fn [{:keys [active]}] active) [1 2 3])
      # Elements are numbers, not maps, so {:keys [active]} fails
      closure_def = {:fn, [{:destructure, {:keys, [:active], []}}], {:var, :active}}

      call_ast =
        {:call, {:var, :filter}, [closure_def, {:vector, [1, 2, 3]}]}

      assert {:error, {:type_error, msg, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "destructure error"
      assert msg =~ "expected map"
    end

    test "sort-by with closure that fails destructuring returns type_error", %{env: env} do
      # (sort-by (fn [{:keys [name]}] name) [1 2 3])
      # Elements are numbers, not maps, so {:keys [name]} fails
      closure_def = {:fn, [{:destructure, {:keys, [:name], []}}], {:var, :name}}

      call_ast =
        {:call, {:var, :"sort-by"}, [closure_def, {:vector, [1, 2, 3]}]}

      assert {:error, {:type_error, msg, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      assert msg =~ "destructure error"
      assert msg =~ "expected map"
    end
  end

  describe "format_closure_error hints" do
    alias PtcRunner.Lisp.Eval.Helpers

    test "provides hint for special forms used without parentheses" do
      # When user writes `return` instead of `(return ...)`
      msg = Helpers.format_closure_error({:unbound_var, :return})

      assert msg =~ "Hint:"
      assert msg =~ "special form"
      assert msg =~ "(return ...)"
    end

    test "provides hint for if special form without parentheses" do
      msg = Helpers.format_closure_error({:unbound_var, :if})

      assert msg =~ "Hint:"
      assert msg =~ "special form"
      assert msg =~ "(if ...)"
    end

    test "provides hint for let special form without parentheses" do
      msg = Helpers.format_closure_error({:unbound_var, :let})

      assert msg =~ "Hint:"
      assert msg =~ "special form"
      assert msg =~ "(let ...)"
    end

    test "provides hint for fail special form without parentheses" do
      msg = Helpers.format_closure_error({:unbound_var, :fail})

      assert msg =~ "Hint:"
      assert msg =~ "special form"
      assert msg =~ "(fail ...)"
    end

    test "no special form hint for regular undefined variables" do
      msg = Helpers.format_closure_error({:unbound_var, :my_var})

      refute msg =~ "special form"
    end
  end

  describe "tool call argument errors" do
    test "positional arguments to tool returns invalid_tool_args error" do
      # (tool/query "corpus string") - positional arg instead of {:corpus "..."}
      tool_call_ast = {:tool_call, :query, [{:string, "some corpus"}]}

      tool_exec = fn _name, _args -> {:ok, %{}} end

      assert {:error, {:invalid_tool_args, msg}} =
               Eval.eval(tool_call_ast, %{}, %{}, %{}, tool_exec)

      assert msg =~ "Tool calls require named arguments"
      assert msg =~ "tool/name {:key value}"
    end

    test "multiple positional arguments to tool returns invalid_tool_args error" do
      # (tool/search "query" 10) - two positional args
      tool_call_ast = {:tool_call, :search, [{:string, "query"}, 10]}

      tool_exec = fn _name, _args -> {:ok, %{}} end

      assert {:error, {:invalid_tool_args, msg}} =
               Eval.eval(tool_call_ast, %{}, %{}, %{}, tool_exec)

      assert msg =~ "Tool calls require named arguments"
    end

    test "map argument to tool succeeds" do
      # (tool/query {:corpus "..."}) - correct format
      tool_call_ast =
        {:tool_call, :query, [{:map, [{{:keyword, :corpus}, {:string, "test"}}]}]}

      tool_exec = fn _name, args ->
        assert args == %{"corpus" => "test"}
        {:ok, %{"result" => "found"}}
      end

      # Tool returns {:ok, value}, which becomes the eval result
      assert {:ok, {:ok, %{"result" => "found"}}, _} =
               Eval.eval(tool_call_ast, %{}, %{}, %{}, tool_exec)
    end

    test "keyword-style arguments to tool succeeds" do
      # (tool/query :corpus "..." :limit 10) - keyword style
      tool_call_ast =
        {:tool_call, :query, [{:keyword, :corpus}, {:string, "test"}, {:keyword, :limit}, 10]}

      tool_exec = fn _name, args ->
        assert args == %{"corpus" => "test", "limit" => 10}
        {:ok, %{"result" => "found"}}
      end

      # Tool returns {:ok, value}, which becomes the eval result
      assert {:ok, {:ok, %{"result" => "found"}}, _} =
               Eval.eval(tool_call_ast, %{}, %{}, %{}, tool_exec)
    end
  end
end
