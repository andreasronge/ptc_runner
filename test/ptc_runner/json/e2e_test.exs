defmodule PtcRunner.Json.E2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Focused E2E tests for PTC-JSON LLM generation.

  Tests basic operations that LLMs can reliably generate.
  Complex queries are covered by demo benchmarks instead.

  Run with: mix test test/ptc_runner/json/e2e_test.exs --include e2e
  """

  @moduletag :e2e

  alias PtcRunner.TestSupport.LLMClient

  setup_all do
    IO.puts("\n=== PTC-JSON E2E Tests ===")
    IO.puts("Model: #{LLMClient.model()}\n")
    :ok
  end

  describe "Text mode - uses Schema.to_prompt()" do
    test "generates valid filter program" do
      task = "Filter products where price is greater than 10"
      program_json = LLMClient.generate_program_text!(task)

      context = %{
        "input" => [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ]
      }

      assert {:ok, result, _memory_delta, _new_memory} =
               PtcRunner.Json.run(program_json, context: context)

      assert is_list(result)
      assert length(result) == 2
      assert Enum.all?(result, fn item -> item["price"] > 10 end)
    end

    test "generates valid sum aggregation" do
      task = "Calculate the sum of all prices"
      program_json = LLMClient.generate_program_text!(task)

      context = %{
        "input" => [
          %{"price" => 10},
          %{"price" => 20},
          %{"price" => 30}
        ]
      }

      assert {:ok, result, _memory_delta, _new_memory} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 60
    end

    test "generates valid chained operations" do
      task = "Filter products where price > 10, then count them"
      program_json = LLMClient.generate_program_text!(task)

      context = %{
        "input" => [
          %{"name" => "A", "price" => 5},
          %{"name" => "B", "price" => 15},
          %{"name" => "C", "price" => 25}
        ]
      }

      assert {:ok, result, _memory_delta, _new_memory} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 2
    end
  end

  describe "Structured mode - uses Schema.to_llm_schema()" do
    test "generates valid filter program with structured output" do
      task = "Filter products where price is greater than 10"

      program_json = LLMClient.generate_program_structured!(task)

      context = %{
        "input" => [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ]
      }

      assert {:ok, result, _memory_delta, _new_memory} =
               PtcRunner.Json.run(program_json, context: context)

      assert is_list(result)
      assert length(result) == 2
      assert Enum.all?(result, fn item -> item["price"] > 10 end)
    end

    test "generates valid sum aggregation with structured output" do
      task = "Calculate the sum of all prices"

      program_json = LLMClient.generate_program_structured!(task)

      context = %{
        "input" => [
          %{"price" => 10},
          %{"price" => 20},
          %{"price" => 30}
        ]
      }

      assert {:ok, result, _memory_delta, _new_memory} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 60
    end
  end
end
