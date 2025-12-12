defmodule PtcRunner.Json.InterpreterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Json.Interpreter

  describe "Interpreter.eval/2 - error cases" do
    test "no longer error when node is missing 'op' field - treated as implicit object" do
      node = %{"value" => 42}
      context = PtcRunner.Context.new()

      # Maps without "op" are now treated as implicit objects
      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{"value" => 42}
    end

    test "no longer error when node is empty map without op - treated as implicit object" do
      node = %{}
      context = PtcRunner.Context.new()

      # Empty maps are now treated as implicit objects
      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{}
    end

    test "returns error when node is a string" do
      node = "not a map"
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
      assert message =~ "not a map"
    end

    test "returns error when node is a list" do
      node = [1, 2, 3]
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end

    test "returns error when node is an integer" do
      node = 42
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end

    test "returns error when node is nil" do
      node = nil
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end

    test "returns error when node is a boolean" do
      node = true
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end

    test "returns error when node is an atom" do
      node = :symbol
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end

    test "returns error when node is a tuple" do
      node = {:op, "literal"}
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message =~ "Node must be a map"
    end
  end

  describe "Interpreter.eval/2 - valid operations" do
    test "evaluates literal operation" do
      node = %{"op" => "literal", "value" => 42}
      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == 42
    end

    test "evaluates load operation" do
      node = %{"op" => "load", "name" => "x"}
      context = PtcRunner.Context.new(%{"x" => 100}, %{}, %{})

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == 100
    end
  end

  describe "Interpreter.eval/2 - implicit object literals" do
    test "evaluates empty map as implicit object literal" do
      node = %{}
      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{}
    end

    test "evaluates map with literal values as implicit object" do
      node = %{"name" => "Alice", "age" => 30}
      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{"name" => "Alice", "age" => 30}
    end

    test "evaluates map with null values as implicit object" do
      node = %{"name" => "Bob", "email" => nil}
      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{"name" => "Bob", "email" => nil}
    end

    test "evaluates map with operation values as implicit object" do
      node = %{
        "x" => %{"op" => "literal", "value" => 10},
        "y" => %{"op" => "literal", "value" => 20}
      }

      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{"x" => 10, "y" => 20}
    end

    test "evaluates nested implicit objects" do
      node = %{
        "user" => %{"name" => "Charlie", "active" => true},
        "count" => 5
      }

      context = PtcRunner.Context.new()

      {:ok, result, _memory} = Interpreter.eval(node, context)

      assert result == %{"user" => %{"name" => "Charlie", "active" => true}, "count" => 5}
    end
  end
end
