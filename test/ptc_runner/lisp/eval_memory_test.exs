defmodule PtcRunner.Lisp.EvalMemoryTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.Eval

  describe "memory threading" do
    test "memory is threaded through literals" do
      memory = %{count: 5}
      {:ok, value, new_memory} = Eval.eval(42, %{}, memory, %{}, &dummy_tool/2)

      assert value == 42
      assert new_memory == memory
    end

    test "memory is threaded through vector evaluation" do
      memory = %{count: 5}

      {:ok, [1, 2, 3], new_memory} =
        Eval.eval({:vector, [1, 2, 3]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end

    test "memory is threaded through map evaluation" do
      memory = %{count: 5}

      {:ok, %{a: 1}, new_memory} =
        Eval.eval({:map, [{{:keyword, :a}, 1}]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end
  end

  describe "memory/put" do
    test "stores a value in memory" do
      ast = {:memory_put, :count, 42}
      {:ok, value, new_memory} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      assert value == 42
      assert new_memory == %{count: 42}
    end

    test "overwrites existing key" do
      ast = {:memory_put, :count, 100}
      {:ok, value, new_memory} = Eval.eval(ast, %{}, %{count: 5}, %{}, &dummy_tool/2)

      assert value == 100
      assert new_memory == %{count: 100}
    end

    test "evaluates value expression before storing" do
      # (memory/put :result (+ 5 3))
      ast = {:memory_put, :result, {:call, {:var, :+}, [5, 3]}}
      env = %{+: {:variadic, &+/2, 0}}
      {:ok, value, new_memory} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)

      assert value == 8
      assert new_memory == %{result: 8}
    end

    test "returns the stored value" do
      ast = {:memory_put, :data, {:string, "hello"}}
      {:ok, value, _memory} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      assert value == "hello"
    end
  end

  describe "memory/get" do
    test "retrieves an existing value" do
      ast = {:memory_get, :count}
      {:ok, value, new_memory} = Eval.eval(ast, %{}, %{count: 42}, %{}, &dummy_tool/2)

      assert value == 42
      assert new_memory == %{count: 42}
    end

    test "returns nil for missing key" do
      ast = {:memory_get, :missing}
      {:ok, value, new_memory} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      assert value == nil
      assert new_memory == %{}
    end

    test "does not modify memory" do
      initial_memory = %{count: 5, name: "test"}
      ast = {:memory_get, :count}
      {:ok, _value, new_memory} = Eval.eval(ast, %{}, initial_memory, %{}, &dummy_tool/2)

      assert new_memory == initial_memory
    end
  end

  describe "memory/get and memory/put integration" do
    test "put then get returns the stored value" do
      # First put
      put_ast = {:memory_put, :value, 123}
      {:ok, _, memory1} = Eval.eval(put_ast, %{}, %{}, %{}, &dummy_tool/2)

      # Then get
      get_ast = {:memory_get, :value}
      {:ok, value, _memory2} = Eval.eval(get_ast, %{}, memory1, %{}, &dummy_tool/2)

      assert value == 123
    end

    test "multiple puts update memory correctly" do
      # Put key1
      put1 = {:memory_put, :key1, {:string, "first"}}
      {:ok, _, memory1} = Eval.eval(put1, %{}, %{}, %{}, &dummy_tool/2)

      # Put key2
      put2 = {:memory_put, :key2, {:string, "second"}}
      {:ok, _, memory2} = Eval.eval(put2, %{}, memory1, %{}, &dummy_tool/2)

      # Both keys should exist
      assert memory2 == %{key1: "first", key2: "second"}
    end
  end

  describe "ctx/tool invocation (ctx_call)" do
    test "ctx_call with no args invokes tool with empty map" do
      tool = fn name, args ->
        assert name == "get-users"
        assert args == %{}
        [%{id: 1}]
      end

      ast = {:ctx_call, :"get-users", []}
      {:ok, result, _memory} = Eval.eval(ast, %{}, %{}, %{}, tool)

      assert result == [%{id: 1}]
    end

    test "ctx_call with single map arg passes map directly" do
      tool = fn name, args ->
        assert name == "search"
        assert args == %{query: "test"}
        [%{id: 1, name: "result"}]
      end

      ast = {:ctx_call, :search, [{:map, [{{:keyword, :query}, {:string, "test"}}]}]}
      {:ok, result, _memory} = Eval.eval(ast, %{}, %{}, %{}, tool)

      assert result == [%{id: 1, name: "result"}]
    end

    test "ctx_call with single non-map arg wraps in args key" do
      tool = fn name, args ->
        assert name == "fetch-user"
        assert args == %{args: [123]}
        %{id: 123, name: "Alice"}
      end

      ast = {:ctx_call, :"fetch-user", [123]}
      {:ok, result, _memory} = Eval.eval(ast, %{}, %{}, %{}, tool)

      assert result == %{id: 123, name: "Alice"}
    end

    test "ctx_call with multiple args wraps in args key" do
      tool = fn name, args ->
        assert name == "fetch-user"
        assert args == %{args: [123, :include_details]}
        %{id: 123}
      end

      ast = {:ctx_call, :"fetch-user", [123, {:keyword, :include_details}]}
      {:ok, result, _memory} = Eval.eval(ast, %{}, %{}, %{}, tool)

      assert result == %{id: 123}
    end

    test "ctx_call evaluates arg expressions before calling tool" do
      tool = fn name, args ->
        assert name == "process"
        assert args == %{value: 8}
        {:processed, 8}
      end

      env = %{+: {:variadic, &+/2, 0}}
      # (ctx/process {:value (+ 5 3)})
      ast = {:ctx_call, :process, [{:map, [{{:keyword, :value}, {:call, {:var, :+}, [5, 3]}}]}]}
      {:ok, result, _memory} = Eval.eval(ast, %{}, %{}, env, tool)

      assert result == {:processed, 8}
    end

    test "ctx_call threads memory correctly" do
      tool = fn _name, _args -> :ok end

      memory = %{existing: "value"}
      ast = {:ctx_call, :noop, []}
      {:ok, _result, new_memory} = Eval.eval(ast, %{}, memory, %{}, tool)

      assert new_memory == memory
    end
  end
end
