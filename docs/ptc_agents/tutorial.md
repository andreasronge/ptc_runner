# PTC SubAgents Tutorial

A practical guide to building context-efficient agentic workflows with PTC SubAgents.

> **Scope**: This SubAgent feature is demo-only (`demo/` folder), not part of the core PtcRunner library. It uses the PTC-Lisp DSL exclusively.

## What is a SubAgent?

A **SubAgent** is an isolated worker that handles a specific task using tools you provide. Think of it as a "context firewall" - the sub-agent does the heavy lifting with large datasets, then returns only what matters: a result, a summary, and small reference values for chaining.

```
┌─────────────┐                      ┌─────────────┐
│ Main Agent  │ ── "Find urgent  ──> │  SubAgent   │
│ (strategic) │     emails"          │ (isolated)  │
│             │                      │             │
│  Context:   │                      │  Has tools: │
│  ~100 tokens│                      │  - get_emails│
│             │ <── summary + ─────  │  - search   │
│             │     email_ids        │             │
└─────────────┘                      └─────────────┘
```

**Why use SubAgents?**

- **Context efficiency**: Raw email bodies might be 50KB; the summary is 100 tokens
- **Clean chaining**: Pass IDs between steps, not full objects
- **Isolation**: Each sub-agent has only the tools it needs
- **Scoped memory**: Each agent has private scratchpad (no state leaks)

---

## Architecture Overview

### The Agentic Loop

A SubAgent runs an **agentic loop** (`AgenticLoop` module) - it may execute multiple programs before completing a task:

```
┌─────────────────────────────────────────────────────────────────┐
│                        SubAgent Loop                            │
├─────────────────────────────────────────────────────────────────┤
│  Turn 1: LLM generates program → execute → get result           │
│      ↓                                                          │
│  Turn 2: LLM sees result, generates next program → execute      │
│      ↓                                                          │
│  Turn 3: LLM sees result, decides it's done → returns answer    │
└─────────────────────────────────────────────────────────────────┘
```

**Example:** "Find the top customer and their recent orders"

| Turn | LLM Action | Result |
|------|------------|--------|
| 1 | Generates: `(call "get_customers")` | Returns list of customers |
| 2 | Sees customers, generates: `(call "get_orders" {:id 1})` | Returns orders for customer #1 |
| 3 | Sees orders, responds: "Top customer is Acme with 3 orders totaling $12K" | Done (no program) |

**Key behaviors:**

- **Multiple programs**: Complex tasks may require several steps
- **Error recovery**: If a program fails, the error is fed back and the LLM can retry
- **Automatic termination**: Loop ends when the LLM responds without a program
- **Safety limit**: `max_turns` option prevents infinite loops (default: 5)

### Module Structure

```
demo/lib/ptc_demo/
├── agentic_loop.ex    # Reusable multi-turn execution logic
├── sub_agent.ex       # SubAgent.delegate/2 and as_tool/1 APIs
├── ref_extractor.ex   # Deterministic value extraction from results
└── lisp_agent.ex      # Main agent (uses AgenticLoop)
```

### Data Flow

```
                    ┌─────────────────────────────────────┐
                    │           SubAgent.delegate/2        │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │           AgenticLoop.run/4          │
                    │  • Manages conversation context      │
                    │  • Tracks tool calls per turn        │
                    │  • Accumulates token usage           │
                    │  • Records execution trace           │
                    └─────────────────────────────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
            ┌─────────────┐                    ┌─────────────┐
            │  LLM Call   │                    │PtcRunner.Lisp│
            │ (ReqLLM)    │                    │   .run/2    │
            └─────────────┘                    └─────────────┘
                                                      │
                                                      ▼
                                            ┌─────────────────┐
                                            │  Tool Execution │
                                            │  (user functions)│
                                            └─────────────────┘
                                                      │
                                                      ▼
                    ┌─────────────────────────────────────┐
                    │         RefExtractor.extract/2       │
                    │  • Path-based: [Access.at(0), :id]  │
                    │  • Function-based: &length/1         │
                    └─────────────────────────────────────┘
```

---

## Quick Start

Here's the simplest possible example - delegate a task and get a result:

```elixir
# Define tools the sub-agent can use
tools = %{
  "get_products" => fn _ ->
    [%{name: "Widget", price: 100}, %{name: "Gadget", price: 50}]
  end
}

# Delegate a task
{:ok, result} = PtcDemo.SubAgent.delegate(
  "What is the most expensive product?",
  tools: tools
)

result.result   #=> [%{name: "Widget", price: 100}, ...]
result.summary  #=> "The most expensive product is Widget at $100"
```

The sub-agent:
1. Receives your task and available tools
2. Generates a PTC-Lisp program to solve it
3. Executes the program safely in isolation
4. Returns the result with a summary

---

## Example: Email Processing Pipeline

This example shows a realistic multi-step workflow where sub-agents handle different parts of an email processing task.

```elixir
# Tools for reading emails
email_tools = %{
  "list_emails" => fn _args ->
    [%{id: 1, subject: "Urgent: Server Down", is_urgent: true},
     %{id: 2, subject: "Lunch?", is_urgent: false},
     %{id: 3, subject: "Urgent: Customer Complaint", is_urgent: true}]
  end,
  "get_email" => fn args ->
    id = args[:id] || args["id"]
    %{id: id, body: "Email body for #{id}..."}
  end
}

# Tools for drafting responses
drafting_tools = %{
  "draft_reply" => fn args ->
    email_id = args[:email_id] || args["email_id"]
    %{draft_id: 100 + email_id, status: "draft_saved"}
  end
}

# Step 1: Find urgent emails (sub-agent handles the filtering)
{:ok, step1} = PtcDemo.SubAgent.delegate(
  "Find all urgent emails",
  tools: email_tools,
  refs: %{
    email_ids: fn result -> Enum.map(result, & &1[:id]) end,
    count: &length/1
  }
)

IO.puts(step1.summary)
#=> "Found 2 urgent emails: Server Down, Customer Complaint"

step1.refs
#=> %{email_ids: [1, 3], count: 2}

# Step 2: Draft responses using only the IDs (not the full email bodies)
{:ok, step2} = PtcDemo.SubAgent.delegate(
  "Draft brief acknowledgment replies for these emails",
  tools: drafting_tools,
  context: %{email_ids: step1.refs.email_ids}
)

IO.puts(step2.summary)
#=> "Created 2 draft replies ready for review"
```

**What happened here:**
- Step 1 processed potentially large email bodies but returned only IDs and a summary
- Step 2 received just the IDs via `context`, keeping its input small
- The main agent never saw the raw email content - just summaries and IDs

---

## Core Concepts

### Tools

Tools are functions the sub-agent can call. Provide them as a map:

```elixir
tools = %{
  # Simple function
  "get_time" => fn _args -> DateTime.utc_now() end,

  # Function that uses arguments
  "search" => fn args ->
    query = args[:query] || args["query"]
    limit = args[:limit] || args["limit"] || 10
    MyApp.search(query, limit)
  end
}
```

**Note:** Tool functions receive a map of arguments. The LLM may pass keys as atoms or strings, so check both.

### Context

Pass small values (IDs, settings) to the sub-agent. These are available in PTC-Lisp as `ctx/key`:

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Get details for this order",
  tools: order_tools,
  context: %{order_id: "ORD-12345", include_history: true}
)
```

The sub-agent can access these as `ctx/order_id` and `ctx/include-history` in its PTC-Lisp program.

### Refs (Extracting Values for Chaining)

Extract specific values from results for passing to the next step:

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Find the top customer by revenue",
  tools: customer_tools,
  refs: %{
    customer_id: [Access.at(0), :id],           # Path-based extraction
    total_revenue: fn r -> r |> hd() |> Map.get(:revenue) end  # Function
  }
)

result.refs.customer_id   #=> "CUST-789"
result.refs.total_revenue #=> 125000
```

Refs are extracted deterministically by `RefExtractor` (not by the LLM), so they're reliable for chaining.

### Memory (Scoped Scratchpad)

Each agent has private memory that persists across turns within a single `delegate` call:

```elixir
# In PTC-Lisp, the agent can:
(memory/put :cached-data result)   # Store a value
(memory/get :cached-data)          # Retrieve it later
memory/cached-data                 # Shorthand access
```

**Important:** Memory is scoped per-agent. SubAgents do not share memory with their parent or siblings. This prevents state leaks and enables safe parallel execution.

---

## Using SubAgents as Tools

Wrap sub-agents as tools so a main agent can orchestrate them:

```elixir
# Create sub-agent tools
main_tools = %{
  "customer-finder" => PtcDemo.SubAgent.as_tool(
    model: "gemini",
    tools: %{
      "search_customers" => fn _args ->
        [%{id: 501, name: "Top Client", revenue: 1_000_000}]
      end
    },
    refs: %{customer_id: [Access.at(0), :id]}
  ),

  "order-fetcher" => PtcDemo.SubAgent.as_tool(
    model: "gemini",
    tools: %{
      "list_orders" => fn args ->
        cid = args[:customer_id] || args["customer_id"]
        [%{id: 901, customer_id: cid, total: 500},
         %{id: 902, customer_id: cid, total: 1200}]
      end
    }
  )
}

# Now the main agent can orchestrate these sub-agents
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Find the top customer and get their orders",
  tools: main_tools
)
```

The main agent decides which sub-agents to call and in what order. Each SubAgent call returns a map with `:result`, `:summary`, `:refs`, and `:trace`.

---

## Planning Agents

A **Planning Agent** generates a structured plan before execution. The spike validated that LLMs can generate plans as data (not prose).

### Plan Generation

Provide a `create_plan` tool and the LLM will generate a structured plan:

```elixir
planning_tools = %{
  "create_plan" => fn args ->
    # The LLM passes the plan structure as args
    IO.inspect(args, label: "Plan Created")
    %{status: "success", plan_id: "plan_123"}
  end
}

{:ok, result} = PtcDemo.SubAgent.delegate(
  """
  Create a plan to:
  1. Find all urgent emails
  2. Read their full bodies
  3. Draft acknowledgment replies

  Use the "create_plan" tool to submit your plan.
  Each step should have: :id, :task, :tools, :needs (dependencies), :output
  """,
  tools: planning_tools,
  context: %{available_tools: ["email-finder", "email-reader", "reply-drafter"]}
)
```

**Observed LLM output** (Gemini 2.5 Flash):

```elixir
%{
  goal: "Find urgent emails, read bodies, draft acknowledgments",
  steps: [
    %{id: "find_urgent_emails",
      task: "Find all urgent emails",
      tools: ["email-finder"],
      needs: [],
      output: %{urgent_emails: "List of urgent email IDs"}},
    %{id: "read_email_bodies",
      task: "Read full body for each urgent email",
      tools: ["email-reader"],
      needs: ["find_urgent_emails"],
      output: %{email_bodies: "Map of email ID to body"}},
    %{id: "draft_acknowledgments",
      task: "Draft acknowledgment for each email",
      tools: ["reply-drafter"],
      needs: ["find_urgent_emails", "read_email_bodies"],
      output: %{draft_ids: "List of draft IDs"}}
  ]
}
```

**Key observations:**
- LLM generates PTC-Lisp maps with proper structure
- Correctly identifies dependencies via `:needs`
- Proactively defines output shapes

### Executing Plans

Plan execution is done in Elixir (not PTC-Lisp). A simple executor:

```elixir
defmodule PlanExecutor do
  def run(plan, tool_registry) do
    Enum.reduce(plan.steps, %{}, fn step, context ->
      # Build context from previous steps
      step_context = Map.take(context, step.needs)

      # Get tools for this step
      tools = Map.get(tool_registry, step.tools)

      # Execute via SubAgent
      {:ok, result} = PtcDemo.SubAgent.delegate(
        step.task,
        tools: tools,
        context: step_context
      )

      # Merge extracted refs into context
      Map.merge(context, result.refs)
    end)
  end
end
```

---

## Observability

### Execution Trace

Every SubAgent delegation returns a trace showing what happened:

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(task, tools: tools)

result.trace
#=> [
#     %{iteration: 5,
#       program: "(call \"search_customers\" {:limit 1})",
#       result: [%{id: 501, name: "Top Client"}],
#       tool_calls: [
#         %{name: "search_customers", args: %{limit: 1}, result: [...]}
#       ],
#       usage: %{input_tokens: 102, output_tokens: 77}},
#     %{iteration: 4,
#       answer: "The top customer is Top Client with ID 501.",
#       usage: %{input_tokens: 211, output_tokens: 27}}
#   ]
```

### Nested Traces

When SubAgents call other SubAgents (via `as_tool`), traces nest:

```elixir
# Parent trace shows SubAgent call with embedded sub-trace
%{
  iteration: 3,
  program: "(call \"customer-finder\" {:task \"find top customer\"})",
  tool_calls: [
    %{name: "customer-finder",
      args: %{task: "find top customer"},
      result: %{
        summary: "Top customer is Top Client",
        refs: %{customer_id: 501},
        trace: [...]  # SubAgent's internal trace
      }}
  ]
}
```

### Usage Accounting

Token usage is tracked and aggregated:

```elixir
result.usage
#=> %{
#     input_tokens: 15442,
#     output_tokens: 1108,
#     total_tokens: 16550,
#     requests: 5,
#     total_runs: 4
#   }
```

---

## LLM Provider Configuration

SubAgents use `PtcDemo.ModelRegistry` to resolve model names. Set via environment variable or option:

```bash
# Environment variable
export PTC_DEMO_MODEL=gemini

# Or pass directly
{:ok, result} = PtcDemo.SubAgent.delegate(task,
  tools: tools,
  model: "gemini"
)
```

**Available aliases:**

| Alias | Model | Provider |
|-------|-------|----------|
| `gemini` | Gemini 2.5 Flash | Google / OpenRouter |
| `haiku` | Claude Haiku 4.5 | Anthropic / OpenRouter |
| `devstral` | Devstral 2512 | OpenRouter (free) |
| `deepseek` | DeepSeek V3.2 | OpenRouter |

The registry auto-selects provider based on available API keys (`GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`).

---

## API Reference

### SubAgent.delegate/2

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(task, opts)
```

**Options:**

| Option | Type | Description |
|--------|------|-------------|
| `tools` | map | Tool functions the sub-agent can call |
| `context` | map | Values accessible as `ctx/key` in the program |
| `refs` | map | Paths or functions to extract values from result |
| `model` | string | LLM model alias or full ID |

**Return value:**

```elixir
{:ok, %{
  result: term(),           # The computed result (last program output)
  summary: String.t(),      # Human-readable summary from LLM
  refs: map(),              # Extracted reference values
  usage: map(),             # Token usage statistics
  trace: [map()]            # Execution trace (all turns)
}}

# Or on error:
{:error, %{reason: term(), usage: map(), trace: [map()]}}
```

### SubAgent.as_tool/1

Wrap a SubAgent configuration as a callable tool:

```elixir
tool = PtcDemo.SubAgent.as_tool(
  model: "gemini",
  tools: %{"search" => &MyApp.search/1},
  refs: %{id: [Access.at(0), :id]}
)
```

The returned function takes `%{task: "..."}` and returns the SubAgent result.

### RefExtractor.extract/2

```elixir
refs = PtcDemo.RefExtractor.extract(result, %{
  first_id: [Access.at(0), :id],  # Path-based
  count: &length/1                 # Function-based
})
```

---

## Test Plan

This section documents the expected behavior and serves as a test specification.

### Unit Tests Required

**RefExtractor:**
```elixir
# Path-based extraction
result = [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
refs = RefExtractor.extract(result, %{first_id: [Access.at(0), :id]})
assert refs == %{first_id: 1}

# Function-based extraction
refs = RefExtractor.extract(result, %{count: &length/1})
assert refs == %{count: 2}

# Missing path returns nil
refs = RefExtractor.extract(result, %{missing: [Access.at(99), :id]})
assert refs == %{missing: nil}
```

**AgenticLoop:**
```elixir
# Single-turn completion (LLM returns answer without program)
# Multi-turn completion (LLM generates program, sees result, answers)
# Error recovery (program fails, error fed back, LLM retries)
# Max iterations reached
# Tool call recording in trace
# Usage accumulation across turns
```

**SubAgent.delegate/2:**
```elixir
# Basic delegation with tools
# Context passed to PTC-Lisp as ctx/key
# Refs extracted from result
# Trace includes tool calls
# Error returns structured fault map
```

**SubAgent.as_tool/1:**
```elixir
# Wrapped SubAgent callable with {:task "..."}
# Returns %{summary, refs, result, trace}
# Nested traces when SubAgent calls SubAgent
```

### Integration Tests (with LLM)

**Chained delegation** (spike_chained_test.exs):
- Main agent calls customer-finder SubAgent
- SubAgent returns customer ID via refs
- Main agent passes ID to order-fetcher SubAgent
- Final answer includes data from both

**Plan generation** (spike_planner_test.exs):
- LLM generates structured plan via create_plan tool
- Plan has correct step structure with :id, :task, :tools, :needs
- Dependencies correctly modeled

**Hybrid pattern** (spike_hybrid_test.exs):
- Planning phase: LLM generates text plan (no tools)
- Execution phase: LLM follows plan using tools
- Reduced turn count vs pure ad-hoc

### Known LLM Behavior Issues

From spike testing with Gemini 2.5 Flash:

1. **Missing functions**: LLM tries `(str ...)` and `(conj ...)` which don't exist in PTC-Lisp
2. **Wrong data paths**: Uses `[:result :id]` instead of `[:result 0 :id]` for lists
3. **Invalid comparators**: Uses `(sort-by :total >)` but `>` isn't a valid comparator

These should be addressed by either:
- Adding missing functions to PTC-Lisp (`str`, `conj`)
- Improving system prompts with SubAgent return structure
- Adding custom comparator support to `sort-by`

---

## Future Ideas

### CLI Commands

Interactive SubAgent commands for the demo CLI:

```
> /subagent "Find the employee with highest expenses"
[SubAgent] Executing: (-> (call "get_expenses") ...)
[SubAgent] Result: "John Smith - $12,450"

> /subagent:verbose "Find top 3 products"
[SubAgent] Shows full trace with programs and tool calls
```

### Tool Discovery

For large tool registries (50+ tools), let SubAgents discover relevant tools:

```elixir
{:ok, result} = PtcDemo.ToolDiscovery.run(
  "Analyze travel expenses for Q3",
  registry: all_company_tools  # 100+ tools
)

# Discovery agent finds and uses only: get_expenses, get_categories, sum_by
```

### Plan Persistence

Save and resume plans:

```elixir
# File-based
Plan.save(plan, "plans/workflow-001.json")
{:ok, plan} = Plan.load("plans/workflow-001.json")

# GitHub Issues (collaborative, auditable)
{:ok, plan} = Plan.from_github_issue("owner/repo", 275)
Plan.sync_to_github(plan)  # Updates issue with execution history
```

### Parallel SubAgents

Run multiple SubAgents concurrently:

```elixir
tasks = [
  {"Jira", "Summarize sprint status", jira_tools},
  {"Slack", "Check urgent mentions", slack_tools},
  {"GitHub", "List PRs needing review", github_tools}
]

results =
  tasks
  |> Task.async_stream(fn {name, task, tools} ->
    {:ok, result} = PtcDemo.SubAgent.delegate(task, tools: tools)
    {name, result.summary}
  end, max_concurrency: 3)
  |> Enum.map(fn {:ok, result} -> result end)
```

**Note:** Memory isolation (scoped scratchpad) enables safe parallel execution.

---

## Further Reading

- [Spike Summary](spike-summary.md) - Validation results and architectural decisions
- [PtcRunner Guide](../guide.md) - Core PTC-Lisp documentation
