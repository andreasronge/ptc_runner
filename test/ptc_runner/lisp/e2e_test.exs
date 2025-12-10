defmodule PtcRunner.Lisp.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias PtcRunner.TestSupport.LispLLMClient

  setup_all do
    IO.puts("\n=== PTC-Lisp E2E Tests ===")
    IO.puts("Model: #{LispLLMClient.model()}\n")
    :ok
  end

  describe "Basic operations" do
    test "filter with simple predicate" do
      task = "Filter products where price is greater than 10"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (filter) ===\n#{program}\n")

      context = %{
        "products" => [
          %{"name" => "Apple", "price" => 5},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Laptop", "price" => 999}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)

      assert is_list(result)
      assert length(result) == 2
      assert Enum.all?(result, fn item -> item["price"] > 10 end)
    end

    test "sum aggregation" do
      task = "Calculate the sum of all prices"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (sum) ===\n#{program}\n")

      context = %{
        "products" => [
          %{"name" => "A", "price" => 10},
          %{"name" => "B", "price" => 20},
          %{"name" => "C", "price" => 30}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)
      assert result == 60
    end

    test "chained operations with threading" do
      task = "Filter products where price > 10, then count them"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (chain) ===\n#{program}\n")

      context = %{
        "products" => [
          %{"name" => "A", "price" => 5},
          %{"name" => "B", "price" => 15},
          %{"name" => "C", "price" => 25}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)
      assert result == 2
    end
  end

  describe "Advanced operations" do
    test "find max with field extraction" do
      task = "Find the most expensive product and return its name"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (max-by + field) ===\n#{program}\n")

      context = %{
        "products" => [
          %{"name" => "Laptop", "price" => 999},
          %{"name" => "Book", "price" => 15},
          %{"name" => "Phone", "price" => 599}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)
      assert result == "Laptop"
    end

    test "group by and aggregate" do
      task = "Group orders by status and count how many orders in each group"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (group-by + count) ===\n#{program}\n")

      context = %{
        "orders" => [
          %{"id" => 1, "status" => "pending", "total" => 100},
          %{"id" => 2, "status" => "delivered", "total" => 200},
          %{"id" => 3, "status" => "pending", "total" => 150},
          %{"id" => 4, "status" => "delivered", "total" => 300},
          %{"id" => 5, "status" => "cancelled", "total" => 50}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)

      # Result should be a map or list with counts per status
      assert is_map(result) or is_list(result)

      # Normalize to map for assertion
      result_map =
        if is_list(result) do
          Enum.into(result, %{}, fn item ->
            {item["status"] || item[:status], item["count"] || item[:count]}
          end)
        else
          result
        end

      assert result_map["pending"] == 2 or result_map[:pending] == 2
      assert result_map["delivered"] == 2 or result_map[:delivered] == 2
      assert result_map["cancelled"] == 1 or result_map[:cancelled] == 1
    end

    test "complex filter with multiple conditions" do
      task =
        "Find all employees who are in the engineering department AND have a salary greater than 80000"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (all-of) ===\n#{program}\n")

      context = %{
        "employees" => [
          %{"name" => "Alice", "department" => "engineering", "salary" => 90_000},
          %{"name" => "Bob", "department" => "engineering", "salary" => 70_000},
          %{"name" => "Carol", "department" => "sales", "salary" => 85_000},
          %{"name" => "Dave", "department" => "engineering", "salary" => 95_000}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)

      assert is_list(result)
      assert length(result) == 2
      names = Enum.map(result, & &1["name"])
      assert "Alice" in names
      assert "Dave" in names
    end
  end

  describe "Challenging queries" do
    test "top N with sorting" do
      task = "Get the names of the top 3 highest paid employees, sorted by salary descending"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (sort + take + pluck) ===\n#{program}\n")

      context = %{
        "employees" => [
          %{"name" => "Alice", "salary" => 70_000},
          %{"name" => "Bob", "salary" => 95_000},
          %{"name" => "Carol", "salary" => 85_000},
          %{"name" => "Dave", "salary" => 60_000},
          %{"name" => "Eve", "salary" => 120_000}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)

      assert is_list(result)
      assert length(result) == 3
      assert result == ["Eve", "Bob", "Carol"]
    end

    test "conditional aggregation" do
      task =
        "Calculate the average price of products in the electronics category that are in stock (where in_stock is true)"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (filter + avg-by) ===\n#{program}\n")

      context = %{
        "products" => [
          %{"name" => "Laptop", "category" => "electronics", "price" => 1000, "in_stock" => true},
          %{"name" => "Phone", "category" => "electronics", "price" => 500, "in_stock" => true},
          %{"name" => "Tablet", "category" => "electronics", "price" => 300, "in_stock" => false},
          %{"name" => "Book", "category" => "books", "price" => 20, "in_stock" => true},
          %{
            "name" => "Headphones",
            "category" => "electronics",
            "price" => 200,
            "in_stock" => true
          }
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)

      # Average of 1000 + 500 + 200 = 1700 / 3 ≈ 566.67
      assert is_number(result)
      assert_in_delta result, 566.67, 1.0
    end

    test "distinct count from nested field" do
      task = "Count how many unique product categories have been ordered"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (distinct + count) ===\n#{program}\n")

      context = %{
        "orders" => [
          %{"id" => 1, "product_category" => "electronics"},
          %{"id" => 2, "product_category" => "books"},
          %{"id" => 3, "product_category" => "electronics"},
          %{"id" => 4, "product_category" => "clothing"},
          %{"id" => 5, "product_category" => "books"},
          %{"id" => 6, "product_category" => "electronics"}
        ]
      }

      assert {:ok, result, _memory_delta, _memory} = PtcRunner.Lisp.run(program, context: context)
      assert result == 3
    end
  end
end
