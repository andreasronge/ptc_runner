defmodule PtcRunner.Lisp.E2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e

  alias PtcRunner.Step
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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)
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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)
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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)
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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

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

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)
      assert result == 3
    end

    test "build collections with conj" do
      task = "Build up a vector using conj, then build a map from key-value pairs"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (conj) ===\n#{program}\n")

      context = %{
        "numbers" => [1, 2, 3],
        "pairs" => [["a", 1], ["b", 2]]
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

      # Result should show multiple operations with conj
      assert is_list(result) or is_map(result)
    end

    test "seq for character iteration" do
      task = "Convert a string to characters using seq, then count them"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (seq + characters) ===\n#{program}\n")

      context = %{
        "text" => "hello"
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)
      assert result == 5
    end

    test "string manipulation with str, split, and join" do
      task = "Build a CSV row from values, then split and join with different separator"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (str + split + join) ===\n#{program}\n")

      context = %{
        "values" => ["apple", "banana", "cherry"]
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

      # Result should be a string
      assert is_binary(result)
    end

    test "string case transformations with trim and replace" do
      task = "Clean up a string by trimming whitespace and removing dashes"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (trim + replace) ===\n#{program}\n")

      context = %{
        "text" => "  hello-world  "
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

      # Result should be trimmed and dashes replaced
      assert is_binary(result)
      assert not String.starts_with?(result, " ")
      assert not String.ends_with?(result, " ")
    end

    test "string case conversion and predicates" do
      task =
        "Filter users with 'user_' prefix and check if any username contains 'admin' (case-insensitive)"

      program = LispLLMClient.generate_program!(task)
      IO.puts("\n=== LLM Generated (string case/predicates) ===\n#{program}\n")

      context = %{
        "usernames" => ["user_1", "ADMIN", "user_2", "guest"]
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

      # Should demonstrate case conversion and predicate usage
      assert is_map(result) or is_list(result) or is_boolean(result)
    end
  end

  describe "Short function syntax #()" do
    test "filter with #(> % 10)" do
      program = "(filter #(> % 10) [5 15 8 20])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [15, 20]
    end

    test "map with #(str \"id-\" %)" do
      program = "(map #(str \"id-\" %) [1 2 3])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == ["id-1", "id-2", "id-3"]
    end

    test "reduce with #(+ %1 %2)" do
      program = "(reduce #(+ %1 %2) 0 [1 2 3])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == 6
    end

    test "map with #(* % %)" do
      program = "(map #(* % %) [1 2 3 4])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [1, 4, 9, 16]
    end

    test "identity function #(%)" do
      program = "((fn [coll] (map #(%) coll)) [10 20 30])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [10, 20, 30]
    end

    test "zero-arity thunk #(42)" do
      program = "(#(42))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == 42
    end

    test "chained operations with short functions" do
      program = "(->> [1 2 3 4 5] (filter #(> % 2)) (map #(* % 2)))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [6, 8, 10]
    end
  end

  describe "memory operations" do
    test "memory/put and memory/get work correctly" do
      program = """
      (do
        (memory/put :count 42)
        (memory/get :count))
      """

      assert {:ok, %Step{return: result, memory: memory}} = PtcRunner.Lisp.run(program)
      assert result == 42
      assert memory[:count] == 42
    end

    test "memory/put returns the stored value" do
      program = "(memory/put :value 123)"

      assert {:ok, %Step{return: result, memory: memory}} = PtcRunner.Lisp.run(program)
      assert result == 123
      assert memory[:value] == 123
    end

    test "memory/get returns nil for missing key" do
      program = "(memory/get :missing)"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == nil
    end

    test "multiple memory operations maintain state" do
      program = """
      (do
        (memory/put :x 10)
        (memory/put :y 20)
        (+ (memory/get :x) (memory/get :y)))
      """

      assert {:ok, %Step{return: result, memory: memory}} = PtcRunner.Lisp.run(program)
      assert result == 30
      assert memory[:x] == 10
      assert memory[:y] == 20
    end
  end
end
