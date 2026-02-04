# Meta Planner: Autonomous Planning and Self-Correction

Use the Meta Planner for missions that require multi-step workflows with automatic replanning on failure. The Meta Planner generates execution plans from natural language missions and self-corrects when tasks fail verification.

## Prerequisites

- Familiarity with [SubAgent basics](subagent-getting-started.md)
- Understanding of [Navigator pattern](subagent-navigator.md) for journaled tasks

## Core Concepts

The Meta Planner operates at the **plan level**, orchestrating multiple SubAgents to accomplish a mission:

| Component | Purpose |
|-----------|---------|
| `MetaPlanner` | Generates plans from missions, creates repair plans on failure |
| `PlanExecutor` | Executes plans with automatic replanning loop |
| `PlanRunner` | Low-level plan execution (single attempt) |
| `Plan` | Struct containing tasks, agents, and dependencies |

## Quick Start

```elixir
alias PtcRunner.PlanExecutor

mission = "Fetch stock prices for AAPL and MSFT, then compare them."

result = PlanExecutor.run(mission,
  llm: llm_callback,
  available_tools: %{
    "fetch_price" => "Fetch stock price. Input: {symbol}. Output: {symbol, price}"
  },
  base_tools: %{
    "fetch_price" => &MyApp.StockAPI.fetch/1
  },
  max_total_replans: 3
)

case result do
  {:ok, results, metadata} ->
    IO.puts("Success after #{metadata.replan_count} replans")

  {:error, reason, metadata} ->
    IO.puts("Failed: #{inspect(reason)}")
end
```

## Plan Structure

The Meta Planner generates plans as JSON with this structure:

```json
{
  "agents": {
    "researcher": {
      "prompt": "You are a financial researcher.",
      "tools": ["fetch_price"]
    }
  },
  "tasks": [
    {
      "id": "fetch_aapl",
      "agent": "researcher",
      "input": "Fetch AAPL stock price",
      "verification": "(> (get data/result \"price\") 0)",
      "on_verification_failure": "replan"
    },
    {
      "id": "compare",
      "agent": "default",
      "input": "Compare prices: {{results.fetch_aapl}} vs {{results.fetch_msft}}",
      "depends_on": ["fetch_aapl", "fetch_msft"],
      "type": "synthesis_gate"
    }
  ]
}
```

### Task Types

| Type | Purpose |
|------|---------|
| (default) | Regular SubAgent execution |
| `synthesis_gate` | Consolidates results from parallel tasks |
| `human_review` | Pauses for human decision |

### Verification Predicates

Tasks can include PTC-Lisp verification predicates:

```lisp
;; Check result has required fields
(and (map? data/result)
     (get data/result "price"))

;; Return diagnosis string on failure
(if (> (get data/result "price") 0)
  true
  "Price must be positive")
```

Available bindings:
- `data/result` — Task output
- `data/input` — Task input parameters
- `data/depends` — Results from dependent tasks

### Tool Configuration

Two separate tool maps serve different purposes:

| Option | Value Type | Purpose |
|--------|------------|---------|
| `available_tools` | `%{name => description}` | Tells the **planner** what tools exist |
| `base_tools` | `%{name => function}` | Provides **executable** functions for runtime |

```elixir
PlanExecutor.run(mission,
  # Descriptions injected into planning prompt (LLM sees these)
  available_tools: %{
    "fetch_price" => "Get stock price. Input: {symbol}. Output: {symbol, price, currency}"
  },

  # Actual functions called during execution
  base_tools: %{
    "fetch_price" => &MyApp.StockAPI.fetch/1
  }
)
```

This separation allows the MetaPlanner to generate plans knowing what capabilities exist, while the actual implementations are provided separately for execution.

### Capability Registry Integration

For dynamic tool resolution and skill injection, use the Capability Registry instead of `base_tools`:

```elixir
alias PtcRunner.CapabilityRegistry.{Registry, Skill}

registry =
  Registry.new()
  |> Registry.register_base_tool("fetch_price", &MyApp.StockAPI.fetch/1,
    signature: "(symbol :string) -> {symbol :string, price :float}",
    tags: ["stocks", "finance"]
  )
  |> Registry.register_skill(
    Skill.new("european_format", "European Formatting",
      "Use comma for decimals, period for thousands.",
      applies_to: [],
      tags: ["european"]
    )
  )

PlanExecutor.run(mission,
  llm: llm_callback,
  registry: registry,
  context_tags: ["european"]  # Matches skills with "european" tag
)
```

When a registry is provided:
- Tools are resolved via `PtcRunner.CapabilityRegistry.Linker.link/3`
- Skills matching `context_tags` are injected into SubAgent system prompts
- Trial outcomes are recorded for learning (success/failure tracking)
- Falls back to `base_tools` if registry linking fails

See the [Capability Registry Architecture](../plans/tool-registry-architecture.md) for details.

### Failure Strategies

The `on_verification_failure` field controls behavior:

| Strategy | Behavior |
|----------|----------|
| `"stop"` | Fail immediately (default) |
| `"skip"` | Mark as failed, continue with other tasks |
| `"retry"` | Retry with diagnosis feedback (up to `max_retries`) |
| `"replan"` | Generate repair plan via MetaPlanner |

## Self-Correction via Replanning

When a task fails verification with `on_verification_failure: "replan"`, the executor:

1. Captures failure context (task output, diagnosis)
2. Calls `MetaPlanner.replan/4` with completed results and failure context
3. Executes the repair plan, preserving already-completed tasks
4. Repeats until success or `max_total_replans` exceeded

### Trial History (Lessons Learned)

The replanning system tracks failed attempts to prevent repeating mistakes:

```elixir
# After 2 failed attempts, the 3rd replan prompt includes:
"""
## Trial & Error History

### Attempt 1
- **Approach**: Called fetch_price with default timeout
- **Output**: {"error": "timeout"}
- **Diagnosis**: API call timed out

### Attempt 2
- **Approach**: Added retry logic with backoff
- **Output**: {"price": "unknown"}
- **Diagnosis**: Price must be a number, got string

## Self-Reflection Required
Review the approaches that FAILED above. Do NOT repeat them.
"""
```

Each `replan_record` in the history contains:
- `task_id` — Which task failed
- `approach` — Description of the attempted strategy
- `output` — Actual task output
- `diagnosis` — Why verification failed
- `timestamp` — When the attempt occurred

The LLM uses this history to adapt its strategy, avoiding approaches that already failed.

## Execution Options

```elixir
PlanExecutor.run(mission,
  llm: llm_callback,

  # Tool configuration (see explanation below)
  available_tools: %{"tool_name" => "description for planning"},
  base_tools: %{"tool_name" => &Module.function/1},

  # Capability Registry (optional, replaces base_tools filtering)
  registry: my_registry,       # CapabilityRegistry struct
  context_tags: ["european"],  # Tags for skill matching

  # Replanning limits
  max_total_replans: 3,        # Total replans across all tasks
  max_replan_attempts: 2,      # Replans per individual task
  replan_cooldown_ms: 500,     # Delay between replans

  # Execution limits
  max_turns: 3,                # Turns per SubAgent
  timeout: 60_000,             # Per-task timeout

  # Constraints (optional)
  constraints: "Use only fetch_price tool. Max 3 tasks.",

  # Events
  on_event: fn event -> IO.inspect(event) end
)
```

## Using a Predefined Plan

For more control, parse a plan and execute directly:

```elixir
alias PtcRunner.{Plan, PlanExecutor}

raw_plan = %{
  "tasks" => [
    %{
      "id" => "research",
      "input" => "Find the creator of Elixir",
      "verification" => "(string? (get data/result \"creator\"))",
      "on_verification_failure" => "replan"
    }
  ]
}

{:ok, plan} = Plan.parse(raw_plan)

result = PlanExecutor.execute(plan, "Research Elixir",
  llm: llm_callback,
  max_total_replans: 2
)
```

## Human Review Gates

Tasks with `type: "human_review"` pause execution:

```elixir
raw_plan = %{
  "tasks" => [
    %{"id" => "research", "input" => "Research topic"},
    %{
      "id" => "verify",
      "input" => "Verify: {{results.research}}",
      "type" => "human_review",
      "depends_on" => ["research"]
    },
    %{
      "id" => "report",
      "input" => "Write report",
      "depends_on" => ["verify"]
    }
  ]
}

# First execution pauses at human_review
{:waiting, pending, partial} = PlanExecutor.execute(plan, mission, opts)

# Resume with human decision
result = PlanExecutor.execute(plan, mission,
  reviews: %{"verify" => %{"approved" => true, "notes" => "Looks good"}}
)
```

## Result Structure

```elixir
case result do
  {:ok, results, metadata} ->
    # results: %{"task_id" => task_output, ...}
    # metadata.replan_count — Number of replans performed
    # metadata.execution_attempts — Total execution attempts
    # metadata.replan_history — List of replan_record
    # metadata.total_duration_ms — Total time

  {:error, reason, metadata} ->
    # reason: Error description
    # metadata: Same structure, shows what was attempted

  {:waiting, pending, metadata} ->
    # pending: List of %{task_id, prompt} awaiting human review
    # metadata.results — Partial results so far
end
```

## Tracing Execution

Use `PlanTracer` for visibility into execution:

```elixir
alias PtcRunner.PlanTracer

{:ok, tracer} = PlanTracer.start(output: :io)

result = PlanExecutor.run(mission,
  llm: llm_callback,
  on_event: PlanTracer.handler(tracer)
)

PlanTracer.stop(tracer)
```

Events include: `:plan_generated`, `:task_started`, `:task_completed`, `:verification_failed`, `:replan_started`, etc.

## Relationship to Journal System

The Meta Planner and Journal system operate at different layers:

| Layer | Component | Purpose |
|-------|-----------|---------|
| Plan | MetaPlanner + PlanExecutor | High-level workflow, replanning on verification failure |
| Task | Journal + `(task id expr)` | Low-level idempotency within SubAgent execution |

They complement each other:
- **Plan-level replanning**: Redesigns the workflow when a task fails
- **Task-level journaling**: Caches successful work, survives crashes

Use both for robust long-running workflows:

```elixir
# Plan defines the workflow structure
# Journal (via Navigator pattern) caches individual task results
result = PlanExecutor.run(mission,
  llm: llm_callback,
  journal: saved_journal  # Passed to SubAgents
)
```

## See Also

- [Navigator Pattern](subagent-navigator.md) — Journaled task execution
- [Composition Patterns](subagent-patterns.md) — Chaining and orchestration
- [Capability Registry Architecture](../plans/tool-registry-architecture.md) — Tool/skill resolution and learning
- `PtcRunner.MetaPlanner` — Plan generation API
- `PtcRunner.PlanExecutor` — Execution with replanning
- `PtcRunner.Plan` — Plan struct and parsing
- `PtcRunner.CapabilityRegistry.Linker.link/3` — Registry-based capability resolution
