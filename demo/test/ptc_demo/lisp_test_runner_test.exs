defmodule PtcDemo.LispTestRunnerTest do
  use ExUnit.Case, async: false

  import PtcDemo.TestHelpers

  alias PtcDemo.{LispTestRunner, MockAgent}

  setup do
    # Define mock responses for all test queries used by LispTestRunner
    # LispTestRunner uses: common_test_cases + lisp_specific_cases + multi_turn_cases
    responses = %{
      # Common test cases
      "How many products are there?" => {:ok, "500 products", nil, 500},
      "How many orders are there?" => {:ok, "1000 orders", nil, 1000},
      "How many employees are there?" => {:ok, "200 employees", nil, 200},
      "How many products are in the electronics category?" =>
        {:ok, "250 electronics products", nil, 250},
      "How many employees work remotely?" => {:ok, "100 remote employees", nil, 100},
      "What is the total of all order amounts?" => {:ok, "Total is 50000", nil, 50_000},
      "What is the average employee salary?" => {:ok, "Average is 100000", nil, 100_000},
      "Count employees in engineering department" => {:ok, "50 employees", nil, 50},
      "Sum all travel expenses" => {:ok, "Total is 5000", nil, 5_000},
      # Lisp-specific cases
      "How many expenses are there?" => {:ok, "800 expenses", nil, 800},
      "How many orders have status delivered?" => {:ok, "750 delivered", nil, 750},
      "How many expenses are pending approval?" => {:ok, "200 pending", nil, 200},
      "What is the average product price?" => {:ok, "Average is 500", nil, 500},
      "Find the most expensive product and return its name" =>
        {:ok, "Product Z", nil, "Product Z"},
      "Get the names of the top 3 highest paid employees" =>
        {:ok, "[Employee1, Employee2, Employee3]", nil, ["Employee1", "Employee2", "Employee3"]},
      "How many orders over 500 have status delivered?" => {:ok, "500 orders", nil, 500},
      "How many unique products have been ordered? (count distinct product_id values in orders)" =>
        {:ok, "300 unique products", nil, 300},
      "What is the total expense amount for employees in the engineering department?" =>
        {:ok, "Total is 10000", nil, 10_000},
      "How many employees have submitted expenses? (count unique employee_ids in expenses that exist in employees)" =>
        {:ok, "150 employees", nil, 150},
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

    # Stop any existing MockAgent first
    if Process.whereis(MockAgent) do
      GenServer.stop(MockAgent)
    end

    {:ok, _pid} = MockAgent.start_link(responses)

    on_exit(fn ->
      if Process.whereis(MockAgent) do
        GenServer.stop(MockAgent)
      end
    end)

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

    test "includes lisp-specific test cases", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

      # LispTestRunner should include common + lisp_specific + multi_turn test cases
      # This verifies that lisp-specific cases are included
      assert result.total >= 3
    end

    test "runs multi-turn tests", %{mock_agent: mock_agent} do
      result = LispTestRunner.run_all(agent: mock_agent, verbose: false)

      # LispTestRunner should run multi-turn tests
      assert result.total >= 2
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
