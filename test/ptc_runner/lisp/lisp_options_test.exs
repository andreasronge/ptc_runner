defmodule PtcRunner.Lisp.OptionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "float_precision option" do
    test "rounds floats in result to specified precision" do
      assert {:ok, %{return: 3.33, memory: %{}}} =
               Lisp.run("(/ 10 3)", float_precision: 2)
    end

    test "full precision when not specified" do
      {:ok, %{return: result, memory: %{}}} = Lisp.run("(/ 10 3)")
      assert result == 10 / 3
    end

    test "rounds floats in nested structures" do
      {:ok, %{return: result, memory: %{}}} =
        Lisp.run("[1.12345 2.67891]", float_precision: 2)

      assert result == [1.12, 2.68]
    end

    test "rounds floats in map values" do
      {:ok, %{return: result, memory: _}} =
        Lisp.run("{:value (/ 10 3)}", float_precision: 1)

      assert result == %{value: 3.3}
    end

    test "precision 0 rounds to integers" do
      {:ok, %{return: result, memory: %{}}} =
        Lisp.run("(/ 10 3)", float_precision: 0)

      assert result == 3.0
    end

    test "does not affect integers" do
      assert {:ok, %{return: 42, memory: %{}}} =
               Lisp.run("42", float_precision: 2)
    end

    test "rounds result including nested floats" do
      # V2: no implicit memory merge, map returns as-is with floats rounded
      {:ok, %{return: result, memory: _}} =
        Lisp.run("{:value (/ 10 3), :pi 3.14159}", float_precision: 2)

      assert result == %{value: 3.33, pi: 3.14}
    end
  end

  describe "tool normalization (LISP-04)" do
    test "accepts bare function" do
      tools = %{"greet" => fn _args -> "hello" end}

      assert {:ok, %{return: "hello", memory: %{}}} =
               Lisp.run("(tool/greet)", tools: tools)
    end

    test "accepts function with explicit signature" do
      tools = %{"greet" => {fn _args -> "hello" end, "() -> :string"}}

      assert {:ok, %{return: "hello", memory: %{}}} =
               Lisp.run("(tool/greet)", tools: tools)
    end

    test "accepts function with signature and description" do
      tools = %{
        "greet" =>
          {fn _args -> "hello" end, signature: "() -> :string", description: "Returns a greeting"}
      }

      assert {:ok, %{return: "hello", memory: %{}}} =
               Lisp.run("(tool/greet)", tools: tools)
    end

    test "accepts function with :skip validation" do
      tools = %{"greet" => {fn _args -> "hello" end, :skip}}

      assert {:ok, %{return: "hello", memory: %{}}} =
               Lisp.run("(tool/greet)", tools: tools)
    end

    test "returns error for invalid tool format" do
      tools = %{"bad" => :not_a_function}

      assert {:error, %{fail: %{reason: :invalid_tool, message: message}}} =
               Lisp.run("(tool/bad)", tools: tools)

      assert message =~ "Tool 'bad'"
    end

    test "empty tools map works correctly" do
      assert {:ok, %{return: 42, memory: %{}}} =
               Lisp.run("42", tools: %{})
    end
  end

  describe "signature validation (LISP-05)" do
    test "validates return value against signature" do
      source = "{:count 5}"

      assert {:ok, %{return: %{count: 5}, signature: signature}} =
               Lisp.run(source, signature: "{count :int}")

      assert signature == "{count :int}"
    end

    test "returns error when validation fails" do
      source = "{:count \"not an int\"}"

      assert {:error, %{fail: %{reason: :validation_error, message: message}}} =
               Lisp.run(source, signature: "{count :int}")

      assert message =~ "count"
      assert message =~ "expected int"
    end

    test "signature stored in step on success" do
      source = "42"

      assert {:ok, %{signature: signature}} = Lisp.run(source, signature: ":int")

      assert signature == ":int"
    end

    test "skip signature validation when option not provided" do
      source = "42"
      assert {:ok, %{signature: nil}} = Lisp.run(source)
    end

    test "validates nested structure" do
      source = "{:items [{:id 1} {:id 2}]}"

      assert {:ok, %{return: %{items: _}}} =
               Lisp.run(source, signature: "{items [{id :int}]}")
    end

    test "validates with optional fields" do
      source = "{:name \"Alice\"}"

      assert {:ok, %{return: %{name: "Alice"}}} =
               Lisp.run(source, signature: "{name :string, age :int?}")
    end

    test "validation error includes path to failed field" do
      source = "{:user {:id \"not an int\"}}"

      assert {:error, %{fail: %{reason: :validation_error, message: message}}} =
               Lisp.run(source, signature: "{user {id :int}}")

      assert message =~ "user"
      assert message =~ "id"
    end

    test "returns parse error for invalid signature" do
      assert {:error, %{fail: %{reason: :parse_error, message: message}}} =
               Lisp.run("42", signature: "invalid syntax")

      assert message =~ "Invalid signature"
    end

    test "validates list return values" do
      source = "[1 2 3]"

      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(source, signature: "[:int]")
    end

    test "validates primitive return values" do
      source = "42"
      assert {:ok, %{return: 42}} = Lisp.run(source, signature: ":int")

      source = "\"hello\""
      assert {:ok, %{return: "hello"}} = Lisp.run(source, signature: ":string")

      source = "true"
      assert {:ok, %{return: true}} = Lisp.run(source, signature: ":bool")
    end

    test "validation works with map results" do
      # V2: :return is just a regular key, map returns as-is
      source = "{:value 42, :stored 100}"

      assert {:ok, %{return: %{value: 42, stored: 100}, signature: _}} =
               Lisp.run(source, signature: "{value :int, stored :int}")
    end
  end

  describe "max_symbols option" do
    test "rejects programs exceeding symbol limit" do
      # Program with 100 unique keywords exceeds limit of 50
      keywords = Enum.map_join(1..100, " ", &":k#{&1}")
      program = "{#{keywords}}"

      assert {:error, step} = Lisp.run(program, max_symbols: 50)
      assert step.fail.reason == :symbol_limit_exceeded
      assert step.fail.message =~ "100 unique symbols/keywords"
      assert step.fail.message =~ "exceeds limit of 50"
    end

    test "accepts programs within limit" do
      program = "{:a 1 :b 2 :c 3}"
      assert {:ok, %{return: %{a: 1, b: 2, c: 3}}} = Lisp.run(program, max_symbols: 10)
    end

    test "uses default limit of 10_000" do
      # Simple program should pass with default limit
      assert {:ok, _} = Lisp.run("{:a 1}")
    end

    test "core symbols do not count toward limit" do
      # (if true 1 2) uses only core symbols
      assert {:ok, _} = Lisp.run("(if true 1 2)", max_symbols: 0)
    end

    test "preserves memory on symbol limit error" do
      keywords = Enum.map_join(1..10, " ", &":k#{&1}")
      program = "{#{keywords}}"
      initial_memory = %{preserved: true}

      assert {:error, step} = Lisp.run(program, max_symbols: 5, memory: initial_memory)
      assert step.memory == initial_memory
    end
  end

  describe "sandbox - timeout" do
    test "simple expression completes within default timeout" do
      assert {:ok, %{return: 6, memory: %{}}} = Lisp.run("(+ 1 2 3)")
    end

    test "respects custom timeout option" do
      # Simple fast operation should complete within generous timeout
      assert {:ok, %{return: 5, memory: %{}}} =
               Lisp.run("(+ 2 3)", timeout: 5000)
    end

    test "timeout option is accepted without error" do
      # Just verify that timeout option doesn't cause errors
      # Actual timeout behavior is hard to test without expensive computations
      assert {:ok, %{return: 3, memory: %{}}} =
               Lisp.run("(+ 1 2)", timeout: 100)
    end
  end

  describe "sandbox - memory limits" do
    test "simple expression stays within memory limit" do
      assert {:ok, %{return: 42, memory: %{}}} = Lisp.run("42")
    end

    test "respects custom max_heap option" do
      # Small computation should complete with larger heap
      assert {:ok, %{return: _result, memory: %{}}} =
               Lisp.run("[1 2 3 4 5]", max_heap: 5_000_000)
    end

    test "max_heap option is accepted without error" do
      # Just verify that max_heap option doesn't cause errors
      assert {:ok, %{return: 5, memory: %{}}} =
               Lisp.run("(+ 2 3)", max_heap: 100_000)
    end
  end

  describe "sandbox - integration with existing features" do
    test "float_precision still works with sandbox" do
      assert {:ok, %{return: 3.33, memory: %{}}} =
               Lisp.run("(/ 10 3)", float_precision: 2, timeout: 1000)
    end

    test "map results work with sandbox execution" do
      # V2: maps pass through unchanged, no implicit memory merge
      source = "{:value 42, :stored 100}"

      {:ok, %{return: result, memory: new_memory}} =
        Lisp.run(source, timeout: 1000)

      assert result == %{value: 42, stored: 100}
      assert new_memory == %{}
    end

    test "context and tools still work with sandbox" do
      tools = %{
        # Tools receive string keys at the boundary
        "double" => fn %{"x" => x} -> x * 2 end
      }

      ctx = %{value: 5}
      source = "(tool/double {:x data/value})"

      assert {:ok, %{return: 10, memory: %{}}} =
               Lisp.run(source, context: ctx, tools: tools)
    end

    test "tool results work in map literals" do
      # V2: maps return as-is, no implicit memory merge
      tools = %{
        "get-data" => fn _args -> "success" end
      }

      source = "{:result (tool/get-data), :status \"done\"}"

      {:ok, %{return: result, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      assert result == %{result: "success", status: "done"}
      assert new_memory == %{}
    end
  end
end
