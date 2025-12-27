# PTC SubAgents Tutorial

A practical guide to building context-efficient agentic workflows with PTC SubAgents.

> **API Location**: `PtcRunner.SubAgent` (core library)
> **Specification**: See [specification.md](specification.md) for full API reference
> **Demo helpers**: `PtcDemo.LLM` and `PtcDemo.ModelRegistry` provide ReqLLM integration

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
lib/ptc_runner/
├── sub_agent.ex              # Main API: delegate/2, as_tool/1
└── sub_agent/
    ├── loop.ex               # Multi-turn agentic execution
    ├── ref_extractor.ex      # Deterministic value extraction
    └── prompt.ex             # System prompt generation

demo/lib/ptc_demo/
├── llm.ex                    # ReqLLM helpers (convenience)
├── model_registry.ex         # Model aliases and provider selection
└── lisp_agent.ex             # Example agent using SubAgent
```

### Data Flow

```
                    ┌─────────────────────────────────────┐
                    │     PtcRunner.SubAgent.delegate/2    │
                    └─────────────────────────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────┐
                    │      PtcRunner.SubAgent.Loop.run/2   │
                    │  • Manages conversation context      │
                    │  • Tracks tool calls per turn        │
                    │  • Accumulates usage statistics      │
                    │  • Records execution trace           │
                    └─────────────────────────────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
            ┌─────────────┐                    ┌─────────────┐
            │ LLM Callback │                   │PtcRunner.Lisp│
            │ (user-provided)│                 │   .run/2    │
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
                    │  PtcRunner.SubAgent.RefExtractor     │
                    │  • Path-based: [Access.at(0), :id]  │
                    │  • Function-based: &length/1         │
                    └─────────────────────────────────────┘
```

---

## Primitives

The SubAgent system provides a small set of composable primitives. Everything else—orchestration patterns, planning strategies, dynamic agent creation—is built from these.

| Primitive | Purpose | Location |
|-----------|---------|----------|
| `delegate/2` | Run a task with tools in isolation | `PtcRunner.SubAgent` |
| `as_tool/1` | Wrap a SubAgent config as a callable tool | `PtcRunner.SubAgent` |
| `RefExtractor.extract/2` | Deterministically pull values from results | `PtcRunner.SubAgent.RefExtractor` |
| `Loop.run/2` | Multi-turn agentic execution engine | `PtcRunner.SubAgent.Loop` |
| `memory/put`, `memory/get` | Per-agent state (scoped, private) | PTC-Lisp builtins |

**Design philosophy**: The library provides primitives, not patterns. You compose primitives into whatever orchestration pattern fits your use case. The patterns shown later in this tutorial are examples, not prescriptions.

```
┌─────────────────────────────────────────────────────────────────┐
│                         Primitives                               │
│                                                                  │
│   delegate/2 ──── Run task in isolation                         │
│   as_tool/1  ──── Make SubAgent callable as a tool              │
│   RefExtractor ── Extract values from results                   │
│   Loop ───────── Multi-turn execution                           │
│   memory/* ───── Per-agent state                                │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                    Patterns (you build)                          │
│                                                                  │
│   Hybrid ─────────── Plan then execute (prompt pattern)         │
│   PlanExecutor ───── Iterate over plan-as-data                  │
│   spawn_agent ────── Dynamic SubAgent creation                  │
│   Pre-defined ────── as_tool for known domains                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

Here's the simplest possible example - delegate a task and get a result:

```elixir
# 1. Create an LLM callback (you provide the integration)
llm = fn %{system: system, messages: messages} ->
  # Call your LLM provider here
  # Return {:ok, "response"} or {:error, reason}
  MyLLM.chat(system, messages)
end

# Or use the demo helper with ReqLLM:
# llm = PtcDemo.LLM.callback("gemini")

# 2. Define tools the sub-agent can use
tools = %{
  "get_products" => fn _args ->
    [%{name: "Widget", price: 100}, %{name: "Gadget", price: 50}]
  end
}

# 3. Delegate a task
{:ok, result} = PtcRunner.SubAgent.delegate(
  "What is the most expensive product?",
  llm: llm,
  tools: tools
)

result.result   #=> [%{name: "Widget", price: 100}, ...]
result.summary  #=> "The most expensive product is Widget at $100"
```

The sub-agent:
1. Receives your task, LLM callback, and available tools
2. Generates a PTC-Lisp program to solve it
3. Executes the program safely in isolation
4. Returns the result with a summary

---

## Example: Email Processing Pipeline

This example shows a realistic multi-step workflow where sub-agents handle different parts of an email processing task.

```elixir
# Setup LLM callback (once)
llm = PtcDemo.LLM.callback("gemini")  # Or your own callback

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
{:ok, step1} = PtcRunner.SubAgent.delegate(
  "Find all urgent emails",
  llm: llm,
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
{:ok, step2} = PtcRunner.SubAgent.delegate(
  "Draft brief acknowledgment replies for these emails",
  llm: llm,
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
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Get details for this order",
  llm: llm,
  tools: order_tools,
  context: %{order_id: "ORD-12345", include_history: true}
)
```

The sub-agent can access these as `ctx/order_id` in its PTC-Lisp program.

#### `ctx/last-result`

In a multi-turn agentic loop, you can access the result of the *most recent* program's execution using `ctx/last-result`:

```clojure
(let [urgent-emails (filter (where :is_urgent) (ctx/last-result))]
  (mapv (fn [e] (call "read_email" {:id (:id e)})) urgent-emails))
```

This is the primary way agents chain transformations across turns without parent intervention.

### Refs (Extracting Values for Chaining)

Extract specific values from results for passing to the next step:

```elixir
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Find the top customer by revenue",
  llm: llm,
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

### Hardened Lisp for Agents

The spike implemented several features to support common LLM patterns:

#### Sequential Execution (`do`)
Group multiple expressions for side effects. Only the last expression's result is returned.
```clojure
(do
  (memory/put :step1 result)
  (call "cleanup" {}))
```

#### Multiple Body Expressions
`let` and `fn` blocks now support multiple body expressions, implicitly wrapped in a `do` block.

#### Multi-Arity `map` and `mapv`
Apply a function to elements from multiple collections simultaneously:
```clojure
(mapv (fn [email body] (assoc email :body body))
      emails
      bodies)
```

#### Keywords as Functions
Look up keys in maps using the keyword itself as a function:
```clojure
(mapv :id urgent-emails) ; Equivalent to (mapv (fn [e] (:id e)) ...)
```

---

## Using SubAgents as Tools

Wrap sub-agents as tools so a main agent can orchestrate them:

```elixir
llm = PtcDemo.LLM.callback("gemini")  # Or your own callback

# Create sub-agent tools
main_tools = %{
  "customer-finder" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: %{
      "search_customers" => fn _args ->
        [%{id: 501, name: "Top Client", revenue: 1_000_000}]
      end
    },
    refs: %{customer_id: [Access.at(0), :id]}
  ),

  "order-fetcher" => PtcRunner.SubAgent.as_tool(
    llm: llm,
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
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Find the top customer and get their orders",
  llm: llm,
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

{:ok, result} = PtcRunner.SubAgent.delegate(
  """
  Create a plan to:
  1. Find all urgent emails
  2. Read their full bodies
  3. Draft acknowledgment replies

  Use the "create_plan" tool to submit your plan.
  Each step should have: :id, :task, :tools, :needs (dependencies), :output
  """,
  llm: llm,
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
  def run(plan, tool_registry, llm) do
    Enum.reduce(plan.steps, %{}, fn step, context ->
      # Build context from previous steps
      step_context = Map.take(context, step.needs)

      # Get tools for this step
      tools = Map.get(tool_registry, step.tools)

      # Execute via SubAgent
      {:ok, result} = PtcRunner.SubAgent.delegate(
        step.task,
        llm: llm,
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

## Orchestration Patterns

These patterns are built from the primitives. They're examples, not prescriptions—compose your own patterns as needed.

### Pattern 1: Dynamic SubAgent Creation (spawn_agent)

Let the LLM create SubAgents on-the-fly by providing a meta-tool:

```elixir
# Tool catalog - all available tool sets
tool_catalog = %{
  "email" => %{
    "list_emails" => fn args -> ... end,
    "read_email" => fn args -> ... end
  },
  "calendar" => %{
    "find_slots" => fn args -> ... end,
    "create_meeting" => fn args -> ... end
  },
  "crm" => %{
    "get_customer" => fn args -> ... end,
    "update_customer" => fn args -> ... end
  }
}

# Meta-tool: LLM can spawn agents with any tool combination
tools = %{
  "spawn_agent" => fn args ->
    # LLM specifies: task, which tool sets, optional context
    tool_names = args["tools"] || []
    selected_tools = tool_names
      |> Enum.flat_map(&Map.get(tool_catalog, &1, %{}))
      |> Map.new()

    {:ok, result} = PtcRunner.SubAgent.delegate(
      args["task"],
      llm: llm,
      tools: selected_tools,
      context: args["context"] || %{}
    )

    # Return summary and refs to parent
    %{summary: result.summary, refs: result.refs}
  end
}

# Now the LLM can dynamically create specialized agents:
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Find urgent emails, then schedule follow-up meetings for each",
  llm: llm,
  tools: tools
)

# The LLM might generate:
# (let [emails (call "spawn_agent" {:task "Find urgent emails"
#                                   :tools ["email"]})
#       meetings (call "spawn_agent" {:task "Schedule meetings"
#                                     :tools ["calendar"]
#                                     :context {:email_ids (:refs emails)}})]
#   {:emails emails :meetings meetings})
```

**When to use**: Exploratory tasks, user-defined automation, when you can't predict which tool combinations are needed.

### Pattern 2: Pre-defined SubAgents

Wrap known SubAgent configurations as tools upfront:

```elixir
# Pre-defined SubAgents for known domains
tools = %{
  "email-agent" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: email_tools,
    refs: %{email_ids: [Access.all(), :id]}
  ),

  "calendar-agent" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: calendar_tools,
    refs: %{meeting_ids: [Access.all(), :id]}
  )
}

# LLM uses pre-defined agents
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Find urgent emails and schedule follow-ups",
  llm: llm,
  tools: tools
)
```

**When to use**: Production systems, well-defined domains, when you want predictable behavior and controlled tool access.

### Pattern 3: Hybrid (Plan → Execute)

A prompt pattern where the agent plans before executing. This is just two `delegate/2` calls:

```elixir
defmodule MyPatterns do
  @doc """
  Hybrid pattern: Plan first, then execute with plan as context.

  This is a prompt engineering pattern, not a library feature.
  Validated to reduce turn counts by 50-70% for complex tasks.
  """
  def hybrid(task, opts) do
    llm = Keyword.fetch!(opts, :llm)
    tools = Keyword.fetch!(opts, :tools)

    # Phase 1: Planning (no tools)
    {:ok, plan} = PtcRunner.SubAgent.delegate(
      """
      Task: #{task}

      Think through your approach. What steps are needed?
      How can you batch operations for efficiency?
      Output a numbered plan. Do NOT execute yet.
      """,
      llm: llm,
      tools: %{}  # No tools - just thinking
    )

    # Phase 2: Execute with plan as guidance
    PtcRunner.SubAgent.delegate(
      """
      Execute: #{task}

      Your plan:
      #{plan.result}

      Follow your plan, adapting as needed. Batch operations with mapv/filter.
      """,
      llm: llm,
      tools: tools,
      context: Keyword.get(opts, :context, %{})
    )
  end
end
```

**When to use**: Complex multi-item tasks, when pure ad-hoc execution leads to item-by-item processing.

### Pattern 4: PlanExecutor (Deterministic)

Use LLM to generate a plan, then execute deterministically in Elixir:

```elixir
defmodule PlanExecutor do
  @doc """
  Execute a structured plan generated by an LLM.
  Each step runs as a SubAgent delegation.
  """
  def run(plan, tool_registry, llm) do
    Enum.reduce(plan.steps, %{}, fn step, context ->
      # Get tools for this step
      tools = step.tools
        |> Enum.flat_map(&Map.get(tool_registry, &1, %{}))
        |> Map.new()

      # Build context from previous steps
      step_context = Map.take(context, step.needs || [])

      # Execute step
      {:ok, result} = PtcRunner.SubAgent.delegate(
        step.task,
        llm: llm,
        tools: tools,
        context: step_context
      )

      # Merge refs into context for next step
      Map.merge(context, result.refs || %{})
    end)
  end
end

# Usage: First, have LLM generate a plan structure
# Then execute it deterministically
plan = %{
  steps: [
    %{id: :find_emails, task: "Find urgent emails",
      tools: [:email], needs: []},
    %{id: :draft_replies, task: "Draft acknowledgments",
      tools: [:email], needs: [:email_ids]}
  ]
}

result = PlanExecutor.run(plan, tool_registry, llm)
```

**When to use**: Workflows needing retries, parallelism, or checkpointing. Production pipelines where you need deterministic execution order.

### Choosing a Pattern

| Task Type | Pattern | Why |
|-----------|---------|-----|
| Simple query | Direct `delegate/2` | One tool call, no orchestration needed |
| 2-3 step chain | Pre-defined SubAgents | Known flow, predictable behavior |
| Complex multi-item | Hybrid | LLM plans batching strategy |
| Novel/exploratory | Dynamic spawn_agent | Flexibility to compose tools |
| Production pipeline | PlanExecutor | Deterministic, retry-able, auditable |

All patterns compose from the same primitives: `delegate/2`, `as_tool/1`, `RefExtractor`, and `memory/*`.

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

See [specification.md](specification.md) for full type definitions.

### PtcRunner.SubAgent.delegate/2

```elixir
{:ok, result} = PtcRunner.SubAgent.delegate(task, opts)
```

**Required Options:**

| Option | Type | Description |
|--------|------|-------------|
| `llm` | function | LLM callback `fn %{system:, messages:} -> {:ok, text}` |

**Optional:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tools` | map | `%{}` | Tool functions the sub-agent can call |
| `context` | map | `%{}` | Values accessible as `ctx/key` in the program |
| `refs` | map | `%{}` | Reference extraction spec (see below) |
| `max_turns` | integer | `5` | Maximum LLM calls before failing |
| `timeout` | integer | `5000` | Per-program execution timeout (ms) |
| `max_ref_retries` | integer | `1` | Retries if required refs are missing |

#### Defining Refs as Contracts

You can mark specific refs as `required`. If extraction returns `nil`, the SubAgent will be given feedback and a "ref retry" to fix its response:

```elixir
refs: %{
  # Required contract: will trigger retry if nil
  email_ids: [path: [Access.at(0), :id], required: true],
  
  # Optional: nil is fine
  count: &length/1
}
```

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

### PtcRunner.SubAgent.as_tool/1

Wrap a SubAgent configuration as a callable tool:

```elixir
tool = PtcRunner.SubAgent.as_tool(
  llm: llm,
  tools: %{"search" => &MyApp.search/1},
  refs: %{id: [Access.at(0), :id]}
)
```

The returned function takes `%{"task" => "..."}` and returns the SubAgent result.

### PtcRunner.SubAgent.RefExtractor.extract/2

```elixir
refs = PtcRunner.SubAgent.RefExtractor.extract(result, %{
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
- 50-70% turn reduction vs pure ad-hoc
- See [Orchestration Patterns](#orchestration-patterns) for implementation examples

### Known LLM Behavior Issues

From spike testing with Gemini 2.5 Flash:

1. **Missing functions**: LLM tries `(str ...)` and `(conj ...)` which are currently missing.
2. **Data Path Confusion**: Uses `[:result :id]` instead of `[:result 0 :id]` for list-wrapped results.
3. **Invalid comparators**: Uses `(sort-by :total >)` but `>` isn't a valid comparator function in the env (operators are syntax, not first-class functions yet).

These should be addressed by either:
- Adding `str` and `conj` to `PtcRunner.Lisp.Runtime`
- Adding numeric safety (handling `nil` in arithmetic)
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
    {:ok, result} = PtcRunner.SubAgent.delegate(task, llm: llm, tools: tools)
    {name, result.summary}
  end, max_concurrency: 3)
  |> Enum.map(fn {:ok, result} -> result end)
```

**Note:** Memory isolation (scoped scratchpad) enables safe parallel execution.

---

## Further Reading

- [Specification](specification.md) - Full API reference and type definitions
- [Spike Summary](spike-summary.md) - Validation results and architectural decisions
- [PtcRunner Guide](../guide.md) - Core PTC-Lisp documentation
