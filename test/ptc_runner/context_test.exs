defmodule PtcRunner.ContextTest do
  use ExUnit.Case, async: true

  describe "Context.new/0" do
    test "creates context with default empty variables and tools" do
      context = PtcRunner.Context.new()

      assert is_struct(context, PtcRunner.Context)
      assert context.variables == %{}
      assert context.tools == %{}
    end
  end

  describe "Context.new/2" do
    test "creates context with provided variables" do
      variables = %{"x" => 10, "y" => 20}
      context = PtcRunner.Context.new(variables)

      assert context.variables == variables
      assert context.tools == %{}
    end

    test "creates context with provided variables and tools" do
      variables = %{"x" => 10}
      tools = %{"fn1" => &:erlang.self/0}
      context = PtcRunner.Context.new(variables, tools)

      assert context.variables == variables
      assert context.tools == tools
    end

    test "creates context with empty variables map" do
      context = PtcRunner.Context.new(%{})

      assert context.variables == %{}
    end

    test "creates context with complex variable values" do
      variables = %{
        "list" => [1, 2, 3],
        "map" => %{"key" => "value"},
        "nested" => [%{"a" => 1}, %{"b" => 2}]
      }

      context = PtcRunner.Context.new(variables)

      assert context.variables == variables
    end
  end

  describe "Context.get_var/2" do
    test "retrieves existing variable" do
      context = PtcRunner.Context.new(%{"x" => 42})
      {:ok, value} = PtcRunner.Context.get_var(context, "x")

      assert value == 42
    end

    test "returns nil for non-existent variable" do
      context = PtcRunner.Context.new()
      {:ok, value} = PtcRunner.Context.get_var(context, "missing")

      assert value == nil
    end

    test "retrieves variable with special characters in name" do
      context = PtcRunner.Context.new(%{"var_name" => "value1"})
      {:ok, value} = PtcRunner.Context.get_var(context, "var_name")

      assert value == "value1"
    end

    test "retrieves variable with spaces in name" do
      context = PtcRunner.Context.new(%{"var name" => "value2"})
      {:ok, value} = PtcRunner.Context.get_var(context, "var name")

      assert value == "value2"
    end

    test "retrieves variable with numbers in name" do
      context = PtcRunner.Context.new(%{"var123" => "value3"})
      {:ok, value} = PtcRunner.Context.get_var(context, "var123")

      assert value == "value3"
    end

    test "retrieves list variable" do
      context = PtcRunner.Context.new(%{"data" => [1, 2, 3]})
      {:ok, value} = PtcRunner.Context.get_var(context, "data")

      assert value == [1, 2, 3]
    end

    test "retrieves map variable" do
      context = PtcRunner.Context.new(%{"config" => %{"timeout" => 5000}})
      {:ok, value} = PtcRunner.Context.get_var(context, "config")

      assert value == %{"timeout" => 5000}
    end

    test "retrieves nil value stored as variable" do
      context = PtcRunner.Context.new(%{"null_var" => nil})
      {:ok, value} = PtcRunner.Context.get_var(context, "null_var")

      assert value == nil
    end

    test "returns error for non-string variable name (integer)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_var(context, 42)

      assert message =~ "Variable name must be a string"
    end

    test "returns error for non-string variable name (atom)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_var(context, :symbol)

      assert message =~ "Variable name must be a string"
    end

    test "returns error for non-string variable name (nil)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_var(context, nil)

      assert message =~ "Variable name must be a string"
    end

    test "returns error for non-string variable name (list)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_var(context, [])

      assert message =~ "Variable name must be a string"
    end

    test "returns error for non-string variable name (map)" do
      context = PtcRunner.Context.new()
      {:error, {:execution_error, message}} = PtcRunner.Context.get_var(context, %{})

      assert message =~ "Variable name must be a string"
    end
  end

  describe "Context.put_var/3" do
    test "sets new variable in empty context" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "x", 42)

      assert updated.variables == %{"x" => 42}
    end

    test "updates existing variable" do
      context = PtcRunner.Context.new(%{"x" => 10})
      updated = PtcRunner.Context.put_var(context, "x", 20)

      assert updated.variables == %{"x" => 20}
    end

    test "adds new variable without modifying existing ones" do
      context = PtcRunner.Context.new(%{"x" => 10})
      updated = PtcRunner.Context.put_var(context, "y", 20)

      assert updated.variables == %{"x" => 10, "y" => 20}
    end

    test "stores list value" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "data", [1, 2, 3])

      assert updated.variables == %{"data" => [1, 2, 3]}
    end

    test "stores map value" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "config", %{"key" => "value"})

      assert updated.variables == %{"config" => %{"key" => "value"}}
    end

    test "stores nil value" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "null_var", nil)

      assert updated.variables == %{"null_var" => nil}
    end

    test "preserves tools when putting variable" do
      tools = %{"fn1" => &:erlang.self/0}
      context = PtcRunner.Context.new(%{}, tools)
      updated = PtcRunner.Context.put_var(context, "x", 42)

      assert updated.tools == tools
    end

    test "variable name with special characters" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "var_name_123", "value")

      assert updated.variables == %{"var_name_123" => "value"}
    end

    test "variable name with spaces" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "var with spaces", "value")

      assert updated.variables == %{"var with spaces" => "value"}
    end
  end

  describe "Context - integration tests" do
    test "get and put variable roundtrip" do
      context = PtcRunner.Context.new()
      updated = PtcRunner.Context.put_var(context, "x", 100)
      {:ok, value} = PtcRunner.Context.get_var(updated, "x")

      assert value == 100
    end

    test "multiple variable operations" do
      context = PtcRunner.Context.new()
      c1 = PtcRunner.Context.put_var(context, "x", 10)
      c2 = PtcRunner.Context.put_var(c1, "y", 20)
      c3 = PtcRunner.Context.put_var(c2, "z", 30)

      {:ok, x} = PtcRunner.Context.get_var(c3, "x")
      {:ok, y} = PtcRunner.Context.get_var(c3, "y")
      {:ok, z} = PtcRunner.Context.get_var(c3, "z")

      assert x == 10
      assert y == 20
      assert z == 30
    end

    test "original context unmodified after put_var" do
      original = PtcRunner.Context.new(%{"x" => 10})
      updated = PtcRunner.Context.put_var(original, "y", 20)

      assert original.variables == %{"x" => 10}
      assert updated.variables == %{"x" => 10, "y" => 20}
    end
  end
end
