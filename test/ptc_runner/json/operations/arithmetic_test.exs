defmodule PtcRunner.Json.Operations.ArithmeticTest do
  use ExUnit.Case

  # Add operation
  describe "add operation" do
    test "adds two integers" do
      program =
        ~s({"program": {"op": "add", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 3}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 8
    end

    test "adds two floats" do
      program =
        ~s({"program": {"op": "add", "left": {"op": "literal", "value": 1.5}, "right": {"op": "literal", "value": 2.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 4.0
    end

    test "adds mixed int and float" do
      program =
        ~s({"program": {"op": "add", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 2.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 7.5
    end

    test "adds with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "a", "value": {"op": "literal", "value": 10}, "in": {"op": "let", "name": "b", "value": {"op": "literal", "value": 20}, "in": {"op": "add", "left": {"op": "var", "name": "a"}, "right": {"op": "var", "name": "b"}}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 30
    end

    test "add requires numeric operands" do
      program =
        ~s({"program": {"op": "add", "left": {"op": "literal", "value": "hello"}, "right": {"op": "literal", "value": 5}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric operands")
    end
  end

  # Sub operation
  describe "sub operation" do
    test "subtracts two integers" do
      program =
        ~s({"program": {"op": "sub", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 3}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 7
    end

    test "subtracts two floats" do
      program =
        ~s({"program": {"op": "sub", "left": {"op": "literal", "value": 5.5}, "right": {"op": "literal", "value": 2.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 3.0
    end

    test "subtracts mixed int and float" do
      program =
        ~s({"program": {"op": "sub", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 2.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 7.5
    end

    test "sub with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "total", "value": {"op": "literal", "value": 100}, "in": {"op": "let", "name": "spent", "value": {"op": "literal", "value": 30}, "in": {"op": "sub", "left": {"op": "var", "name": "total"}, "right": {"op": "var", "name": "spent"}}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 70
    end

    test "sub requires numeric operands" do
      program =
        ~s({"program": {"op": "sub", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": []}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric operands")
    end
  end

  # Mul operation
  describe "mul operation" do
    test "multiplies two integers" do
      program =
        ~s({"program": {"op": "mul", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 3}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 15
    end

    test "multiplies two floats" do
      program =
        ~s({"program": {"op": "mul", "left": {"op": "literal", "value": 2.5}, "right": {"op": "literal", "value": 4.0}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 10.0
    end

    test "multiplies mixed int and float" do
      program =
        ~s({"program": {"op": "mul", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 1.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 7.5
    end

    test "mul with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "qty", "value": {"op": "literal", "value": 5}, "in": {"op": "let", "name": "price", "value": {"op": "literal", "value": 10}, "in": {"op": "mul", "left": {"op": "var", "name": "qty"}, "right": {"op": "var", "name": "price"}}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 50
    end

    test "mul requires numeric operands" do
      program =
        ~s({"program": {"op": "mul", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": true}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric operands")
    end
  end

  # Div operation
  describe "div operation" do
    test "divides two integers" do
      program =
        ~s({"program": {"op": "div", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 4}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 2.5
    end

    test "divides two floats" do
      program =
        ~s({"program": {"op": "div", "left": {"op": "literal", "value": 7.5}, "right": {"op": "literal", "value": 2.5}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 3.0, 0.001
    end

    test "divides mixed int and float" do
      program =
        ~s({"program": {"op": "div", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 2.0}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 2.5
    end

    test "div with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "numerator", "value": {"op": "literal", "value": 20}, "in": {"op": "let", "name": "denominator", "value": {"op": "literal", "value": 4}, "in": {"op": "div", "left": {"op": "var", "name": "numerator"}, "right": {"op": "var", "name": "denominator"}}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 5.0
    end

    test "div by zero returns error" do
      program =
        ~s({"program": {"op": "div", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 0}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "division by zero")
    end

    test "div requires numeric operands" do
      program =
        ~s({"program": {"op": "div", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": "two"}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric operands")
    end
  end

  # Round operation
  describe "round operation" do
    test "rounds to nearest integer (default precision 0)" do
      program = ~s({"program": {"op": "round", "value": {"op": "literal", "value": 3.7}}})
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 4.0
    end

    test "rounds down with precision 0" do
      program = ~s({"program": {"op": "round", "value": {"op": "literal", "value": 3.4}}})
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 3.0
    end

    test "rounds to 2 decimal places" do
      program =
        ~s({"program": {"op": "round", "value": {"op": "literal", "value": 3.14159}, "precision": 2}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 3.14, 0.001
    end

    test "rounds to 1 decimal place" do
      program =
        ~s({"program": {"op": "round", "value": {"op": "literal", "value": 2.76}, "precision": 1}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 2.8
    end

    test "round with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "value", "value": {"op": "literal", "value": 3.14159}, "in": {"op": "round", "value": {"op": "var", "name": "value"}, "precision": 2}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 3.14, 0.001
    end

    test "round requires numeric value" do
      program =
        ~s({"program": {"op": "round", "value": {"op": "literal", "value": "not a number"}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric value")
    end

    test "round with integer value works" do
      program = ~s({"program": {"op": "round", "value": {"op": "literal", "value": 5}}})
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 5.0
    end
  end

  # Pct operation
  describe "pct operation" do
    test "calculates simple percentage" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": 1}, "whole": {"op": "literal", "value": 4}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 25.0, 0.001
    end

    test "calculates percentage with two thirds" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": 2}, "whole": {"op": "literal", "value": 3}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 66.66666666666666, 0.001
    end

    test "calculates percentage with floats" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": 1.5}, "whole": {"op": "literal", "value": 5.0}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 30.0
    end

    test "pct with variable expressions" do
      program =
        ~s({"program": {"op": "let", "name": "delivered", "value": {"op": "literal", "value": 80}, "in": {"op": "let", "name": "total", "value": {"op": "literal", "value": 100}, "in": {"op": "pct", "part": {"op": "var", "name": "delivered"}, "whole": {"op": "var", "name": "total"}}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 80.0
    end

    test "pct by zero returns error" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": 50}, "whole": {"op": "literal", "value": 0}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "division by zero")
    end

    test "pct requires numeric operands" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": "fifty"}, "whole": {"op": "literal", "value": 100}}})

      {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
      assert String.contains?(msg, "numeric operands")
    end

    test "pct with 0 part returns 0" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "literal", "value": 0}, "whole": {"op": "literal", "value": 100}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 0.0
    end
  end

  # Nested operations
  describe "nested arithmetic operations" do
    test "combine add and mul" do
      program =
        ~s({"program": {"op": "add", "left": {"op": "literal", "value": 2}, "right": {"op": "mul", "left": {"op": "literal", "value": 3}, "right": {"op": "literal", "value": 4}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 14
    end

    test "combine sub and div" do
      program =
        ~s({"program": {"op": "sub", "left": {"op": "literal", "value": 10}, "right": {"op": "div", "left": {"op": "literal", "value": 8}, "right": {"op": "literal", "value": 2}}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 6.0
    end

    test "round result of division" do
      program =
        ~s({"program": {"op": "round", "value": {"op": "div", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 3}}, "precision": 2}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert_in_delta result, 3.33, 0.001
    end

    test "percentage of calculated value" do
      program =
        ~s({"program": {"op": "pct", "part": {"op": "div", "left": {"op": "literal", "value": 1}, "right": {"op": "literal", "value": 2}}, "whole": {"op": "literal", "value": 1}}})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 50.0
    end
  end
end
