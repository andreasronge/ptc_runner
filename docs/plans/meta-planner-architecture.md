# Meta-Planner Architecture: From Script Generation to Execution Manifests

**Status**: Research / Design
**Created**: 2025-02-03
**Related**: `test/ptc_runner/sub_agent/meta_planner_e2e_test.exs`

## Problem Statement

Current ptc_runner patterns (plan-and-execute, planner-worker-reviewer) require **hand-crafted orchestration logic** in prompts. The LLM is given explicit patterns like `do-step` and told how to structure its work.

We want to explore: **Can the LLM design its own multi-agent architecture?**

This shifts from "LLM as Coder" (generating scripts) to "LLM as DevOps Engineer" (generating deployment manifests with health checks and recovery logic).

## Research Questions

### Core Questions

1. **Planning emergence**: Does the LLM naturally create plans when needed, or does it dive in?
2. **Agent invention**: What specialized agents does it create? (researcher, reviewer, synthesizer)
3. **Verification strategies**: When does it add review steps? Always, never, or selectively?
4. **Recovery semantics**: Does it specify what happens on failure? (retry, skip, replan)
5. **Parallelism awareness**: Does it batch independent work?

### Architectural Questions

1. **Schema convergence**: Do different LLMs produce similar plan structures?
2. **Complexity calibration**: Do simple missions get simple plans?
3. **Recursive planning**: Should a spawned agent be able to invoke the MetaPlanner?
4. **Context management**: How do we prevent "context window death spiral" in long workflows?

## Current State

### What exists

- `SubAgent` with flexible prompt/tool configuration
- `SubAgent.as_tool` for nesting agents
- PTC-Lisp sandbox with tracing, journaling, tool caching
- `step-done` / `task-reset` for progress tracking
- `meta_planner_e2e_test.exs` - initial experiments with plan generation

### What's missing

- Formalized plan schema (currently free-form JSON)
- Plan executor that interprets the schema
- Adversarial plan evaluation
- Synthesis gates for context management
- Challenge-response test framework

## Proposed Architecture

### The Plan as "Kubernetes Manifest"

Instead of generating a script, the MetaPlanner generates a **deployment manifest**:

```
┌─────────────────────────────────────────────────────────────┐
│                         Plan                                 │
├─────────────────────────────────────────────────────────────┤
│ mission_analysis    │ Complexity, critical path, capabilities│
│ agent_definitions   │ "Pod specs" - prompt, tools, reliability│
│ workflow            │ Tasks with deps, verification, on_failure│
│ control_logic       │ Replan triggers, turn limits, staleness │
└─────────────────────────────────────────────────────────────┘
```

### Component Overview

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ MetaPlanner  │────▶│  PlanCritic  │────▶│  PlanRunner  │
│ (Architect)  │     │ (Adv. SRE)   │     │ (Executor)   │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │                    │
       ▼                    ▼                    ▼
   Plan JSON          Critique +           Spawned agents
   (manifest)         refinement           + event stream
```

## Detailed Design

### 1. Plan Schema (The Contract)

```elixir
defmodule PtcRunner.Plan do
  @type t :: %__MODULE__{
    mission_analysis: mission_analysis(),
    agent_definitions: %{String.t() => agent_spec()},
    workflow: [task()],
    control_logic: control_logic()
  }

  @type mission_analysis :: %{
    estimated_complexity: :trivial | :low | :medium | :high,
    critical_path: [String.t()],
    required_capabilities: [String.t()]
  }

  @type agent_spec :: %{
    system_prompt: String.t(),
    tools: [String.t()],
    reliability_weight: float(),  # 0.0-1.0
    max_turns: pos_integer()
  }

  @type task :: %{
    id: String.t(),
    agent: String.t(),  # references agent_definitions
    input: String.t() | map(),
    depends_on: [String.t()],
    parallel_group: String.t() | nil,
    verification: verification_spec() | nil,
    on_failure: :retry | :skip | :replan | :fail,
    critical: boolean()
  }

  @type verification_spec :: %{
    type: :schema_check | :llm_reviewer | :none,
    criteria: String.t() | nil
  }

  @type control_logic :: %{
    max_turns_per_phase: pos_integer(),
    replan_on_empty_result: boolean(),
    synthesis_gates: [synthesis_gate()]
  }

  @type synthesis_gate :: %{
    after_tasks: [String.t()],
    agent: String.t(),
    max_output_tokens: pos_integer()
  }
end
```

### 2. MetaPlanner (The Architect)

Multi-turn agent that thinks before architecting:

```elixir
defmodule PtcRunner.MetaPlanner do
  def generate(mission, available_tools, opts \\ []) do
    planner = SubAgent.new(
      prompt: """
      You are a Workflow Architect for a multi-agent system.

      MISSION: {{mission}}
      AVAILABLE_TOOLS: {{available_tools}}

      PHASE 1 - ANALYZE:
      - What is the complexity? (trivial/low/medium/high)
      - What capabilities are required?
      - What are the failure points?

      PHASE 2 - DESIGN AGENTS:
      - What specialized agents are needed?
      - What tools does each agent need?
      - What are their reliability characteristics?

      PHASE 3 - DESIGN WORKFLOW:
      - What tasks need to happen?
      - What are the dependencies?
      - Which tasks can run in parallel?
      - Where is verification needed?
      - What happens on failure?

      PHASE 4 - OUTPUT:
      Return the complete plan as JSON matching the schema.
      """,
      signature: "(mission :string, available_tools [:string]) -> :map",
      output: :json,
      max_turns: 1
    )

    SubAgent.run(planner,
      context: %{mission: mission, available_tools: available_tools},
      llm: opts[:llm]
    )
  end
end
```

### 3. PlanCritic (The Adversarial SRE)

Reviews plans for failure modes before execution:

```elixir
defmodule PtcRunner.PlanCritic do
  def review(plan, mission, opts \\ []) do
    critic = SubAgent.new(
      prompt: """
      You are a Senior SRE reviewing a deployment manifest. Find problems.

      MISSION: {{mission}}
      PLAN: {{plan}}

      EVALUATE EACH DIMENSION (score 0-10):

      1. SINGLE POINT OF FAILURE
         Which task, if it fails, kills everything?
         Is there a fallback?

      2. OUTPUT FORMAT COUPLING
         Does Task B assume Task A returns field X?
         Is X guaranteed by A's agent prompt?

      3. CONTEXT BUDGET
         Will any task exceed ~8K tokens of input?
         Are synthesis gates present for parallel phases?

      4. MISSING FALLBACKS
         Which critical tasks lack on_failure handlers?

      5. PARALLEL MISSES
         Are independent tasks incorrectly sequenced?

      Return:
      - scores: {dimension: 0-10}
      - issues: [{dimension, task_id, description}]
      - recommendations: [string]
      - overall_score: 0-10
      """,
      signature: "(mission :string, plan :map) -> :map",
      output: :json,
      max_turns: 1
    )

    SubAgent.run(critic,
      context: %{mission: mission, plan: Jason.encode!(plan)},
      llm: opts[:llm]
    )
  end
end
```

### 4. PlanRunner (The Executor)

Executes plans by instantiating agents and managing workflow:

```elixir
defmodule PtcRunner.PlanRunner do
  @doc """
  Executes a validated plan.

  Options:
  - llm: LLM callback for spawned agents
  - base_tools: Tool implementations to select from
  - on_event: Callback for execution events
  """
  def execute(%Plan{} = plan, opts) do
    state = %{
      results: %{},           # task_id => result
      events: [],             # execution trace
      current_phase: 0,
      replan_count: 0
    }

    # Validate plan structure
    :ok = Plan.validate(plan)

    # Group tasks by execution phase (respecting dependencies)
    phases = compute_execution_phases(plan.workflow)

    # Execute each phase
    Enum.reduce_while(phases, state, fn phase, state ->
      case execute_phase(phase, plan, state, opts) do
        {:ok, new_state} -> {:cont, new_state}
        {:replan, reason} -> handle_replan(plan, state, reason, opts)
        {:error, reason} -> {:halt, {:error, reason, state}}
      end
    end)
  end

  defp execute_phase(tasks, plan, state, opts) do
    # Group by parallel_group
    groups = Enum.group_by(tasks, & &1.parallel_group)

    # Execute groups (parallel within group, sequential across nil group)
    # Compile to PTC-Lisp for execution in sandbox
    lisp_code = compile_phase_to_lisp(groups, plan.agent_definitions)

    agents = instantiate_agents(plan.agent_definitions, opts[:base_tools], opts[:llm])

    case Lisp.run(lisp_code, tools: agents, ...) do
      {:ok, step} ->
        {:ok, merge_results(state, step)}
      {:error, step} ->
        handle_task_failure(step, plan.control_logic, state)
    end
  end
end
```

### 5. Synthesis Gates

Prevent context window overflow by forcing compression between phases:

```elixir
# In workflow definition:
%{
  workflow: [
    %{id: "r1", parallel_group: "research", ...},
    %{id: "r2", parallel_group: "research", ...},
    %{id: "r3", parallel_group: "research", ...},

    # Gate: compress before proceeding
    %{
      id: "synthesize_research",
      type: :synthesis_gate,
      inputs: ["r1", "r2", "r3"],
      agent: "synthesizer",
      max_output_tokens: 2000
    },

    %{id: "analysis", depends_on: ["synthesize_research"], ...}
  ]
}
```

## Evaluation Framework

### Metrics (replacing task_count)

```elixir
def compute_metrics(plan) do
  %{
    # Resilience: ratio of fallbacks to critical tasks
    resilience_score: fallback_coverage(plan),

    # Efficiency: parallel utilization
    parallelism_ratio: max_concurrent(plan) / length(plan.workflow),

    # Quality: prompt specificity
    prompt_precision: avg_prompt_specificity(plan.agent_definitions),

    # Risk: single points of failure
    spof_count: count_single_points_of_failure(plan),

    # Context: synthesis gate coverage
    synthesis_coverage: synthesis_gates_present?(plan)
  }
end
```

### Challenge-Response Tests

| Challenge | Scenario | Expected Plan Property |
|-----------|----------|----------------------|
| Blind Alley | Search for non-existent entity | `on_failure: :replan` or pivot strategy |
| Data Flood | Process 50 files | `parallel_group` + batching + synthesis gate |
| Unreliable Witness | Conflicting sources | Reviewer agent or conflict resolution |
| Deep Chain | A→B→C→D dependency | Correct `depends_on` + intermediate verification |
| Partial Failure | 2 of 3 sources fail | Graceful degradation, not total failure |

### Test Implementation

```elixir
describe "challenge-response" do
  test "blind alley triggers replan" do
    # Mock search that always returns empty
    mock_tools = %{"search" => fn _ -> %{results: []} end}

    {:ok, plan} = MetaPlanner.generate(
      "Research the company XyzzyCorp",
      ["search", "summarize"]
    )

    # Execute with mock
    events = PlanRunner.execute(plan, base_tools: mock_tools)
              |> collect_events()

    assert :replan in events or :pivot in events
    refute :hard_fail in events
  end
end
```

## Implementation Phases

### Phase 1: Critic Agent (Quick Win)
- Add `PlanCritic` to existing `meta_planner_e2e_test.exs`
- Generate plan → Critique → Log issues
- No execution yet, just evaluation

### Phase 2: Plan Struct + Validation
- Define `PtcRunner.Plan` struct with types
- Add validation: acyclic deps, referenced agents exist
- Parse generated JSON into struct

### Phase 3: Minimal PlanRunner
- Elixir loop that iterates phases
- Compiles each phase to PTC-Lisp
- Spawns agents from definitions
- Basic `on_failure` handling

### Phase 4: Synthesis Gates
- Add gate detection to PlanRunner
- Spawn synthesizer agents between phases
- Enforce max_output_tokens compression

### Phase 5: Challenge-Response Suite
- Mock tool infrastructure
- Event collection from PlanRunner
- Property-based assertions on plan behavior

## Open Questions

1. **Recursive MetaPlanner**: Should spawned agents be able to call MetaPlanner?
   - Proposal: No by default. Return `{:needs_decomposition, subtask}` signal instead.

2. **Plan serialization**: JSON vs Elixir terms vs PTC-Lisp?
   - Proposal: JSON for portability, convert to struct for execution.

3. **Replan limits**: How many replans before giving up?
   - Proposal: Configurable in `control_logic`, default 2.

4. **Agent caching**: Can we reuse spawned agents across tasks?
   - Proposal: Yes if same `agent_definition` key, no state carryover.

5. **Human-in-the-loop**: Where do we pause for approval?
   - Proposal: Optional gate type `:human_review` in workflow.

## Success Criteria

1. **MetaPlanner generates valid plans** for all challenge scenarios
2. **PlanCritic catches >80% of failure modes** in adversarial tests
3. **PlanRunner executes plans** with correct dependency ordering
4. **Synthesis gates prevent** context overflow in data-heavy missions
5. **Challenge-response tests pass** with appropriate resilience properties

## References

- `test/ptc_runner/sub_agent/meta_planner_e2e_test.exs` - Current experiments
- `test/ptc_runner/sub_agent/planner_worker_e2e_test.exs` - Hand-crafted pattern
- `tmp/meta_planner_summary.md` - Generated plan examples
