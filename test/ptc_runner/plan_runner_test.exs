defmodule PtcRunner.PlanRunnerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Plan
  alias PtcRunner.PlanRunner

  describe "execute/2" do
    test "executes single task plan" do
      raw = %{
        "tasks" => [
          %{"id" => "answer", "input" => "What is 2+2?"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      # Mock LLM that returns JSON
      mock_llm = fn _input ->
        {:ok, ~s({"answer": 4})}
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      assert Map.has_key?(results, "answer")
    end

    test "executes tasks in dependency order" do
      raw = %{
        "tasks" => [
          %{
            "id" => "step2",
            "input" => "Use result from step1: {{results.step1}}",
            "depends_on" => ["step1"]
          },
          %{"id" => "step1", "input" => "Get first value"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      # Track call order
      call_order = Agent.start_link(fn -> [] end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(call_order, fn calls -> calls ++ [prompt] end)

        cond do
          String.contains?(prompt, "Get first value") ->
            {:ok, ~s({"value": "hello"})}

          String.contains?(prompt, "hello") ->
            {:ok, ~s({"combined": "hello world"})}

          true ->
            {:ok, ~s({"result": "unknown"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      calls = Agent.get(call_order, & &1)
      Agent.stop(call_order)

      # step1 should be called before step2
      assert length(calls) == 2
      assert String.contains?(hd(calls), "Get first value")
      assert String.contains?(Enum.at(calls, 1), "hello")

      assert Map.has_key?(results, "step1")
      assert Map.has_key?(results, "step2")
    end

    test "passes tools to agents that need them" do
      raw = %{
        "agents" => %{
          "searcher" => %{
            "prompt" => "You search for things",
            "tools" => ["search"]
          }
        },
        "tasks" => [
          %{"id" => "find", "agent" => "searcher", "input" => "Find X"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      search_called = Agent.start_link(fn -> false end) |> elem(1)

      search_tool = fn _args ->
        Agent.update(search_called, fn _ -> true end)
        ["result1", "result2"]
      end

      # LLM that returns PTC-Lisp code calling the tool, then returns result
      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call - return code that calls the tool
          {:ok, ~s|```clojure\n(tool/search {:query "X"})\n```|}
        else
          # After tool execution, return the final result
          {:ok, ~s|```clojure\n(return ["result1" "result2"])\n```|}
        end
      end

      {:ok, results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          base_tools: %{"search" => search_tool},
          max_turns: 3
        )

      Agent.stop(call_count)

      # Tool should have been called
      was_called = Agent.get(search_called, & &1)
      Agent.stop(search_called)

      assert was_called, "Search tool should have been called"
      assert Map.has_key?(results, "find")
    end

    test "stops on first failure" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "first"},
          %{"id" => "t2", "input" => "second", "depends_on" => ["t1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        if count == 0 do
          {:error, "LLM failure"}
        else
          {:ok, ~s({"result": "ok"})}
        end
      end

      result = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      count = Agent.get(call_count, & &1)
      Agent.stop(call_count)

      # Should stop after first failure
      assert count == 1
      assert match?({:error, "t1", _, _}, result)
    end

    test "expands result references in input" do
      raw = %{
        "tasks" => [
          %{"id" => "get_name", "input" => "What's the name?"},
          %{
            "id" => "greet",
            "input" => "Say hello to {{results.get_name.name}}",
            "depends_on" => ["get_name"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        cond do
          String.contains?(prompt, "name?") ->
            {:ok, ~s({"name": "Alice"})}

          String.contains?(prompt, "Alice") ->
            {:ok, ~s({"greeting": "Hello Alice!"})}

          true ->
            {:ok, ~s({"error": "unexpected"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      assert results["get_name"]["name"] == "Alice"
      assert results["greet"]["greeting"] == "Hello Alice!"
    end

    test "executes independent tasks in parallel" do
      raw = %{
        "tasks" => [
          %{"id" => "a", "input" => "Task A"},
          %{"id" => "b", "input" => "Task B"},
          %{"id" => "c", "input" => "Task C"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      # Track timing to verify parallel execution
      start_times = Agent.start_link(fn -> %{} end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        task_id =
          cond do
            String.contains?(prompt, "Task A") -> "a"
            String.contains?(prompt, "Task B") -> "b"
            String.contains?(prompt, "Task C") -> "c"
          end

        Agent.update(start_times, fn times ->
          Map.put(times, task_id, System.monotonic_time(:millisecond))
        end)

        # Small delay to make timing differences visible
        Process.sleep(50)
        {:ok, ~s({"task": "#{task_id}"})}
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      times = Agent.get(start_times, & &1)
      Agent.stop(start_times)

      # All tasks should have results
      assert Map.has_key?(results, "a")
      assert Map.has_key?(results, "b")
      assert Map.has_key?(results, "c")

      # Start times should be very close (within 20ms) if running in parallel
      time_values = Map.values(times)
      time_spread = Enum.max(time_values) - Enum.min(time_values)

      assert time_spread < 30,
             "Tasks should start nearly simultaneously (spread: #{time_spread}ms)"
    end

    test "skips failed task when on_failure is skip" do
      raw = %{
        "tasks" => [
          %{
            "id" => "fails",
            "input" => "This fails",
            "on_failure" => "skip",
            "critical" => false
          },
          %{"id" => "succeeds", "input" => "This succeeds"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "fails") do
          {:error, "Simulated failure"}
        else
          {:ok, ~s({"result": "ok"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      # Skipped task should not be in results, but succeeds should
      refute Map.has_key?(results, "fails")
      assert Map.has_key?(results, "succeeds")
    end

    test "retries failed task when on_failure is retry" do
      raw = %{
        "tasks" => [
          %{"id" => "flaky", "input" => "Flaky task", "on_failure" => "retry", "max_retries" => 3}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      attempt_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        count = Agent.get_and_update(attempt_count, fn n -> {n, n + 1} end)

        if count < 2 do
          {:error, "Transient failure"}
        else
          {:ok, ~s({"result": "success after retries"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      attempts = Agent.get(attempt_count, & &1)
      Agent.stop(attempt_count)

      # Should have retried and eventually succeeded
      assert attempts == 3
      assert results["flaky"]["result"] == "success after retries"
    end

    test "non-critical task failure continues execution" do
      raw = %{
        "tasks" => [
          %{"id" => "optional", "input" => "Optional", "critical" => false},
          %{"id" => "required", "input" => "Required"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "Optional") do
          {:error, "Failed"}
        else
          {:ok, ~s({"result": "done"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      # Required task should complete even though optional failed
      assert Map.has_key?(results, "required")
    end

    test "executes synthesis gate with all previous results" do
      raw = %{
        "tasks" => [
          %{"id" => "research1", "input" => "Research topic A"},
          %{"id" => "research2", "input" => "Research topic B"},
          %{
            "id" => "synthesize",
            "input" => "Summarize findings",
            "type" => "synthesis_gate",
            "depends_on" => ["research1", "research2"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      prompts_received = Agent.start_link(fn -> [] end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(prompts_received, fn ps -> ps ++ [prompt] end)

        cond do
          String.contains?(prompt, "topic A") ->
            {:ok, ~s({"finding": "A is important"})}

          String.contains?(prompt, "topic B") ->
            {:ok, ~s({"finding": "B is also important"})}

          String.contains?(prompt, "SYNTHESIS GATE") ->
            # Gate should receive previous results
            {:ok, ~s({"summary": "A and B are both important"})}

          true ->
            {:ok, ~s({"result": "unknown"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      prompts = Agent.get(prompts_received, & &1)
      Agent.stop(prompts_received)

      # Verify gate received the results
      gate_prompt = Enum.find(prompts, &String.contains?(&1, "SYNTHESIS GATE"))
      assert gate_prompt != nil, "Gate should have received SYNTHESIS GATE instruction"
      assert String.contains?(gate_prompt, "research1"), "Gate should see research1 results"
      assert String.contains?(gate_prompt, "research2"), "Gate should see research2 results"

      # Verify all results are present
      assert Map.has_key?(results, "research1")
      assert Map.has_key?(results, "research2")
      assert Map.has_key?(results, "synthesize")
      assert results["synthesize"]["summary"] == "A and B are both important"
    end

    test "synthesis gate compresses results for downstream tasks" do
      raw = %{
        "tasks" => [
          %{"id" => "data1", "input" => "Get data 1"},
          %{"id" => "data2", "input" => "Get data 2"},
          %{
            "id" => "compress",
            "input" => "Compress the data",
            "type" => "synthesis_gate",
            "depends_on" => ["data1", "data2"]
          },
          %{
            "id" => "final",
            "input" => "Use compressed data: {{results.compress}}",
            "depends_on" => ["compress"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        cond do
          String.contains?(prompt, "Get data 1") ->
            {:ok, ~s({"data": "verbose data from source 1 with lots of details"})}

          String.contains?(prompt, "Get data 2") ->
            {:ok, ~s({"data": "verbose data from source 2 with lots of details"})}

          String.contains?(prompt, "SYNTHESIS GATE") ->
            {:ok, ~s({"compressed": "key points: 1, 2"})}

          String.contains?(prompt, "key points") ->
            # Final task should see the compressed version
            {:ok, ~s({"final": "processed key points"})}

          true ->
            {:ok, ~s({"error": "unexpected prompt"})}
        end
      end

      {:ok, results} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      assert results["compress"]["compressed"] == "key points: 1, 2"
      assert results["final"]["final"] == "processed key points"
    end
  end

  describe "human review" do
    test "pauses at human review task" do
      raw = %{
        "tasks" => [
          %{"id" => "research", "input" => "Research the topic"},
          %{
            "id" => "approve",
            "input" => "Review the research findings",
            "type" => "human_review",
            "depends_on" => ["research"]
          },
          %{
            "id" => "publish",
            "input" => "Publish {{results.approve}}",
            "depends_on" => ["approve"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"findings": "important data"})}
      end

      # First execution should pause at the review
      result = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      assert {:waiting, pending_reviews, partial_results} = result
      assert length(pending_reviews) == 1

      pending = hd(pending_reviews)
      assert pending.task_id == "approve"
      assert pending.prompt == "Review the research findings"
      assert Map.has_key?(pending.context, :upstream_results)

      # Research should have completed
      assert Map.has_key?(partial_results, "research")
    end

    test "continues after review decision provided" do
      raw = %{
        "tasks" => [
          %{"id" => "draft", "input" => "Draft the document"},
          %{
            "id" => "review",
            "input" => "Approve or reject the draft",
            "type" => "human_review",
            "depends_on" => ["draft"]
          },
          %{
            "id" => "finalize",
            "input" => "Finalize based on {{results.review}}",
            "depends_on" => ["review"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        cond do
          String.contains?(prompt, "Draft") ->
            {:ok, ~s({"draft": "initial content"})}

          String.contains?(prompt, "approved") ->
            {:ok, ~s({"final": "approved content"})}

          true ->
            {:ok, ~s({"result": "ok"})}
        end
      end

      # First execution - pauses at review
      {:waiting, _pending, partial} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)
      assert Map.has_key?(partial, "draft")

      # Second execution - provide review decision
      {:ok, results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          max_turns: 1,
          reviews: %{"review" => %{"decision" => "approved", "notes" => "looks good"}}
        )

      # All tasks should complete
      assert Map.has_key?(results, "draft")
      assert Map.has_key?(results, "review")
      assert Map.has_key?(results, "finalize")

      # Review result should be the human decision
      assert results["review"]["decision"] == "approved"
    end

    test "multiple parallel human reviews" do
      raw = %{
        "tasks" => [
          %{"id" => "legal_review", "input" => "Legal review required", "type" => "human_review"},
          %{
            "id" => "finance_review",
            "input" => "Finance review required",
            "type" => "human_review"
          },
          %{
            "id" => "proceed",
            "input" => "Both approved",
            "depends_on" => ["legal_review", "finance_review"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"result": "done"})}
      end

      # Should pause with both reviews pending (they're in parallel)
      {:waiting, pending, _partial} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      assert length(pending) == 2
      task_ids = Enum.map(pending, & &1.task_id) |> Enum.sort()
      assert task_ids == ["finance_review", "legal_review"]

      # Provide both decisions
      {:ok, results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          max_turns: 1,
          reviews: %{
            "legal_review" => "approved by legal",
            "finance_review" => "approved by finance"
          }
        )

      assert results["legal_review"] == "approved by legal"
      assert results["finance_review"] == "approved by finance"
      assert Map.has_key?(results, "proceed")
    end

    test "human review receives upstream results in context" do
      raw = %{
        "tasks" => [
          %{"id" => "analyze", "input" => "Analyze the data"},
          %{
            "id" => "approve",
            "input" => "Review analysis: {{results.analyze.summary}}",
            "type" => "human_review",
            "depends_on" => ["analyze"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"summary": "key findings here"})}
      end

      {:waiting, pending, _partial} = PlanRunner.execute(plan, llm: mock_llm, max_turns: 1)

      pending_review = hd(pending)

      # Prompt should have the results expanded
      assert String.contains?(pending_review.prompt, "key findings here")

      # Context should include upstream results
      assert pending_review.context.depends_on == ["analyze"]
      assert Map.has_key?(pending_review.context.upstream_results, "analyze")
    end
  end

  describe "initial_results (replanning support)" do
    test "skips tasks already in initial_results" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Get first value"},
          %{"id" => "step2", "input" => "Get second value"},
          %{
            "id" => "step3",
            "input" => "Combine {{results.step1}} and {{results.step2}}",
            "depends_on" => ["step1", "step2"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      # Track which tasks the LLM is called for
      called_tasks = Agent.start_link(fn -> [] end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(called_tasks, fn tasks ->
          cond do
            String.contains?(prompt, "first value") -> tasks ++ ["step1"]
            String.contains?(prompt, "second value") -> tasks ++ ["step2"]
            String.contains?(prompt, "Combine") -> tasks ++ ["step3"]
            true -> tasks
          end
        end)

        {:ok, ~s({"result": "computed"})}
      end

      # Execute with step1 already completed
      {:ok, results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          max_turns: 1,
          initial_results: %{"step1" => %{"value" => "precomputed"}}
        )

      tasks_called = Agent.get(called_tasks, & &1)
      Agent.stop(called_tasks)

      # step1 should NOT have been called (it was in initial_results)
      refute "step1" in tasks_called
      # step2 and step3 should have been called
      assert "step2" in tasks_called
      assert "step3" in tasks_called

      # Results should include all tasks
      assert Map.has_key?(results, "step1")
      assert Map.has_key?(results, "step2")
      assert Map.has_key?(results, "step3")

      # step1 should have the initial_results value
      assert results["step1"] == %{"value" => "precomputed"}
    end

    test "uses initial_results values in template expansion" do
      raw = %{
        "tasks" => [
          %{"id" => "fetch", "input" => "Fetch data"},
          %{
            "id" => "process",
            "input" => "Process: {{results.fetch.data}}",
            "depends_on" => ["fetch"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      prompt_received = Agent.start_link(fn -> nil end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "Process:") do
          Agent.update(prompt_received, fn _ -> prompt end)
        end

        {:ok, ~s({"done": true})}
      end

      {:ok, _results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          max_turns: 1,
          initial_results: %{"fetch" => %{"data" => "pre-fetched data"}}
        )

      prompt = Agent.get(prompt_received, & &1)
      Agent.stop(prompt_received)

      # The prompt should contain the expanded initial_results value
      assert String.contains?(prompt, "pre-fetched data")
    end

    test "skips entire phase if all tasks completed" do
      raw = %{
        "tasks" => [
          # Phase 0: two parallel tasks
          %{"id" => "a", "input" => "Task A"},
          %{"id" => "b", "input" => "Task B"},
          # Phase 1: depends on both
          %{"id" => "c", "input" => "Combine", "depends_on" => ["a", "b"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        Agent.update(call_count, &(&1 + 1))
        {:ok, ~s({"result": "new"})}
      end

      # Execute with phase 0 already completed
      {:ok, results} =
        PlanRunner.execute(plan,
          llm: mock_llm,
          max_turns: 1,
          initial_results: %{
            "a" => %{"result" => "old_a"},
            "b" => %{"result" => "old_b"}
          }
        )

      count = Agent.get(call_count, & &1)
      Agent.stop(call_count)

      # Only task "c" should have been executed
      assert count == 1

      # Results should preserve initial values for a and b
      assert results["a"] == %{"result" => "old_a"}
      assert results["b"] == %{"result" => "old_b"}
    end
  end
end
