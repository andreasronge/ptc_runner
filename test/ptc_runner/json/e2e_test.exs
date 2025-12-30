defmodule PtcRunner.Json.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias PtcRunner.Step
  alias PtcRunner.TestSupport.LLMClient

  setup_all do
    IO.puts("\n=== PTC-JSON E2E Tests ===")
    IO.puts("Model: #{LLMClient.model()}\n")
    :ok
  end

  describe "Text mode - uses Schema.to_prompt() (~300 tokens)" do
    @describetag :text_mode

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

      assert {:ok, %Step{return: result}} =
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

      assert {:ok, %Step{return: result}} =
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

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 2
    end

    # Tests targeting issue #93 - DSL consistency problems

    test "find row with max value using max_by" do
      task = "Find the employee with the highest years_employed value"
      program_json = LLMClient.generate_program_text!(task)
      IO.puts("\n=== LLM Generated (max_by test) ===\n#{program_json}\n")

      context = %{
        "input" => [
          %{"name" => "Alice", "years_employed" => 3},
          %{"name" => "Bob", "years_employed" => 7},
          %{"name" => "Carol", "years_employed" => 5}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result["name"] == "Bob"
      assert result["years_employed"] == 7
    end

    test "find row with min value using min_by" do
      task = "Find the product with the lowest price"
      program_json = LLMClient.generate_program_text!(task)
      IO.puts("\n=== LLM Generated (min_by test) ===\n#{program_json}\n")

      context = %{
        "input" => [
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Phone", "price" => 599}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result["name"] == "Book"
      assert result["price"] == 15
    end

    test "extract single field from each item (get path confusion)" do
      task = "Get all product names as a list"
      program_json = LLMClient.generate_program_text!(task)
      IO.puts("\n=== LLM Generated (pluck/get test) ===\n#{program_json}\n")

      context = %{
        "input" => [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == ["Apple", "Book", "Laptop"]
    end

    test "sort by field using sort_by" do
      task = "Sort products by price from lowest to highest"
      program_json = LLMClient.generate_program_text!(task)
      IO.puts("\n=== LLM Generated (sort_by test) ===\n#{program_json}\n")

      context = %{
        "input" => [
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Phone", "price" => 599}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert is_list(result)
      assert length(result) == 3
      prices = Enum.map(result, & &1["price"])
      assert prices == [15, 599, 999]
    end
  end

  describe "Structured mode - uses Schema.to_llm_schema() with API enforcement" do
    @describetag :structured_mode
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

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      # Constraint assertions - not exact values
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

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 60
    end

    test "generates valid chained operations with structured output" do
      task = "Filter products where price > 10, then count them"

      program_json = LLMClient.generate_program_structured!(task)

      context = %{
        "input" => [
          %{"name" => "A", "price" => 5},
          %{"name" => "B", "price" => 15},
          %{"name" => "C", "price" => 25}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      assert result == 2
    end

    test "calculates percentage using arithmetic operations" do
      task = "What percentage of orders have been delivered?"

      program_json = LLMClient.generate_program_structured!(task)

      context = %{
        "input" => [
          %{"status" => "delivered"},
          %{"status" => "pending"},
          %{"status" => "delivered"}
        ]
      }

      assert {:ok, %Step{return: result}} =
               PtcRunner.Json.run(program_json, context: context)

      # 2 delivered out of 3 total = 66.67%
      assert is_number(result)
      assert_in_delta result, 66.67, 1.0
    end
  end
end
