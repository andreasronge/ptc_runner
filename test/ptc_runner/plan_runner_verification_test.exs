defmodule PtcRunner.PlanRunnerVerificationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for verification predicates in PlanRunner.

  These tests validate:
  1. Verification predicates execute after task completion
  2. Failed verification triggers on_verification_failure handling
  3. Smart retry appends diagnosis to agent prompt
  4. Synthesis gates act as implicit checkpoints
  5. data/depends provides access to upstream results

  Run with: mix test test/ptc_runner/plan_runner_verification_test.exs
  """

  alias PtcRunner.Plan
  alias PtcRunner.PlanRunner

  # Mock LLM that returns controlled JSON responses
  defp mock_llm(response) when is_binary(response) do
    fn _req -> {:ok, response} end
  end

  defp mock_llm(responses) when is_list(responses) do
    counter = :counters.new(1, [:atomics])

    fn _req ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)
      response = Enum.at(responses, idx - 1, List.last(responses))
      {:ok, response}
    end
  end

  # Mock LLM that captures requests for inspection
  defp capturing_llm(responses) when is_list(responses) do
    agent = Agent.start_link(fn -> {0, []} end) |> elem(1)

    llm = fn req ->
      {idx, _} =
        Agent.get_and_update(agent, fn {i, reqs} -> {{i, reqs}, {i + 1, reqs ++ [req]}} end)

      response = Enum.at(responses, idx, List.last(responses))
      {:ok, response}
    end

    {llm, agent}
  end

  defp get_captured_requests(agent) do
    {_, requests} = Agent.get(agent, & &1)
    requests
  end

  describe "verification predicates" do
    @tag :skip
    test "task passes when verification returns true" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "fetch data", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "get items",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: "(map? data/result)",
            on_verification_failure: :stop
          }
        ]
      }

      llm = mock_llm(~s|{"items": [1, 2, 3]}|)

      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      assert %{"items" => [1, 2, 3]} = results["fetch"]
    end

    @tag :skip
    test "task fails when verification returns false" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "fetch data", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "get items",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: "(> (count (get data/result \"items\")) 0)",
            on_verification_failure: :stop
          }
        ]
      }

      # Return empty items - verification should fail
      llm = mock_llm(~s|{"items": []}|)

      assert {:error, "fetch", %{}, {:verification_failed, "fetch", _diagnosis}} =
               PlanRunner.execute(plan, llm: llm)
    end

    @tag :skip
    test "verification failure captures diagnosis string" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "fetch data", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "get items",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: """
            (if (> (count (get data/result "items")) 0)
                true
                "Expected items but got empty list")
            """,
            on_verification_failure: :stop
          }
        ]
      }

      llm = mock_llm(~s|{"items": []}|)

      assert {:error, "fetch", %{}, {:verification_failed, "fetch", diagnosis}} =
               PlanRunner.execute(plan, llm: llm)

      assert diagnosis == "Expected items but got empty list"
    end

    @tag :skip
    test "nil verification always passes" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "task1",
            agent: "worker",
            input: "do work",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      llm = mock_llm(~s|{"result": "done"}|)

      assert {:ok, _results} = PlanRunner.execute(plan, llm: llm)
    end
  end

  describe "data/depends binding" do
    @tag :skip
    test "verification can access upstream task results" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "fetch products",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          },
          %{
            id: "filter",
            agent: "worker",
            input: "filter products",
            depends_on: ["fetch"],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            # Verify filter didn't lose items from fetch
            verification: """
            (>= (count (get data/result "items"))
                (count (get-in data/depends ["fetch" "items"])))
            """,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # fetch returns 5 items
          ~s|{"items": [1, 2, 3, 4, 5]}|,
          # filter returns 3 items (subset, should pass >= check... wait no)
          # Actually this should fail - filter has fewer items than fetch
          # Let me fix this - filter should return same or more
          ~s|{"items": [1, 2, 3, 4, 5]}|
        ])

      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      assert results["filter"]["items"] == [1, 2, 3, 4, 5]
    end

    @tag :skip
    test "verification fails when upstream comparison fails" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "fetch products",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          },
          %{
            id: "filter",
            agent: "worker",
            input: "filter products",
            depends_on: ["fetch"],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            # Verify filter preserved all items (should fail when filter drops items)
            verification: """
            (if (>= (count (get data/result "items"))
                    (count (get-in data/depends ["fetch" "items"])))
                true
                (str "Filter dropped items: expected >="
                     (count (get-in data/depends ["fetch" "items"]))
                     " got "
                     (count (get data/result "items"))))
            """,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # fetch returns 5 items
          ~s|{"items": [1, 2, 3, 4, 5]}|,
          # filter returns only 2 items (lost items - should fail)
          ~s|{"items": [1, 2]}|
        ])

      assert {:error, "filter", partial, {:verification_failed, "filter", _diagnosis}} =
               PlanRunner.execute(plan, llm: llm)

      # fetch succeeded
      assert Map.has_key?(partial, "fetch")
    end
  end

  describe "smart retry with diagnosis" do
    @tag :skip
    test "retry appends diagnosis to agent prompt" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "fetch items", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "get at least 3 items",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 3,
            critical: true,
            verification: """
            (if (>= (count (get data/result "items")) 3)
                true
                "Need at least 3 items")
            """,
            on_verification_failure: :retry
          }
        ]
      }

      {llm, agent} =
        capturing_llm([
          # First attempt: insufficient items
          ~s|{"items": [1]}|,
          # Second attempt: still insufficient
          ~s|{"items": [1, 2]}|,
          # Third attempt: success
          ~s|{"items": [1, 2, 3, 4]}|
        ])

      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      assert length(results["fetch"]["items"]) >= 3

      # Verify diagnosis was injected into retry prompts
      requests = get_captured_requests(agent)
      assert length(requests) == 3

      # Second request should contain diagnosis from first failure
      second_req = Enum.at(requests, 1)
      second_content = get_last_message_content(second_req)
      assert String.contains?(second_content, "Previous attempt failed verification")
      assert String.contains?(second_content, "Need at least 3 items")
    end

    @tag :skip
    test "retry exhaustion with critical task halts execution" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "fetch items", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "get items",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 2,
            critical: true,
            verification: "(> (count (get data/result \"items\")) 10)",
            on_verification_failure: :retry
          }
        ]
      }

      # Always return insufficient data
      llm = mock_llm(~s|{"items": [1, 2]}|)

      assert {:error, "fetch", %{}, {:verification_failed, "fetch", _}} =
               PlanRunner.execute(plan, llm: llm)
    end

    @tag :skip
    test "retry exhaustion with non-critical task skips" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "optional",
            agent: "worker",
            input: "optional work",
            depends_on: [],
            type: :task,
            on_failure: :skip,
            max_retries: 2,
            critical: false,
            verification: "(> (count (get data/result \"items\")) 10)",
            on_verification_failure: :retry
          },
          %{
            id: "required",
            agent: "worker",
            input: "required work",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # optional fails verification
          ~s|{"items": [1]}|,
          ~s|{"items": [1]}|,
          # required succeeds
          ~s|{"result": "done"}|
        ])

      # Should succeed - optional is skipped, required passes
      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      refute Map.has_key?(results, "optional")
      assert Map.has_key?(results, "required")
    end
  end

  describe "synthesis gates as checkpoints" do
    @tag :skip
    test "synthesis gate failure halts downstream tasks" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "a",
            agent: "worker",
            input: "task a",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          },
          %{
            id: "b",
            agent: "worker",
            input: "task b",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          },
          %{
            id: "gate",
            agent: "worker",
            input: "synthesize a and b",
            depends_on: ["a", "b"],
            type: :synthesis_gate,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: "(map? (get data/result \"summary\"))",
            on_verification_failure: :stop
          },
          %{
            id: "final",
            agent: "worker",
            input: "final task using gate results",
            depends_on: ["gate"],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # a succeeds
          ~s|{"result": "a done"}|,
          # b succeeds
          ~s|{"result": "b done"}|,
          # gate returns invalid data (no summary map)
          ~s|{"compressed": "data"}|
          # final should never run
        ])

      assert {:error, "gate", partial, {:verification_failed, "gate", _}} =
               PlanRunner.execute(plan, llm: llm)

      # a and b completed
      assert Map.has_key?(partial, "a")
      assert Map.has_key?(partial, "b")
      # gate failed, final never ran
      refute Map.has_key?(partial, "gate")
      refute Map.has_key?(partial, "final")
    end

    @tag :skip
    test "synthesis gate with passing verification allows downstream" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "a",
            agent: "worker",
            input: "task a",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          },
          %{
            id: "gate",
            agent: "worker",
            input: "synthesize",
            depends_on: ["a"],
            type: :synthesis_gate,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: "(map? (get data/result \"summary\"))",
            on_verification_failure: :stop
          },
          %{
            id: "final",
            agent: "worker",
            input: "final",
            depends_on: ["gate"],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # a succeeds
          ~s|{"result": "a done"}|,
          # gate returns valid summary
          ~s|{"summary": {"key": "value"}}|,
          # final succeeds
          ~s|{"final": "done"}|
        ])

      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      assert Map.has_key?(results, "a")
      assert Map.has_key?(results, "gate")
      assert Map.has_key?(results, "final")
    end
  end

  describe "on_verification_failure: :skip" do
    @tag :skip
    test "skip continues execution without task result" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "skippable",
            agent: "worker",
            input: "optional enrichment",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: false,
            verification: "(> (count (get data/result \"items\")) 5)",
            on_verification_failure: :skip
          },
          %{
            id: "required",
            agent: "worker",
            input: "required task",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      llm =
        mock_llm([
          # skippable fails verification
          ~s|{"items": [1, 2]}|,
          # required succeeds
          ~s|{"result": "done"}|
        ])

      assert {:ok, results} = PlanRunner.execute(plan, llm: llm)
      refute Map.has_key?(results, "skippable")
      assert Map.has_key?(results, "required")
    end
  end

  describe "on_verification_failure: :replan" do
    @tag :skip
    test "replan returns signal for MetaPlanner" do
      plan = %Plan{
        agents: %{"worker" => %{prompt: "work", tools: []}},
        tasks: [
          %{
            id: "fetch",
            agent: "worker",
            input: "fetch data",
            depends_on: [],
            type: :task,
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            verification: "(> (count (get data/result \"items\")) 10)",
            on_verification_failure: :replan
          }
        ]
      }

      llm = mock_llm(~s|{"items": [1, 2, 3]}|)

      assert {:replan_required, context} = PlanRunner.execute(plan, llm: llm)
      assert context.task_id == "fetch"
      assert context.diagnosis =~ "Verification failed"
      assert context.task_output == %{"items" => [1, 2, 3]}
    end
  end

  describe "Plan parsing with verification" do
    test "parses verification field from task" do
      raw = %{
        "tasks" => [
          %{
            "id" => "t1",
            "input" => "work",
            "verification" => "(map? data/result)",
            "on_verification_failure" => "retry"
          }
        ]
      }

      assert {:ok, plan} = Plan.parse(raw)
      task = hd(plan.tasks)
      assert task.verification == "(map? data/result)"
      assert task.on_verification_failure == :retry
    end

    test "defaults on_verification_failure to :stop" do
      raw = %{
        "tasks" => [
          %{
            "id" => "t1",
            "input" => "work",
            "verification" => "(map? data/result)"
          }
        ]
      }

      assert {:ok, plan} = Plan.parse(raw)
      task = hd(plan.tasks)
      assert task.on_verification_failure == :stop
    end

    test "parses replan as on_verification_failure" do
      raw = %{
        "tasks" => [
          %{
            "id" => "t1",
            "input" => "work",
            "on_verification_failure" => "replan"
          }
        ]
      }

      assert {:ok, plan} = Plan.parse(raw)
      task = hd(plan.tasks)
      assert task.on_verification_failure == :replan
    end

    test "nil verification is preserved" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "work"}
        ]
      }

      assert {:ok, plan} = Plan.parse(raw)
      task = hd(plan.tasks)
      assert task.verification == nil
    end
  end

  # Helper to extract the last message content from a request
  defp get_last_message_content(%{messages: messages}) do
    messages
    |> List.last()
    |> Map.get(:content, "")
  end

  defp get_last_message_content(_), do: ""
end
