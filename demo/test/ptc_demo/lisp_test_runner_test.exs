defmodule PtcDemo.LispTestRunnerTest do
  use ExUnit.Case, async: false

  import PtcDemo.TestHelpers

  alias PtcDemo.{LispTestRunner, MockAgent}

  setup do
    # Define mock responses for all test queries used by LispTestRunner
    # LispTestRunner uses: common_test_cases (12 tests) + multi_turn_cases (2 tests)
    # (lisp_specific_cases is now empty - all tests unified into common)
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
      "What is the average salary of senior-level employees?" =>
        {:ok, "Average is 150000", nil, 150_000},
      "How many unique products have been ordered? (count distinct product_id values in orders)" =>
        {:ok, "300 unique products", nil, 300},
      # Multi-turn cases
      "Count delivered orders and store the result in memory as delivered-count" =>
        {:ok, "750 delivered orders", nil, 750},
      "What percentage of all orders are delivered? Use memory/delivered-count and total order count." =>
        {:ok, "75 percent", nil, 75},
      "Store the list of employees in the engineering department in memory as engineering-employees" =>
        {:ok, "Stored employee list", nil, ["Employee1", "Employee2"]},
      "What is the average salary of the engineering employees stored in memory?" =>
        {:ok, "Average salary is 100000", nil, 100_000}
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

      # LispTestRunner should include 12 common + 2 multi_turn = 14 test cases
      assert result.total == 14
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
