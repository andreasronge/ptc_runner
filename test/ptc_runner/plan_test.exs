defmodule PtcRunner.PlanTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Plan

  describe "parse/1" do
    test "parses plan with tasks key" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "agent" => "researcher", "input" => "search for X"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      assert length(plan.tasks) == 1
      assert hd(plan.tasks).id == "t1"
      assert hd(plan.tasks).agent == "researcher"
      assert hd(plan.tasks).input == "search for X"
    end

    test "parses plan with steps key" do
      raw = %{
        "steps" => [
          %{"id" => "s1", "action" => "fetch data"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      assert length(plan.tasks) == 1
      assert hd(plan.tasks).id == "s1"
      assert hd(plan.tasks).input == "fetch data"
    end

    test "parses plan with workflow key" do
      raw = %{
        "workflow" => [
          %{"id" => "w1", "query" => "what is X?"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      assert length(plan.tasks) == 1
      assert hd(plan.tasks).input == "what is X?"
    end

    test "parses nested plan.steps" do
      raw = %{
        "plan" => %{
          "steps" => [
            %{"id" => "p1", "description" => "step one"}
          ]
        }
      }

      {:ok, plan} = Plan.parse(raw)

      assert length(plan.tasks) == 1
      assert hd(plan.tasks).input == "step one"
    end

    test "parses agents map" do
      raw = %{
        "agents" => %{
          "researcher" => %{
            "prompt" => "You are a researcher",
            "tools" => ["search", "fetch"]
          }
        },
        "tasks" => []
      }

      {:ok, plan} = Plan.parse(raw)

      assert Map.has_key?(plan.agents, "researcher")
      assert plan.agents["researcher"].prompt == "You are a researcher"
      assert plan.agents["researcher"].tools == ["search", "fetch"]
    end

    test "parses workers key as agents" do
      raw = %{
        "workers" => %{
          "analyst" => %{"role" => "Analyze data"}
        },
        "tasks" => []
      }

      {:ok, plan} = Plan.parse(raw)

      assert Map.has_key?(plan.agents, "analyst")
      assert plan.agents["analyst"].prompt == "Analyze data"
    end

    test "parses dependencies" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "first"},
          %{"id" => "t2", "input" => "second", "depends_on" => ["t1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      assert t2.depends_on == ["t1"]
    end

    test "parses requires key as depends_on" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "first"},
          %{"id" => "t2", "input" => "second", "requires" => ["t1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      assert t2.depends_on == ["t1"]
    end

    test "parses after key as depends_on" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "first"},
          %{"id" => "t2", "input" => "second", "after" => ["t1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      assert t2.depends_on == ["t1"]
    end

    test "generates task ids when missing" do
      raw = %{
        "tasks" => [
          %{"input" => "first task"},
          %{"input" => "second task"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      assert Enum.at(plan.tasks, 0).id == "task_1"
      assert Enum.at(plan.tasks, 1).id == "task_2"
    end

    test "handles simple string tasks" do
      raw = %{
        "tasks" => ["do this", "then that"]
      }

      {:ok, plan} = Plan.parse(raw)

      assert length(plan.tasks) == 2
      assert Enum.at(plan.tasks, 0).input == "do this"
      assert Enum.at(plan.tasks, 1).input == "then that"
    end

    test "handles simple string agent prompt" do
      raw = %{
        "agents" => %{
          "helper" => "You are a helpful assistant"
        },
        "tasks" => []
      }

      {:ok, plan} = Plan.parse(raw)

      assert plan.agents["helper"].prompt == "You are a helpful assistant"
      assert plan.agents["helper"].tools == []
    end

    test "parses on_failure field" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "risky", "on_failure" => "skip"},
          %{"id" => "t2", "input" => "retry", "on_failure" => "retry", "max_retries" => 3},
          %{"id" => "t3", "input" => "default"},
          %{"id" => "t4", "input" => "replan", "on_failure" => "replan"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t1 = Enum.find(plan.tasks, &(&1.id == "t1"))
      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      t3 = Enum.find(plan.tasks, &(&1.id == "t3"))
      t4 = Enum.find(plan.tasks, &(&1.id == "t4"))

      assert t1.on_failure == :skip
      assert t2.on_failure == :retry
      assert t2.max_retries == 3
      assert t3.on_failure == :stop
      assert t4.on_failure == :replan
    end

    test "parses critical field" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "important", "critical" => true},
          %{"id" => "t2", "input" => "optional", "critical" => false},
          %{"id" => "t3", "input" => "default"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t1 = Enum.find(plan.tasks, &(&1.id == "t1"))
      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      t3 = Enum.find(plan.tasks, &(&1.id == "t3"))

      assert t1.critical == true
      assert t2.critical == false
      # Default is critical
      assert t3.critical == true
    end

    test "normalizes log_and_continue to skip" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "test", "on_failure" => "log_and_continue"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      assert hd(plan.tasks).on_failure == :skip
    end

    test "parses task type field" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "research", "type" => "task"},
          %{"id" => "t2", "input" => "compress", "type" => "synthesis_gate"},
          %{"id" => "t3", "input" => "default type"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t1 = Enum.find(plan.tasks, &(&1.id == "t1"))
      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      t3 = Enum.find(plan.tasks, &(&1.id == "t3"))

      assert t1.type == :task
      assert t2.type == :synthesis_gate
      # Default is :task
      assert t3.type == :task
    end

    test "normalizes gate type variations" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "x", "type" => "gate"},
          %{"id" => "t2", "input" => "x", "type" => "synthesis"},
          %{"id" => "t3", "input" => "x", "type" => "compress"},
          %{"id" => "t4", "input" => "x", "type" => "summarize"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      for task <- plan.tasks do
        assert task.type == :synthesis_gate, "Task #{task.id} should be synthesis_gate"
      end
    end

    test "normalizes human_review type variations" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "x", "type" => "human_review"},
          %{"id" => "t2", "input" => "x", "type" => "review"},
          %{"id" => "t3", "input" => "x", "type" => "approval"},
          %{"id" => "t4", "input" => "x", "type" => "human_approval"},
          %{"id" => "t5", "input" => "x", "type" => "manual"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      for task <- plan.tasks do
        assert task.type == :human_review, "Task #{task.id} should be human_review"
      end
    end

    test "parses quality_gate field" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "x", "quality_gate" => true},
          %{"id" => "t2", "input" => "x", "quality_gate" => false},
          %{"id" => "t3", "input" => "x", "quality_gate" => "true"},
          %{"id" => "t4", "input" => "x", "quality_gate" => "false"},
          %{"id" => "t5", "input" => "x"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t1 = Enum.find(plan.tasks, &(&1.id == "t1"))
      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      t3 = Enum.find(plan.tasks, &(&1.id == "t3"))
      t4 = Enum.find(plan.tasks, &(&1.id == "t4"))
      t5 = Enum.find(plan.tasks, &(&1.id == "t5"))

      assert t1.quality_gate == true
      assert t2.quality_gate == false
      assert t3.quality_gate == true
      assert t4.quality_gate == false
      assert t5.quality_gate == nil
    end

    test "string task gets quality_gate nil" do
      raw = %{"tasks" => ["do this"]}

      {:ok, plan} = Plan.parse(raw)

      assert hd(plan.tasks).quality_gate == nil
    end

    test "parses output field for explicit mode selection" do
      raw = %{
        "tasks" => [
          %{"id" => "t1", "input" => "x", "output" => "ptc_lisp"},
          %{"id" => "t2", "input" => "x", "output" => "lisp"},
          %{"id" => "t3", "input" => "x", "output" => "json"},
          %{"id" => "t4", "input" => "x"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      t1 = Enum.find(plan.tasks, &(&1.id == "t1"))
      t2 = Enum.find(plan.tasks, &(&1.id == "t2"))
      t3 = Enum.find(plan.tasks, &(&1.id == "t3"))
      t4 = Enum.find(plan.tasks, &(&1.id == "t4"))

      assert t1.output == :ptc_lisp
      assert t2.output == :ptc_lisp
      assert t3.output == :json
      # Default is nil (auto-detect based on tools)
      assert t4.output == nil
    end
  end

  describe "topological_sort/1" do
    test "sorts tasks by dependencies" do
      tasks = [
        %{id: "t3", depends_on: ["t2"], agent: "a", input: ""},
        %{id: "t1", depends_on: [], agent: "a", input: ""},
        %{id: "t2", depends_on: ["t1"], agent: "a", input: ""}
      ]

      sorted = Plan.topological_sort(tasks)
      ids = Enum.map(sorted, & &1.id)

      assert ids == ["t1", "t2", "t3"]
    end

    test "handles tasks with no dependencies" do
      tasks = [
        %{id: "a", depends_on: [], agent: "x", input: ""},
        %{id: "b", depends_on: [], agent: "x", input: ""}
      ]

      sorted = Plan.topological_sort(tasks)

      # Both should be present, order doesn't matter for independent tasks
      assert length(sorted) == 2
      assert Enum.map(sorted, & &1.id) |> Enum.sort() == ["a", "b"]
    end

    test "handles diamond dependencies" do
      tasks = [
        %{id: "d", depends_on: ["b", "c"], agent: "x", input: ""},
        %{id: "b", depends_on: ["a"], agent: "x", input: ""},
        %{id: "c", depends_on: ["a"], agent: "x", input: ""},
        %{id: "a", depends_on: [], agent: "x", input: ""}
      ]

      sorted = Plan.topological_sort(tasks)
      ids = Enum.map(sorted, & &1.id)

      # a must come first, d must come last
      assert hd(ids) == "a"
      assert List.last(ids) == "d"
    end
  end

  describe "group_by_level/1" do
    test "groups independent tasks into first phase" do
      tasks = [
        %{
          id: "a",
          depends_on: [],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "b",
          depends_on: [],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        }
      ]

      phases = Plan.group_by_level(tasks)

      assert length(phases) == 1
      assert length(hd(phases)) == 2
      assert Enum.map(hd(phases), & &1.id) |> Enum.sort() == ["a", "b"]
    end

    test "groups dependent tasks into separate phases" do
      tasks = [
        %{
          id: "a",
          depends_on: [],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "b",
          depends_on: ["a"],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "c",
          depends_on: ["b"],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        }
      ]

      phases = Plan.group_by_level(tasks)

      assert length(phases) == 3
      assert hd(phases) |> hd() |> Map.get(:id) == "a"
      assert Enum.at(phases, 1) |> hd() |> Map.get(:id) == "b"
      assert Enum.at(phases, 2) |> hd() |> Map.get(:id) == "c"
    end

    test "handles diamond pattern correctly" do
      # a -> b, c -> d (b and c can run in parallel)
      tasks = [
        %{
          id: "a",
          depends_on: [],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "b",
          depends_on: ["a"],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "c",
          depends_on: ["a"],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        },
        %{
          id: "d",
          depends_on: ["b", "c"],
          agent: "x",
          input: "",
          on_failure: :stop,
          max_retries: 1,
          critical: true
        }
      ]

      phases = Plan.group_by_level(tasks)

      assert length(phases) == 3

      # Phase 0: a
      assert hd(phases) |> Enum.map(& &1.id) == ["a"]

      # Phase 1: b and c (parallel)
      phase1_ids = Enum.at(phases, 1) |> Enum.map(& &1.id) |> Enum.sort()
      assert phase1_ids == ["b", "c"]

      # Phase 2: d
      assert Enum.at(phases, 2) |> Enum.map(& &1.id) == ["d"]
    end

    test "returns empty list for empty input" do
      assert Plan.group_by_level([]) == []
    end
  end

  describe "validate/1" do
    test "returns :ok for valid plan" do
      {:ok, plan} =
        Plan.parse(%{
          "agents" => %{"worker" => %{"prompt" => "You work"}},
          "tasks" => [
            %{"id" => "a", "agent" => "worker", "input" => "do A"},
            %{"id" => "b", "agent" => "worker", "input" => "do B", "depends_on" => ["a"]}
          ]
        })

      assert Plan.validate(plan) == :ok
    end

    test "returns :ok for plan with default agent" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "do A"}
          ]
        })

      assert Plan.validate(plan) == :ok
    end

    test "detects missing dependency" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "do A", "depends_on" => ["nonexistent"]}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert length(issues) == 1
      assert hd(issues).category == :missing_dependency
      assert hd(issues).task_id == "a"
      assert String.contains?(hd(issues).message, "nonexistent")
    end

    test "detects missing agent" do
      {:ok, plan} =
        Plan.parse(%{
          "agents" => %{"worker" => %{"prompt" => "You work"}},
          "tasks" => [
            %{"id" => "a", "agent" => "nonexistent_agent", "input" => "do A"}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert length(issues) == 1
      assert hd(issues).category == :missing_agent
      assert hd(issues).task_id == "a"
    end

    test "detects duplicate task IDs" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "first A"},
            %{"id" => "a", "input" => "second A"}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert Enum.any?(issues, &(&1.category == :duplicate_id))
    end

    test "detects simple cycle (A -> B -> A)" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "do A", "depends_on" => ["b"]},
            %{"id" => "b", "input" => "do B", "depends_on" => ["a"]}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
      cycle_issue = Enum.find(issues, &(&1.category == :cycle_detected))
      assert String.contains?(cycle_issue.message, "->")
    end

    test "detects longer cycle (A -> B -> C -> A)" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "do A", "depends_on" => ["c"]},
            %{"id" => "b", "input" => "do B", "depends_on" => ["a"]},
            %{"id" => "c", "input" => "do C", "depends_on" => ["b"]}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
    end

    test "detects self-reference (A -> A)" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "do A", "depends_on" => ["a"]}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
    end

    test "returns multiple issues when multiple problems exist" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{
              "id" => "a",
              "agent" => "nonexistent",
              "input" => "do A",
              "depends_on" => ["missing"]
            },
            %{"id" => "a", "input" => "duplicate"}
          ]
        })

      assert {:error, issues} = Plan.validate(plan)
      # Should have: duplicate_id, missing_dependency, missing_agent
      assert length(issues) >= 2
      categories = Enum.map(issues, & &1.category)

      assert :missing_dependency in categories or :missing_agent in categories or
               :duplicate_id in categories
    end

    test "rejects empty plan" do
      {:ok, plan} = Plan.parse(%{"tasks" => []})
      {:error, issues} = Plan.validate(plan)
      assert Enum.any?(issues, &(&1.category == :empty_plan))
    end

    test "allows valid DAG with multiple roots" do
      {:ok, plan} =
        Plan.parse(%{
          "tasks" => [
            %{"id" => "a", "input" => "root A"},
            %{"id" => "b", "input" => "root B"},
            %{"id" => "c", "input" => "depends on both", "depends_on" => ["a", "b"]}
          ]
        })

      assert Plan.validate(plan) == :ok
    end
  end

  describe "sanitize/1" do
    test "keeps valid signatures" do
      plan = %Plan{
        tasks: [
          %{
            id: "t1",
            input: "test",
            signature: "{name :string, age :int}",
            agent: "default",
            depends_on: [],
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            type: :task,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      {sanitized, warnings} = Plan.sanitize(plan)
      assert hd(sanitized.tasks).signature == "{name :string, age :int}"
      assert warnings == []
    end

    test "keeps valid verification predicate" do
      plan = %Plan{
        tasks: [
          %{
            id: "t1",
            input: "test",
            signature: nil,
            agent: "default",
            depends_on: [],
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            type: :task,
            verification: "(and (map? data/result) (> (count data/result) 0))",
            on_verification_failure: :stop
          }
        ]
      }

      {sanitized, warnings} = Plan.sanitize(plan)

      assert hd(sanitized.tasks).verification ==
               "(and (map? data/result) (> (count data/result) 0))"

      assert warnings == []
    end

    test "removes verification with undefined variables and adds warning" do
      plan = %Plan{
        tasks: [
          %{
            id: "t1",
            input: "test",
            signature: nil,
            agent: "default",
            depends_on: [],
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            type: :task,
            verification: "(map? result)",
            on_verification_failure: :stop
          }
        ]
      }

      {sanitized, warnings} = Plan.sanitize(plan)
      assert hd(sanitized.tasks).verification == nil
      assert length(warnings) == 1
      assert hd(warnings).category == :invalid_verification
      assert hd(warnings).message =~ "result"
    end

    test "verification with boolean? passes (builtin regression)" do
      plan = %Plan{
        tasks: [
          %{
            id: "t1",
            input: "test",
            signature: nil,
            agent: "default",
            depends_on: [],
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            type: :task,
            verification: "(boolean? data/result)",
            on_verification_failure: :stop
          }
        ]
      }

      {sanitized, warnings} = Plan.sanitize(plan)
      assert hd(sanitized.tasks).verification == "(boolean? data/result)"
      assert warnings == []
    end

    test "removes invalid signatures and adds warning" do
      plan = %Plan{
        tasks: [
          %{
            id: "t1",
            input: "test",
            signature: "{invalid_signature",
            agent: "default",
            depends_on: [],
            on_failure: :stop,
            max_retries: 1,
            critical: true,
            type: :task,
            verification: nil,
            on_verification_failure: :stop
          }
        ]
      }

      {sanitized, warnings} = Plan.sanitize(plan)
      assert hd(sanitized.tasks).signature == nil
      assert length(warnings) == 1
      assert hd(warnings).category == :invalid_signature
      assert hd(warnings).task_id == "t1"
    end
  end
end
