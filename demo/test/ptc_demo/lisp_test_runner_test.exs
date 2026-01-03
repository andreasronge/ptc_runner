defmodule PtcDemo.LispTestRunnerTest do
  use ExUnit.Case, async: false

  import PtcDemo.TestHelpers

  alias PtcDemo.{LispTestRunner, MockAgent}

  setup do
    # Define mock responses for all test queries used by LispTestRunner
    # LispTestRunner uses: common_test_cases (13 tests) + lisp_specific_cases (1 test) + multi_turn_cases (2 tests) = 16 tests
    responses = %{
      # Level 1: Basic Operations
      "How many products are there?" => {:ok, "500 products", nil, 500},
      "How many orders have status 'delivered'?" => {:ok, "200 delivered orders", nil, 200},
      "What is the total revenue from all orders? (sum the total field)" =>
        {:ok, "Total is 2500000", nil, 2_500_000},
      "What is the average product rating?" => {:ok, "Average rating is 3.5", nil, 3.5},
      # Level 2: Intermediate Operations
      "How many employees work remotely?" => {:ok, "100 remote employees", nil, 100},
      "How many products cost more than $500?" => {:ok, "250 products", nil, 250},
      "How many orders over $1000 were paid by credit card?" => {:ok, "150 orders", nil, 150},
      "What is the name of the cheapest product?" => {:ok, "Product 42", nil, "Product 42"},
      # Level 3: Advanced Operations
      "Get the names of the 3 most expensive products" =>
        {:ok, "[Product A, Product B, Product C]", nil, ["Product A", "Product B", "Product C"]},
      "How many orders are either cancelled or refunded?" => {:ok, "300 orders", nil, 300},
      "What is the average salary of senior-level employees? Return only the numeric value." =>
        {:ok, "Average is 150000", nil, 150_000},
      "How many unique products have been ordered? (count distinct product_id values in orders)" =>
        {:ok, "300 unique products", nil, 300},
      "What is the total expense amount for employees in the engineering department? (Find engineering employee IDs, then sum expenses for those employees)" =>
        {:ok, "Total expenses: 50000", nil, 50_000},
      # Lisp-specific cases
      "Which expense category has the highest total spending? Return a map with :highest (the top category with its stats) and :breakdown (all categories sorted by total descending). Each category should have :category, :total, :count, and :avg fields." =>
        {:ok, "Travel category", nil,
         %{
           highest: %{category: "travel", total: 25000, count: 50, avg: 500},
           breakdown: [
             %{category: "travel", total: 25000, count: 50, avg: 500},
             %{category: "equipment", total: 15000, count: 30, avg: 500}
           ]
         }},
      # Multi-turn cases
      "Analyze expense claims to find suspicious patterns. Which employee's spending looks most like potential fraud or abuse? Return their employee_id." =>
        {:ok, "Employee 102 looks suspicious", nil, 102},
      "Use the search tool to find the policy document that covers BOTH 'remote work' AND 'expense reimbursement'. Return the document title." =>
        {:ok, "Policy WFH-2024-REIMB", nil, "Policy WFH-2024-REIMB"}
    }

    start_supervised!({MockAgent, responses})

    {:ok, mock_agent: MockAgent}
  end

  describe "run_all/1 with mock agent" do
    test "passes when all constraints are met", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

      assert is_map(result)
      assert result.passed >= 1
      assert result.total >= 1
    end

    test "skips API key check when mock agent is provided", %{mock_agent: mock_agent} do
      # This should not raise an error even without API key set
      without_api_keys(fn ->
        result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

        assert is_map(result)
        assert result.passed >= 1
      end)
    end

    test "returns results with correct structure", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

      assert Map.has_key?(result, :passed)
      assert Map.has_key?(result, :failed)
      assert Map.has_key?(result, :total)
      assert is_integer(result.passed)
      assert is_integer(result.failed)
      assert is_integer(result.total)
    end

    test "runs all common and multi-turn tests", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

      # LispTestRunner: 13 common + 1 lisp_specific + 2 multi_turn = 16 test cases
      assert result.total == 16
    end
  end

  describe "run_one/2 with mock agent" do
    test "runs a single test successfully", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_one(1, agent: mock_agent, verbose: false)

      assert is_map(result)
      assert Map.has_key?(result, :passed)
      assert Map.has_key?(result, :index)
      assert result.index == 1
    end

    test "returns nil for invalid index", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_one(999, agent: mock_agent, verbose: false)

      assert is_nil(result)
    end

    test "skips API key check for mock agent in run_one", %{mock_agent: mock_agent} do
      without_api_keys(fn ->
        result = LispTestRunner.run_one(1, agent: mock_agent, verbose: false)

        assert is_map(result)
        assert result.index == 1
      end)
    end
  end
end
