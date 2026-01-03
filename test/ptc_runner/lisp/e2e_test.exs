defmodule PtcRunner.Lisp.E2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  Focused E2E tests for PTC-Lisp LLM generation.

  Tests basic operations that LLMs can reliably generate.
  Complex queries are covered by demo benchmarks instead.

  Run with: mix test test/ptc_runner/lisp/e2e_test.exs --include e2e
  """

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

  describe "Short function syntax #()" do
    # These test syntax parsing, not LLM generation

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

    test "chained operations with short functions" do
      program = "(->> [1 2 3 4 5] (filter #(> % 2)) (map #(* % 2)))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [6, 8, 10]
    end
  end

  describe "Memory operations" do
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
