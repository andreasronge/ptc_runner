# Meta-Planner Architecture

**Status**: Phase 1 (Verification) and Phase 2 (Tail Replanning) Complete
**Next Step**: E2E testing with real LLMs, then Phase 3 (Validation & Observability)

## Overview

The meta-planner enables LLMs to design multi-agent workflows as "deployment manifests" rather than hand-crafted orchestration. An LLM generates a plan (agents + tasks + dependencies), which PlanRunner executes with parallel phases and error handling.

```
LLM → Plan JSON → PlanCritic (validate) → PlanExecutor (execute + replan) → Results
```

## Current Implementation

| Component | Status | Notes |
|-----------|--------|-------|
| `Plan` | ✅ Complete | Flexible parsing of LLM variations |
| `PlanRunner` | ✅ Complete | Parallel phases, error handling, human review gates, initial_results |
| `PlanCritic` | ✅ Complete | Static analysis + optional LLM review |
| `MetaPlanner` | ✅ Complete | Repair plan generation for failed tasks |
| `PlanExecutor` | ✅ Complete | Execution loop with automatic replanning |
| Verification predicates | ✅ Complete | Lisp predicates with data/input, data/result, data/depends |

### Plan Schema

```elixir
%Plan{
  agents: %{"researcher" => %{prompt: "...", tools: ["search"]}},
  tasks: [
    %{
      id: "fetch_data",
      agent: "researcher",
      input: "Find X",
      depends_on: [],
      type: :task,              # :task | :synthesis_gate | :human_review
      on_failure: :retry,       # :stop | :skip | :retry
      max_retries: 3,
      critical: true
    }
  ]
}
```

### Execution Model

Tasks grouped by dependency level, executed in parallel phases:

```elixir
phases = Plan.group_by_level(plan.tasks)
# Phase 0: tasks with no dependencies (parallel)
# Phase 1: tasks depending on phase 0 (parallel)
# ...
```

### Task Types

| Type | Behavior |
|------|----------|
| `:task` | Run SubAgent with agent's prompt/tools |
| `:synthesis_gate` | Compress results from `depends_on` tasks only. **Implicit checkpoint** - halts downstream on failure. |
| `:human_review` | Pause execution, return `{:waiting, pending, partial_results}` |

### Error Handling

| `on_failure` | `critical: true` | `critical: false` |
|--------------|------------------|-------------------|
| `:stop` | Halt execution | Log and continue |
| `:skip` | Log and continue | Log and continue |
| `:retry` | Retry with diagnosis → halt if exhausted | Retry with diagnosis → skip if exhausted |

### Static Analysis (PlanCritic)

| Check | Severity | Condition |
|-------|----------|-----------|
| `:missing_gate` | warning | ≥3 parallel tasks without downstream synthesis |
| `:parallel_explosion` | critical | >10 parallel tasks |
| `:optimism_bias` | warning | Flaky operation with `critical: true` |
| `:missing_dependency` | critical | Depends on non-existent task |
| `:disconnected_flow` | warning | Dependency declared but not used in input |

---

## Phase 1: Verification Predicates

**Goal**: Tasks specify how their output should be validated using PTC-Lisp.

**E2E Validation**: LLMs generate valid predicates (100% success rate in tests).

### Three-Layer Model

| Layer | Mechanism | Cost | When |
|-------|-----------|------|------|
| Schema | Signature output schema | Free | Always (existing) |
| Predicate | Lisp expression | Cheap | Always |
| LLM Review | Separate agent review | Expensive | Critical tasks |

### Task Schema Extension

```elixir
%{
  # existing fields...
  verification: "(and (map? data/result) (> (count (get data/result \"items\")) 0))",
  on_verification_failure: :retry  # :stop | :skip | :retry | :replan
}
```

### Predicate Bindings

```lisp
;; Available bindings
data/input    ;; task's input
data/result   ;; task's output
data/depends  ;; map of depends_on task_id => result

;; Return values
true                           ;; passed
"Expected 5+ items, got 2"     ;; failed with diagnosis
false                          ;; failed (generic)
```

### Predicate Examples

```lisp
;; BAD - hardcoded expectation
(= (get data/result "city") "Tokyo")

;; GOOD - references input
(= (get data/result "city") (get data/input "city"))

;; GOOD - compare against upstream task result
(>= (count (get data/result "items"))
    (count (get-in data/depends ["fetch_products" "items"])))

;; GOOD - diagnosis string on failure
(if (> (count (get data/result "items")) 0)
    true
    (str "Expected items, got " (count (get data/result "items"))))
```

### Failure Handling: Retry vs Replan

| Strategy | Behavior | Cost | Use When |
|----------|----------|------|----------|
| `:retry` | Re-run agent with diagnosis feedback | Cheap | Recoverable errors (wrong format, missing fields) |
| `:replan` | Return to MetaPlanner for structural changes | Expensive | Fundamental approach is wrong |

**Smart Retry**: When `:retry` is triggered, the diagnosis is appended to the agent's prompt:

```
Previous attempt failed verification: "Expected 5+ items, got 2"
Adjust your approach to satisfy this requirement.
```

Most verification failures are recoverable with feedback. Reserve `:replan` for cases where the task itself is misconceived.

### Synthesis Gates as Checkpoints

Synthesis gates are **implicit checkpoints**. If a synthesis gate fails (execution error or verification failure), downstream tasks are not run. This prevents "garbage in, garbage out" cascades.

Rationale: Synthesis gates aggregate results from multiple upstream tasks. If aggregation fails, all downstream consumers would receive invalid data.

### Implementation

Add to `PlanRunner.execute_task/3`:

```elixir
defp execute_task(task, results, opts) do
  case run_sub_agent(task, results, opts) do
    {:ok, output} ->
      case run_verification(task, output, results) do
        :passed -> {:ok, output}
        {:failed, diagnosis} -> handle_verification_failure(task, output, diagnosis, opts)
      end
    error -> error
  end
end

defp run_verification(%{verification: nil}, _output, _results), do: :passed
defp run_verification(%{verification: predicate} = task, output, results) do
  # Build depends map from task's depends_on
  depends = Map.take(results, task.depends_on)

  bindings = %{
    "input" => task.input,
    "result" => output,
    "depends" => depends
  }

  case Lisp.run(predicate, context: bindings, timeout: 1000) do
    {:ok, %{return: true}} -> :passed
    {:ok, %{return: diagnosis}} when is_binary(diagnosis) -> {:failed, diagnosis}
    {:ok, %{return: false}} -> {:failed, "Verification failed"}
    {:error, step} -> {:error, {:verification_error, step.fail}}
  end
end

defp handle_verification_failure(task, output, diagnosis, opts) do
  case task.on_verification_failure do
    :stop -> {:error, {:verification_failed, task.id, diagnosis}}
    :skip -> {:skipped, diagnosis}
    :retry -> retry_with_diagnosis(task, diagnosis, opts)
    :replan -> {:replan_required, %{task_id: task.id, output: output, diagnosis: diagnosis}}
  end
end

defp retry_with_diagnosis(task, diagnosis, opts) do
  # Append diagnosis to task input for next attempt
  feedback = """
  Previous attempt failed verification: "#{diagnosis}"
  Adjust your approach to satisfy this requirement.
  """
  updated_task = %{task | input: task.input <> "\n\n" <> feedback}
  # ... retry logic with max_retries tracking
end
```

---

## Phase 2: Tail Replanning

**Status**: ✅ Complete

**Goal**: When `:replan` is triggered, redesign the workflow from that point forward.

### Architecture

```
PlanExecutor.execute(plan, mission, opts)
    │
    ├── PlanRunner.execute(plan, initial_results: completed)
    │       │
    │       ├── Skip tasks in initial_results
    │       └── Execute remaining tasks
    │               │
    │               └── {:replan_required, context} if verification fails
    │
    ├── MetaPlanner.replan(mission, completed, failure_context)
    │       │
    │       └── Generate repair plan via LLM
    │
    └── Loop until success or max_replans exceeded
```

### PlanRunner Skip-if-Present

The `initial_results` option allows PlanRunner to skip already-completed tasks:

```elixir
PlanRunner.execute(plan,
  llm: my_llm,
  initial_results: %{"step1" => cached_result}  # skip step1
)
```

### MetaPlanner.replan/4

```elixir
{:ok, repair_plan} = MetaPlanner.replan(
  mission,
  completed_results,
  %{task_id: "fetch", task_output: bad_result, diagnosis: "count < 5"},
  llm: my_llm
)
```

The repair plan includes completed task IDs (so they're skipped) and redesigns the failed task.

### PlanExecutor

High-level orchestrator that handles the replan loop:

```elixir
{:ok, metadata} = PlanExecutor.execute(plan, mission,
  llm: my_llm,
  max_replan_attempts: 3,    # per task
  max_total_replans: 5,      # per execution
  replan_cooldown_ms: 1000
)

# metadata includes:
# - results: final task results
# - replan_count: how many replans occurred
# - execution_attempts: total execution attempts
# - replan_history: [{task_id, diagnosis, ...}, ...]
```

---

## Phase 3: Validation & Observability

- `Plan.validate/1` with cycle detection and agent reference checks
- `on_event` callback for execution tracing
- Token counting for synthesis gate output

---

## API Reference

### Plan.parse/1

```elixir
{:ok, plan} = Plan.parse(%{
  "agents" => %{"worker" => %{"prompt" => "..."}},
  "tasks" => [%{"id" => "t1", "agent" => "worker", "input" => "..."}]
})
```

Handles variations: `tasks`/`steps`/`workflow`, `depends_on`/`requires`/`after`, etc.

### PlanRunner.execute/2

```elixir
{:ok, results} = PlanRunner.execute(plan,
  llm: fn req -> {:ok, "response"} end,
  base_tools: %{"search" => &search/1},
  timeout: 30_000,
  max_turns: 5,
  max_concurrency: 10
)

# Human review pause/resume
{:waiting, pending, partial} = PlanRunner.execute(plan, llm: llm)
{:ok, results} = PlanRunner.execute(plan, llm: llm, reviews: %{"review_id" => decision})
```

### PlanCritic.review/2

```elixir
{:ok, critique} = PlanCritic.static_review(plan)
# => %{score: 7, issues: [...], summary: "...", recommendations: [...]}

{:ok, critique} = PlanCritic.review(plan, llm: llm)  # with LLM analysis
```

### MetaPlanner.replan/4

```elixir
{:ok, repair_plan} = MetaPlanner.replan(
  "Original mission description",
  %{"step1" => result1, "step2" => result2},  # completed results
  %{task_id: "step3", task_output: bad_output, diagnosis: "Price must be positive"},
  llm: my_llm,
  timeout: 30_000
)
```

### PlanExecutor.execute/3

```elixir
{:ok, metadata} = PlanExecutor.execute(plan, mission,
  llm: my_llm,
  base_tools: %{"search" => &search/1},
  max_replan_attempts: 3,
  max_total_replans: 5
)

# metadata = %{
#   results: %{"task1" => ..., "task2" => ...},
#   replan_count: 1,
#   execution_attempts: 2,
#   total_duration_ms: 15000,
#   replan_history: [%{task_id: "task2", diagnosis: "...", ...}]
# }
```

---

## Test Coverage

- `test/ptc_runner/plan_test.exs` - Parsing, topological sort, verification fields
- `test/ptc_runner/plan_runner_test.exs` - Execution, parallel phases, gates, initial_results, verification
- `test/ptc_runner/plan_executor_test.exs` - Replan loop, max attempts, error handling
- `test/ptc_runner/plan_critic_test.exs` - Static analysis, scoring
- `test/ptc_runner/sub_agent/meta_planner_e2e_test.exs` - E2E tests with real LLM
