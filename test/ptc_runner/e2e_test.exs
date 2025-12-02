defmodule PtcRunner.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias PtcRunner.TestSupport.LLMClient

  describe "LLM program generation" do
    test "generates valid filter program" do
      task = "Filter products where price is greater than 10"
      json_schema = PtcRunner.Schema.to_json_schema()

      program_json = LLMClient.generate_program!(task, json_schema)

      context = %{
        "input" => [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ]
      }

      assert {:ok, result, _metrics} = PtcRunner.run(program_json, context: context)

      # Constraint assertions - not exact values
      assert is_list(result)
      assert length(result) == 2
      assert Enum.all?(result, fn item -> item["price"] > 10 end)
    end

    test "generates valid sum aggregation" do
      task = "Calculate the sum of all prices"
      json_schema = PtcRunner.Schema.to_json_schema()

      program_json = LLMClient.generate_program!(task, json_schema)

      context = %{
        "input" => [
          %{"price" => 10},
          %{"price" => 20},
          %{"price" => 30}
        ]
      }

      assert {:ok, result, _metrics} = PtcRunner.run(program_json, context: context)
      assert result == 60
    end

    test "generates valid chained operations" do
      task = "Filter products where price > 10, then count them"
      json_schema = PtcRunner.Schema.to_json_schema()

      program_json = LLMClient.generate_program!(task, json_schema)

      context = %{
        "input" => [
          %{"name" => "A", "price" => 5},
          %{"name" => "B", "price" => 15},
          %{"name" => "C", "price" => 25}
        ]
      }

      assert {:ok, result, _metrics} = PtcRunner.run(program_json, context: context)
      assert result == 2
    end
  end
end
