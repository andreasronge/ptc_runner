defmodule PtcDemo.MockAgentTest do
  use ExUnit.Case, async: false

  alias PtcDemo.MockAgent

  describe "ask/1" do
    test "returns predetermined response for known query" do
      responses = %{"How many products?" => {:ok, "500 products", nil, 500}}

      start_supervised!({MockAgent, responses})

      {:ok, answer} = MockAgent.ask("How many products?")
      assert answer == "500 products"
    end

    test "returns error for unknown query" do
      responses = %{}

      start_supervised!({MockAgent, responses})

      {:error, reason} = MockAgent.ask("Unknown question")
      assert String.contains?(reason, "Unknown query")
    end

    test "handles multiple queries" do
      responses = %{
        "Query 1" => {:ok, "Answer 1", nil, 1},
        "Query 2" => {:ok, "Answer 2", nil, 2}
      }

      start_supervised!({MockAgent, responses})

      {:ok, answer1} = MockAgent.ask("Query 1")
      assert answer1 == "Answer 1"

      {:ok, answer2} = MockAgent.ask("Query 2")
      assert answer2 == "Answer 2"
    end

    test "tracks call count" do
      responses = %{
        "Query" => {:ok, "Answer", nil, 1}
      }

      start_supervised!({MockAgent, responses})

      MockAgent.ask("Query")
      MockAgent.ask("Query")

      # Note: We don't expose call_count directly, but we can infer it from programs
      programs = MockAgent.programs()
      assert length(programs) == 2
    end
  end

  describe "reset/0" do
    test "clears state" do
      responses = %{"Query" => {:ok, "Answer", nil, 1}}

      start_supervised!({MockAgent, responses})

      MockAgent.ask("Query")
      :ok = MockAgent.reset()

      assert MockAgent.programs() == []
      assert MockAgent.last_result() == nil
    end
  end

  describe "last_program/0 and last_result/0" do
    test "tracks last executed program and result" do
      responses = %{
        "Query 1" => {:ok, "Answer 1", "program_1", 100},
        "Query 2" => {:ok, "Answer 2", "program_2", 200}
      }

      start_supervised!({MockAgent, responses})

      MockAgent.ask("Query 1")
      assert MockAgent.last_program() == "program_1"
      assert MockAgent.last_result() == 100

      MockAgent.ask("Query 2")
      assert MockAgent.last_program() == "program_2"
      assert MockAgent.last_result() == 200
    end

    test "returns nil when no program executed" do
      responses = %{}

      start_supervised!({MockAgent, responses})

      assert MockAgent.last_program() == nil
      assert MockAgent.last_result() == nil
    end
  end

  describe "programs/0" do
    test "returns list of {program, result} tuples" do
      # When no program is specified, MockAgent generates (return value) as the program
      responses = %{
        "Query 1" => {:ok, "Answer 1", nil, 1},
        "Query 2" => {:ok, "Answer 2", nil, 2}
      }

      start_supervised!({MockAgent, responses})

      MockAgent.ask("Query 1")
      MockAgent.ask("Query 2")

      programs = MockAgent.programs()
      assert length(programs) == 2
      # Programs are auto-generated as (return <value>) when nil is passed
      assert {"(return 1)", 1} in programs
      assert {"(return 2)", 2} in programs
    end

    test "returns empty list when no queries asked" do
      responses = %{}

      start_supervised!({MockAgent, responses})

      assert MockAgent.programs() == []
    end
  end

  describe "public API compatibility" do
    test "implements all required public functions" do
      responses = %{}

      start_supervised!({MockAgent, responses})

      # All these should work without raising errors
      assert MockAgent.reset() == :ok
      assert MockAgent.model() == "mock:test-model"
      assert is_list(MockAgent.stats() |> Map.keys())
      assert MockAgent.data_mode() == :schema
      assert is_list(MockAgent.context())
      assert is_binary(MockAgent.system_prompt())
      assert MockAgent.set_data_mode(:schema) == :ok
      assert MockAgent.set_model("some-model") == :ok
      assert is_map(MockAgent.list_datasets())
    end
  end
end
