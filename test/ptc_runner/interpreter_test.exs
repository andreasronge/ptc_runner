defmodule PtcRunner.InterpreterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Json.Interpreter

  describe "Interpreter.eval/2 - error cases" do
    test "returns error when node is missing 'op' field" do
      node = %{"value" => 42}
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message == "Missing required field 'op'"
    end

    test "returns error when node is empty map without op" do
      node = %{}
      context = PtcRunner.Context.new()

      {:error, {:execution_error, message}} = Interpreter.eval(node, context)

      assert message == "Missing required field 'op'"
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

      {:ok, result} = Interpreter.eval(node, context)

      assert result == 42
    end

    test "evaluates load operation" do
      node = %{"op" => "load", "name" => "x"}
      context = PtcRunner.Context.new(%{"x" => 100})

      {:ok, result} = Interpreter.eval(node, context)

      assert result == 100
    end
  end
end
