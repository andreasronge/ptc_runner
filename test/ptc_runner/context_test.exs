defmodule PtcRunner.ContextTest do
  use ExUnit.Case, async: true

  describe "Context.new/0" do
    test "creates context with default empty fields" do
      context = PtcRunner.Context.new()

      assert is_struct(context, PtcRunner.Context)
      assert context.ctx == %{}
      assert context.memory == %{}
      assert context.tools == %{}
    end
  end

  describe "Context.new/3" do
    test "creates context with provided ctx and memory" do
      ctx = %{"x" => 10, "y" => 20}
      memory = %{"counter" => 0}
      context = PtcRunner.Context.new(ctx, memory)

      assert context.ctx == ctx
      assert context.memory == memory
      assert context.tools == %{}
    end

    test "creates context with all three arguments" do
      ctx = %{"x" => 10}
      memory = %{"counter" => 0}
      tools = %{"fn1" => &:erlang.self/0}
      context = PtcRunner.Context.new(ctx, memory, tools)

      assert context.ctx == ctx
      assert context.memory == memory
      assert context.tools == tools
    end

    test "creates context with empty maps" do
      context = PtcRunner.Context.new(%{}, %{})

      assert context.ctx == %{}
      assert context.memory == %{}
    end

    test "creates context with complex variable values" do
      ctx = %{
        "list" => [1, 2, 3],
        "map" => %{"key" => "value"},
        "nested" => [%{"a" => 1}, %{"b" => 2}]
      }

      context = PtcRunner.Context.new(ctx)

      assert context.ctx == ctx
    end
  end

  describe "Context.get_ctx/2" do
    test "retrieves existing context variable" do
      context = PtcRunner.Context.new(%{"x" => 42})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "x")

      assert value == 42
    end

    test "returns nil for non-existent context variable" do
      context = PtcRunner.Context.new()
      {:ok, value} = PtcRunner.Context.get_ctx(context, "missing")

      assert value == nil
    end

    test "retrieves variable with special characters in name" do
      context = PtcRunner.Context.new(%{"var_name" => "value1"})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "var_name")

      assert value == "value1"
    end

    test "retrieves variable with spaces in name" do
      context = PtcRunner.Context.new(%{"var name" => "value2"})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "var name")

      assert value == "value2"
    end

    test "retrieves variable with numbers in name" do
      context = PtcRunner.Context.new(%{"var123" => "value3"})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "var123")

      assert value == "value3"
    end

    test "retrieves list variable" do
      context = PtcRunner.Context.new(%{"data" => [1, 2, 3]})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "data")

      assert value == [1, 2, 3]
    end

    test "retrieves map variable" do
      context = PtcRunner.Context.new(%{"config" => %{"timeout" => 5000}})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "config")

      assert value == %{"timeout" => 5000}
    end

    test "retrieves nil value stored as variable" do
      context = PtcRunner.Context.new(%{"null_var" => nil})
      {:ok, value} = PtcRunner.Context.get_ctx(context, "null_var")

      assert value == nil
    end

    test "returns error for non-string context key (integer)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_ctx(context, 42)

      assert message =~ "Context key must be a string"
    end

    test "returns error for non-string context key (atom)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_ctx(context, :symbol)

      assert message =~ "Context key must be a string"
    end
  end

  describe "Context.get_memory/2" do
    test "retrieves existing memory variable" do
      context = PtcRunner.Context.new(%{}, %{"counter" => 42})
      {:ok, value} = PtcRunner.Context.get_memory(context, "counter")

      assert value == 42
    end

    test "returns nil for non-existent memory variable" do
      context = PtcRunner.Context.new()
      {:ok, value} = PtcRunner.Context.get_memory(context, "missing")

      assert value == nil
    end

    test "retrieves memory with special characters in name" do
      context = PtcRunner.Context.new(%{}, %{"var_name" => "value1"})
      {:ok, value} = PtcRunner.Context.get_memory(context, "var_name")

      assert value == "value1"
    end

    test "retrieves list from memory" do
      context = PtcRunner.Context.new(%{}, %{"data" => [1, 2, 3]})
      {:ok, value} = PtcRunner.Context.get_memory(context, "data")

      assert value == [1, 2, 3]
    end

    test "returns error for non-string memory key (integer)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_memory(context, 42)

      assert message =~ "Memory key must be a string"
    end
  end

  describe "Context.put_memory/3" do
    test "sets new variable in empty memory" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_memory(context, "counter", 1)

      assert updated.memory == %{"counter" => 1}
    end

    test "updates existing memory variable" do
      context = PtcRunner.Context.new(%{}, %{"counter" => 0})
      updated = PtcRunner.Context.put_memory(context, "counter", 1)

      assert updated.memory == %{"counter" => 1}
    end

    test "adds new memory variable without modifying existing ones" do
      context = PtcRunner.Context.new(%{}, %{"x" => 10})
      updated = PtcRunner.Context.put_memory(context, "y", 20)

      assert updated.memory == %{"x" => 10, "y" => 20}
    end

    test "stores list value in memory" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_memory(context, "data", [1, 2, 3])

      assert updated.memory == %{"data" => [1, 2, 3]}
    end

    test "stores map value in memory" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_memory(context, "config", %{"key" => "value"})

      assert updated.memory == %{"config" => %{"key" => "value"}}
    end

    test "stores nil value in memory" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_memory(context, "null_var", nil)

      assert updated.memory == %{"null_var" => nil}
    end

    test "preserves tools when putting memory variable" do
      tools = %{"fn1" => &:erlang.self/0}
      context = PtcRunner.Context.new(%{}, %{}, tools)
      updated = PtcRunner.Context.put_memory(context, "x", 42)

      assert updated.tools == tools
    end

    test "preserves ctx when putting memory variable" do
      ctx = %{"external" => 100}
      context = PtcRunner.Context.new(ctx, %{})
      updated = PtcRunner.Context.put_memory(context, "x", 42)

      assert updated.ctx == ctx
    end
  end

  describe "Context - integration tests" do
    test "get and put memory roundtrip" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_memory(context, "counter", 100)
      {:ok, value} = PtcRunner.Context.get_memory(updated, "counter")

      assert value == 100
    end

    test "get ctx and put memory" do
      context = PtcRunner.Context.new(%{"data" => [1, 2, 3]}, %{})
      {:ok, ctx_value} = PtcRunner.Context.get_ctx(context, "data")
      updated = PtcRunner.Context.put_memory(context, "counter", 0)
      {:ok, mem_value} = PtcRunner.Context.get_memory(updated, "counter")

      assert ctx_value == [1, 2, 3]
      assert mem_value == 0
    end

    test "multiple memory operations" do
      context = PtcRunner.Context.new()
      c1 = PtcRunner.Context.put_memory(context, "x", 10)
      c2 = PtcRunner.Context.put_memory(c1, "y", 20)
      c3 = PtcRunner.Context.put_memory(c2, "z", 30)

      {:ok, x} = PtcRunner.Context.get_memory(c3, "x")
      {:ok, y} = PtcRunner.Context.get_memory(c3, "y")
      {:ok, z} = PtcRunner.Context.get_memory(c3, "z")

      assert x == 10
      assert y == 20
      assert z == 30
    end

    test "original context unmodified after put_memory" do
      original = PtcRunner.Context.new(%{}, %{"x" => 10})
      updated = PtcRunner.Context.put_memory(original, "y", 20)

      assert original.memory == %{"x" => 10}
      assert updated.memory == %{"x" => 10, "y" => 20}
    end
  end
end
