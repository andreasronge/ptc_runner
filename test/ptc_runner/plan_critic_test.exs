defmodule PtcRunner.PlanCriticTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Plan
  alias PtcRunner.PlanCritic

  describe "static_review/1" do
    test "returns high score for well-structured plan" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Get the data"},
          %{
            "id" => "step2",
            "input" => "Process {{results.step1}}",
            "depends_on" => ["step1"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      assert critique.score >= 8
      assert critique.issues == [] or Enum.all?(critique.issues, &(&1.severity == :info))
    end

    test "detects missing synthesis gate for parallel tasks" do
      raw = %{
        "tasks" => [
          %{"id" => "r1", "input" => "Research A"},
          %{"id" => "r2", "input" => "Research B"},
          %{"id" => "r3", "input" => "Research C"},
          # 3 parallel tasks, then analysis without gate
          %{
            "id" => "analyze",
            "input" => "Analyze all",
            "depends_on" => ["r1", "r2", "r3"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      missing_gate_issues = Enum.filter(critique.issues, &(&1.category == :missing_gate))
      assert length(missing_gate_issues) > 0

      issue = hd(missing_gate_issues)
      assert String.contains?(issue.message, "parallel tasks")
      assert String.contains?(issue.recommendation, "synthesis_gate")
    end

    test "no missing gate warning when gate exists" do
      raw = %{
        "tasks" => [
          %{"id" => "r1", "input" => "Research A"},
          %{"id" => "r2", "input" => "Research B"},
          %{"id" => "r3", "input" => "Research C"},
          # Gate compresses results
          %{
            "id" => "compress",
            "input" => "Compress findings",
            "type" => "synthesis_gate",
            "depends_on" => ["r1", "r2", "r3"]
          },
          %{"id" => "analyze", "input" => "Analyze", "depends_on" => ["compress"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      missing_gate_issues = Enum.filter(critique.issues, &(&1.category == :missing_gate))
      assert missing_gate_issues == []
    end

    test "detects optimism bias for flaky operations" do
      raw = %{
        "tasks" => [
          %{
            "id" => "search",
            "input" => "Search the web for information",
            "critical" => true
            # on_failure defaults to :stop
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      optimism_issues = Enum.filter(critique.issues, &(&1.category == :optimism_bias))
      assert length(optimism_issues) > 0

      issue = hd(optimism_issues)
      assert issue.task_id == "search"
      assert String.contains?(issue.recommendation, "retry")
    end

    test "no optimism bias when retry is set" do
      raw = %{
        "tasks" => [
          %{
            "id" => "search",
            "input" => "Search the web",
            "on_failure" => "retry",
            "max_retries" => 3
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      optimism_issues = Enum.filter(critique.issues, &(&1.category == :optimism_bias))
      assert optimism_issues == []
    end

    test "detects missing dependencies" do
      raw = %{
        "tasks" => [
          %{"id" => "task1", "input" => "Do something"},
          %{"id" => "task2", "input" => "Use result", "depends_on" => ["nonexistent"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      missing_dep_issues = Enum.filter(critique.issues, &(&1.category == :missing_dependency))
      assert length(missing_dep_issues) > 0

      issue = hd(missing_dep_issues)
      assert issue.task_id == "task2"
      assert issue.severity == :critical
      assert String.contains?(issue.message, "nonexistent")
    end

    test "detects parallel explosion" do
      # Create 12 parallel tasks
      tasks =
        for i <- 1..12 do
          %{"id" => "task_#{i}", "input" => "Task #{i}"}
        end

      raw = %{"tasks" => tasks}

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      explosion_issues = Enum.filter(critique.issues, &(&1.category == :parallel_explosion))
      assert length(explosion_issues) > 0

      issue = hd(explosion_issues)
      assert issue.severity == :critical
      assert String.contains?(issue.message, "12")
    end

    test "calculates score based on issue severity" do
      # Plan with 2 critical issues
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "Search web", "critical" => true},
          %{"id" => "t2", "input" => "Fetch API data", "critical" => true}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      # Each warning = -1, should be around 8
      assert critique.score <= 8
    end

    test "detects disconnected flow - dependency not used in input" do
      raw = %{
        "tasks" => [
          %{"id" => "research", "input" => "Research topic X"},
          %{
            "id" => "analyze",
            "input" => "Analyze the data",
            "depends_on" => ["research"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      disconnected_issues = Enum.filter(critique.issues, &(&1.category == :disconnected_flow))
      assert length(disconnected_issues) > 0

      issue = hd(disconnected_issues)
      assert issue.task_id == "analyze"
      assert String.contains?(issue.message, "research")
      assert String.contains?(issue.recommendation, "{{results.")
    end

    test "no disconnected flow when dependency is used" do
      raw = %{
        "tasks" => [
          %{"id" => "research", "input" => "Research topic X"},
          %{
            "id" => "analyze",
            "input" => "Analyze the findings from {{results.research}}",
            "depends_on" => ["research"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      disconnected_issues = Enum.filter(critique.issues, &(&1.category == :disconnected_flow))
      assert disconnected_issues == []
    end

    test "no disconnected flow when dependency name mentioned in text" do
      # Weaker signal: if the task mentions the dependency name, it's probably intentional
      raw = %{
        "tasks" => [
          %{"id" => "get_user", "input" => "Get user profile"},
          %{
            "id" => "format",
            "input" => "Format the get_user result nicely",
            "depends_on" => ["get_user"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      disconnected_issues = Enum.filter(critique.issues, &(&1.category == :disconnected_flow))
      assert disconnected_issues == []
    end

    test "partial disconnected flow is info severity" do
      raw = %{
        "tasks" => [
          %{"id" => "task_a", "input" => "Do A"},
          %{"id" => "task_b", "input" => "Do B"},
          %{
            "id" => "combine",
            "input" => "Combine with {{results.task_a}}",
            "depends_on" => ["task_a", "task_b"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      disconnected_issues = Enum.filter(critique.issues, &(&1.category == :disconnected_flow))

      # Should flag task_b as unused but at info level
      assert length(disconnected_issues) == 1
      issue = hd(disconnected_issues)
      assert issue.severity == :info
      assert String.contains?(issue.message, "task_b")
    end
  end

  describe "review/2 with LLM" do
    test "combines static and LLM analysis" do
      # Simple plan without placeholders (to avoid SubAgent validation issues)
      raw = %{
        "tasks" => [
          %{"id" => "get_data", "input" => "Fetch user profile"},
          %{
            "id" => "use_data",
            "input" => "Send email to user from get_data result",
            "depends_on" => ["get_data"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      # Mock LLM that returns a data flow gap issue
      mock_llm = fn _input ->
        {:ok,
         Jason.encode!([
           %{
             "category" => "data_flow_gap",
             "severity" => "warning",
             "task_id" => "use_data",
             "message" => "get_data may not return an 'email' field",
             "recommendation" => "Ensure get_data's agent is instructed to return email"
           }
         ])}
      end

      {:ok, critique} = PlanCritic.review(plan, llm: mock_llm)

      # Should have LLM-detected issue
      llm_issues = Enum.filter(critique.issues, &(&1.category == :data_flow_gap))
      assert length(llm_issues) > 0
    end
  end

  describe "scoring" do
    test "score 10 for perfect plan" do
      raw = %{
        "tasks" => [
          %{"id" => "simple", "input" => "Do a simple task"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      # Simple plan with no flaky ops should score high
      assert critique.score >= 9
    end

    test "score drops with critical issues" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "Task 1", "depends_on" => ["missing1"]},
          %{"id" => "t2", "input" => "Task 2", "depends_on" => ["missing2"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      {:ok, critique} = PlanCritic.static_review(plan)

      # 2 critical issues = -6 points = score 4
      assert critique.score <= 5
    end
  end
end
