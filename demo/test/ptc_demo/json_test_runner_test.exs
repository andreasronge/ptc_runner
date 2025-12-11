defmodule PtcDemo.JsonTestRunnerTest do
  use ExUnit.Case, async: false

  import PtcDemo.TestHelpers

  alias PtcDemo.{JsonTestRunner, MockAgent}

  setup do
    # Define mock responses for all test queries used by JsonTestRunner
    # JsonTestRunner uses: common_test_cases + multi_turn_cases
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
      result = JsonTestRunner.run_all(agent: mock_agent, verbose: false)

      assert is_map(result)
      assert result.passed >= 1
      assert result.total >= 1
    end

    test "skips API key check when mock agent is provided", %{mock_agent: mock_agent} do
      # This should not raise an error even without API key set
      without_api_keys(fn ->
        result = JsonTestRunner.run_all(agent: mock_agent, verbose: false)

        assert is_map(result)
        assert result.passed >= 1
      end)
    end

    test "returns results with correct structure", %{mock_agent: mock_agent} do
      result = JsonTestRunner.run_all(agent: mock_agent, verbose: false)

      assert Map.has_key?(result, :passed)
      assert Map.has_key?(result, :failed)
      assert Map.has_key?(result, :total)
      assert is_integer(result.passed)
      assert is_integer(result.failed)
      assert is_integer(result.total)
    end

    test "runs multi-turn tests", %{mock_agent: mock_agent} do
      result = JsonTestRunner.run_all(agent: mock_agent, verbose: false)

      # Check if any multi-turn tests were run
      # Multi-turn tests have a :queries key
      assert result.total >= 2
    end
  end

  describe "run_one/2 with mock agent" do
    test "runs a single test successfully", %{mock_agent: mock_agent} do
      result = JsonTestRunner.run_one(1, agent: mock_agent, verbose: false)

      assert is_map(result)
      assert Map.has_key?(result, :passed)
      assert Map.has_key?(result, :index)
      assert result.index == 1
    end

    test "returns nil for invalid index", %{mock_agent: mock_agent} do
      result = JsonTestRunner.run_one(999, agent: mock_agent, verbose: false)

      assert is_nil(result)
    end

    test "skips API key check for mock agent in run_one", %{mock_agent: mock_agent} do
      without_api_keys(fn ->
        result = JsonTestRunner.run_one(1, agent: mock_agent, verbose: false)

        assert is_map(result)
        assert result.index == 1
      end)
    end
  end
end
