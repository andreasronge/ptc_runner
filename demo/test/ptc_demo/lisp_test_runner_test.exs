defmodule PtcDemo.LispTestRunnerTest do
  use ExUnit.Case, async: false

  import PtcDemo.TestHelpers

  alias PtcDemo.{LispTestRunner, MockAgent}

  setup do
    # LispTestRunner: 13 common + 2 lisp_specific + 2 multi_turn = 17 tests
    responses = Map.merge(common_mock_responses(), lisp_specific_mock_responses())

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

      # LispTestRunner: 13 common + 4 lisp_specific + 2 multi_turn = 19 test cases
      assert result.total == 19
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
