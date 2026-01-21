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

  describe "juxt function combinator" do
    test "multi-criteria sorting with juxt" do
      # Sort by priority (ascending) then name (ascending)
      program = "(sort-by (juxt :priority :name) data/tasks)"

      context = %{
        tasks: [
          %{priority: 2, name: "Deploy"},
          %{priority: 1, name: "Test"},
          %{priority: 1, name: "Build"}
        ]
      }

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program, context: context)

      assert result == [
               %{priority: 1, name: "Build"},
               %{priority: 1, name: "Test"},
               %{priority: 2, name: "Deploy"}
             ]
    end

    test "extract multiple values with map and juxt" do
      program = "(map (juxt :x :y) [{:x 1 :y 2} {:x 3 :y 4}])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [[1, 2], [3, 4]]
    end

    test "juxt with closures" do
      program = "((juxt #(+ % 1) #(* % 2)) 5)"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [6, 10]
    end
  end

  describe "pmap parallel map" do
    test "pmap basic functionality" do
      program = "(pmap inc [1 2 3 4 5])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [2, 3, 4, 5, 6]
    end

    test "pmap with anonymous function" do
      program = "(pmap #(* % 2) [1 2 3])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [2, 4, 6]
    end

    test "pmap with keyword accessor" do
      program = "(pmap :name [{:name \"Alice\"} {:name \"Bob\"}])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == ["Alice", "Bob"]
    end

    test "pmap preserves order" do
      program = "(pmap identity [1 2 3 4 5 6 7 8 9 10])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    end

    test "pmap with closure capturing let binding" do
      program = "(let [factor 10] (pmap #(* % factor) [1 2 3]))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [10, 20, 30]
    end

    test "pmap with tool calls provides speedup" do
      # Simulate slow tool calls - 50ms each
      # Sequential: 5 * 50ms = 250ms minimum
      # Parallel: ~50ms minimum (all run concurrently)
      # We check that parallel is significantly faster

      # Tools receive string keys at the boundary
      slow_tool = fn %{"value" => v} ->
        Process.sleep(50)
        v * 2
      end

      program = "(pmap #(tool/slow-process {:value %}) [1 2 3 4 5])"

      {time_us, {:ok, %Step{return: result}}} =
        :timer.tc(fn ->
          PtcRunner.Lisp.run(program, tools: [{"slow-process", slow_tool}])
        end)

      time_ms = div(time_us, 1000)

      # Result should be correct
      assert result == [2, 4, 6, 8, 10]

      # Should be significantly faster than sequential (250ms)
      # Allow some overhead, but should be under 200ms
      assert time_ms < 200,
             "pmap should run in parallel (took #{time_ms}ms, expected <200ms)"
    end

    test "pmap with empty collection" do
      program = "(pmap inc [])"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == []
    end
  end

  describe "pcalls parallel calls" do
    test "pcalls basic functionality" do
      program = "(pcalls #(+ 1 1) #(* 2 3) #(- 10 5))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [2, 6, 5]
    end

    test "pcalls with closures capturing let bindings" do
      program = "(let [x 10 y 20] (pcalls #(+ x 1) #(* y 2)))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [11, 40]
    end

    test "pcalls with empty arguments" do
      program = "(pcalls)"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == []
    end

    test "pcalls preserves order" do
      # Create 10 thunks that each return their position
      program =
        "(pcalls #(identity 0) #(identity 1) #(identity 2) #(identity 3) #(identity 4) #(identity 5) #(identity 6) #(identity 7) #(identity 8) #(identity 9))"

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    end

    test "pcalls with tool calls provides speedup" do
      # Simulate slow tool calls - 50ms each
      # Sequential: 3 * 50ms = 150ms minimum
      # Parallel: ~50ms minimum (all run concurrently)

      # Tools receive string keys at the boundary
      slow_user = fn %{"id" => id} ->
        Process.sleep(50)
        %{name: "User#{id}"}
      end

      slow_stats = fn %{"id" => id} ->
        Process.sleep(50)
        %{count: id * 10}
      end

      slow_config = fn %{} ->
        Process.sleep(50)
        %{theme: "dark"}
      end

      program = """
      (pcalls
        #(tool/get-user {:id 1})
        #(tool/get-stats {:id 2})
        #(tool/get-config {}))
      """

      {time_us, {:ok, %Step{return: result}}} =
        :timer.tc(fn ->
          PtcRunner.Lisp.run(program,
            tools: [
              {"get-user", slow_user},
              {"get-stats", slow_stats},
              {"get-config", slow_config}
            ]
          )
        end)

      time_ms = div(time_us, 1000)

      # Result should be correct
      assert result == [%{name: "User1"}, %{count: 20}, %{theme: "dark"}]

      # Should be significantly faster than sequential (150ms)
      # Allow some overhead, but should be under 120ms
      assert time_ms < 120,
             "pcalls should run in parallel (took #{time_ms}ms, expected <120ms)"
    end

    test "pcalls destructuring result" do
      # Common pattern: fetch multiple things and destructure
      program = """
      (let [[a b c] (pcalls #(+ 1 1) #(+ 2 2) #(+ 3 3))]
        {:sum (+ a b c) :items [a b c]})
      """

      assert {:ok, %Step{return: result}} = PtcRunner.Lisp.run(program)
      assert result == %{sum: 12, items: [2, 4, 6]}
    end
  end
end
