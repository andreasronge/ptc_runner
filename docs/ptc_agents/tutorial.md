# PTC SubAgents Tutorial

**Notice:** This API isn’t implemented yet.
This tutorial describes the planned “SubAgents” API and exists to validate the design early—so it’s ergonomic, consistent, and pleasant to use before we commit to the implementation.

A practical guide to building context-efficient agentic workflows with PTC SubAgents.

> **API Location**: `PtcRunner.SubAgent` (core library)
> **Specification**: See [specification.md](specification.md) for full API reference

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

### How It Works

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  delegate/2 │ ───> │ Agentic Loop │ ───> │   Result    │
│  (your task)│      │  (LLM ↔ Lisp)│      │ + refs      │
└─────────────┘      └──────────────┘      └─────────────┘
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
        ┌──────────┐  ┌──────────┐  ┌──────────┐
        │   LLM    │  │  Tools   │  │  Memory  │
        │ callback │  │ (yours)  │  │ (scoped) │
        └──────────┘  └──────────┘  └──────────┘
```

## Core API

The SubAgent system provides two main functions:

| Function | Purpose |
|----------|---------|
| `delegate/2` | Run a task with tools in isolation, get back result + refs |
| `as_tool/1` | Wrap a SubAgent config as a callable tool for orchestration |

**Design philosophy**: The library provides primitives, not patterns. You compose these into whatever orchestration pattern fits your use case. The patterns shown later in this tutorial are examples, not prescriptions.

```
┌─────────────────────────────────────────────────────────────────┐
│                       Core Functions                             │
│                                                                  │
│   delegate/2 ──── Run task in isolation                         │
│   as_tool/1  ──── Make SubAgent callable as a tool              │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                    Patterns (you build)                          │
│                                                                  │
│   Chained ──────────── Pass refs between steps                  │
│   Hierarchical ─────── SubAgents calling SubAgents              │
│   Planning ─────────── Generate plan, then execute              │
│   Dynamic ──────────── spawn_agent meta-tool                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

Here's the simplest possible example - delegate a task and get a result:

```elixir
# 1. Create an LLM callback (see "LLM Integration" below)
llm = fn %{system: system, messages: messages} ->
  MyLLM.chat(system, messages)  # Return {:ok, text} or {:error, reason}
end

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

## LLM Integration

SubAgent is provider-agnostic. You supply a callback function that calls your LLM.

### Callback Interface

```elixir
# Required fields
fn %{system: String.t(), messages: [map()]} ->
  {:ok, String.t()} | {:error, term()}
end

# Optional fields (callback can ignore these)
%{
  system: "...",
  messages: [...],
  turn: 2,                    # Current turn number
  task: "Find urgent emails", # Original task
  tool_names: ["search"],     # Available tools
  llm_opts: %{temperature: 0.7}  # User-provided options
}
```

### ReqLLM Example

```elixir
# Add {:req_llm, "~> 0.x"} to your deps
defmodule MyApp.LLM do
  def callback(model \\ "google/gemini-2.5-flash") do
    fn %{system: system, messages: messages} = params ->
      opts = Map.get(params, :llm_opts, %{})

      case ReqLLM.chat(:openrouter,
             model: model,
             system: system,
             messages: messages,
             temperature: opts[:temperature] || 0.7) do
        {:ok, %{choices: [%{message: %{content: text}} | _]}} -> {:ok, text}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

# Usage
llm = MyApp.LLM.callback()
PtcRunner.SubAgent.delegate(task, llm: llm, tools: tools)

# With options
PtcRunner.SubAgent.delegate(task,
  llm: llm,
  tools: tools,
  llm_opts: %{temperature: 0.2}
)
```

---

## Example: Email Processing Pipeline

This example shows a realistic multi-step workflow where sub-agents handle different parts of an email processing task.

```elixir
# Setup LLM callback
llm = MyApp.LLM.callback()

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

### Tool Contracts (Types)

Tools can have **contracts** that serve two purposes:
1. **Declarative schema** → LLM sees what the tool accepts/returns
2. **Programmatic validation** → Runtime checks with error feedback

#### Auto-Extraction from @spec (Default)

The simplest approach: just pass a function reference. The library auto-extracts type info from `@spec`:

```elixir
# In your module:
@spec search(String.t(), integer()) :: [%{id: integer(), title: String.t()}]
def search(query, limit), do: ...

@spec get_customer(integer()) :: %{id: integer(), name: String.t()}
def get_customer(id), do: ...

# Tool registration - specs extracted automatically:
tools = %{
  "search" => &MyApp.search/2,
  "get_customer" => &MyApp.get_customer/1
}
```

The library uses `Function.info/1` to get module/function/arity, then `Code.Typespec.fetch_specs/1` to extract the spec.

**Supported types:** Auto-extraction handles a pragmatic subset of Elixir types:

| Elixir type | Maps to |
|-------------|---------|
| `String.t()` | `:string` |
| `integer()` | `:int` |
| `float()` | `:float` |
| `boolean()` | `:bool` |
| `atom()` | `:keyword` |
| `map()` | `:map` |
| `list(t)` | `[:t]` |
| `%{key: type}` | `{:key :type}` |

**Unsupported types** require explicit override:
- `pid()`, `reference()`, `port()` - no JSON equivalent
- `timeout()` - union of integer and `:infinity`
- Complex unions - `{:ok, t} | {:error, reason}`
- Custom `@type` definitions - not recursively expanded
- Opaque types - `t()` from other modules

```elixir
# This won't auto-extract cleanly
@spec start_link(GenServer.options()) :: GenServer.on_start()
def start_link(opts), do: ...

# Use explicit override instead
tools = %{
  "start" => {&start_link/1, :skip}  # or provide manual spec
}
```

#### Override with Explicit Spec

Override auto-extraction with a tuple `{function, spec}`:

```elixir
tools = %{
  # String schema format
  "search" => {
    &MyApp.search/2,
    "(query :string, limit :int) -> [{:id :int :title :string}]"
  },

  # ToolSpec struct for full control
  "complex" => {
    &MyApp.complex_op/1,
    ToolSpec.new(
      params: [
        query: [type: :string, required: true],
        limit: [type: :int, default: 10]
      ],
      returns: [{:id, :int}, {:title, :string}]
    )
  }
}
```

#### Skip Validation

For tools where validation isn't needed or possible:

```elixir
tools = %{
  # Skip validation for specific tool
  "dynamic" => {&MyApp.dynamic_fn/1, :skip},

  # Anonymous functions have no @spec to extract
  "inline" => fn args -> some_operation(args) end
}
```

#### Global Validation Options

Control validation behavior at the delegation level:

```elixir
PtcRunner.SubAgent.delegate(task,
  tools: tools,
  tool_validation: :enabled  # default
)
```

| Option | Behavior |
|--------|----------|
| `:enabled` | Validate, fail on errors (default) |
| `:warn_only` | Validate, log errors but continue |
| `:disabled` | Skip all validation |
| `:strict` | Fail if any tool lacks a spec |

**Behavior matrix:**

| Tool definition | `@spec` exists? | Behavior |
|-----------------|-----------------|----------|
| `&fun/n` | Yes | Auto-extract, validate |
| `&fun/n` | No | Warn, no validation |
| `{&fun/n, spec}` | — | Use provided spec |
| `{&fun/n, :skip}` | — | No validation |
| `fn args -> ... end` | — | No validation (anonymous) |

#### ToolSpec Features

Using `ToolSpec.new/1` provides:
- **Schema generation** → `"(query :string, limit :int) -> [{:id :int :title :string}]"`
- **Input validation** → Checks args before calling tool
- **Output validation** → Checks result after tool returns
- **Error feedback** → Validation errors feed back to LLM for self-correction

#### Input Coercion

LLMs sometimes quote numbers (`"123"` instead of `123`). Input validation performs gentle coercion:

```
LLM generates: (call "get_customer" {:id "42"})

Validator:
  - Coerces "42" → 42
  - Adds warning: "id: coerced string \"42\" to integer"
  - Proceeds with call

LLM sees warning in next turn, learns to use unquoted numbers.
```

Output validation is **strict**—your tools should return correct types.

#### Validation Error Feedback

When validation fails, errors feed back to the LLM with full paths:

```
Tool validation errors:
- results[0].customer.id: expected integer, got string "abc"
- results[2].amount: expected float, got nil

Tool validation warnings:
- limit: coerced string "10" to integer
```

The LLM can self-correct based on these messages.

#### Type Syntax Reference

```
Primitives:
  :string :int :float :bool :keyword :any

Collections:
  [:int]                          ; list of ints
  [{:id :int :name :string}]      ; list of maps

Maps:
  {:id :int :name :string}        ; map with typed fields
  :map                            ; any map

Optional/Nullable:
  {:id :int :email [:string]}     ; email is optional (nil allowed)

Nested:
  {:customer {:id :int :address {:city :string :zip :string}}}
```

#### SubAgent-as-Tool Contracts

SubAgents wrapped with `as_tool/1` can also have typed contracts:

```elixir
tools = %{
  "email-agent" => SubAgent.as_tool(
    llm: llm,
    tools: email_tools,
    description: "Find, filter, and summarize emails",
    refs: %{
      email_ids: [Access.all(), :id],
      count: &length/1
    },
    spec: ToolSpec.new(
      params: [
        task: [type: :string, required: true],
        context: [type: :map, default: %{}]
      ],
      returns: {:refs, %{email_ids: [:int], count: :int}}
    )
  )
}
```

Generated schema for LLM:
```
"agent(task :string, context :map) -> {:summary :string :refs {:email_ids [:int] :count :int}}"
```

The `agent(...)` prefix signals this is a SubAgent delegation, not a direct function call.

#### Dynamic spawn_agent Contract

For dynamic SubAgent creation, the meta-tool has a flexible contract:

```elixir
tools = %{
  "spawn_agent" => {
    &spawn_agent_fn/1,
    ToolSpec.new(
      params: [
        task: [type: :string, required: true],
        tools: [type: [:string], required: true],
        context: [type: :map, default: %{}]
      ],
      returns: {:summary, :string, :refs, :map}
    )
  }
}
```

#### Explicit Type Conversion in PTC-Lisp

When the LLM needs to convert types explicitly, use Clojure 1.11+ functions:

```clojure
;; Parse strings to numbers (returns nil on failure)
(parse-long "42")        ;; => 42
(parse-double "3.14")    ;; => 3.14

;; Safe with if-let
(if-let [n (parse-long user-input)]
  (call "get_order" {:id n})
  "Invalid order ID")
```

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
llm = MyApp.LLM.callback()

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

Provide a `create_plan` tool and the domain tools via `tool_catalog`. The LLM sees the tool schemas (with types) but can only call `create_plan`:

```elixir
planning_tools = %{
  "create_plan" => fn args ->
    # The LLM passes the plan structure as args
    IO.inspect(args, label: "Plan Created")
    %{status: "success", plan_id: "plan_123"}
  end
}

# Domain tools - the planner sees their schemas but can't call them
domain_tools = %{
  "email-finder" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: email_tools,
    refs: %{email_ids: [Access.all(), :id], count: &length/1}
  ),
  "email-reader" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: %{"read_email" => &MyApp.read_email/1},
    refs: %{bodies: fn r -> Map.new(r, &{&1.id, &1.body}) end}
  ),
  "reply-drafter" => PtcRunner.SubAgent.as_tool(
    llm: llm,
    tools: %{"draft_reply" => &MyApp.draft_reply/1},
    refs: %{draft_ids: [Access.all(), :draft_id]}
  )
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
  tool_catalog: domain_tools  # Schemas visible, not callable
)
```

**What the LLM sees in its system prompt:**

```
## Tools you can call
- create_plan(steps [{:id :keyword :task :string :tools [:string] :needs [:keyword] :output :map}]) -> {:status :string :plan_id :string}

## Tools available for planning (do not call directly)
- email-finder: agent(task :string) -> {:summary :string :refs {:email_ids [:int] :count :int}}
- email-reader: agent(task :string, context :map) -> {:summary :string :refs {:bodies :map}}
- reply-drafter: agent(task :string, context :map) -> {:summary :string :refs {:draft_ids [:int]}}
```

The LLM can see the exact input/output types of each tool, enabling it to plan correct data flow between steps (e.g., knowing that `email-finder` returns `email_ids` as `[:int]` which can be passed to `email-reader`).

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

Let the LLM create SubAgents on-the-fly by providing a **meta-tool** - a tool that itself creates and runs SubAgents.

#### How It Works

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Parent SubAgent                                  │
│                                                                          │
│  Task: "Find urgent emails, then schedule follow-up meetings"           │
│                                                                          │
│  Available tool: spawn_agent(task, tools, context)                      │
│                                                                          │
│  LLM decides:                                                            │
│    1. I need email tools → spawn_agent({task: "Find urgent...",         │
│                                         tools: ["email"]})              │
│    2. I need calendar tools → spawn_agent({task: "Schedule...",         │
│                                            tools: ["calendar"],         │
│                                            context: {email_ids: ...}})  │
└─────────────────────────────────────────────────────────────────────────┘
                              │
            ┌─────────────────┴─────────────────┐
            ▼                                   ▼
   ┌─────────────────┐                 ┌─────────────────┐
   │  Child SubAgent │                 │  Child SubAgent │
   │  tools: email   │                 │  tools: calendar│
   │                 │                 │                 │
   │  list_emails    │                 │  find_slots     │
   │  read_email     │                 │  create_meeting │
   └─────────────────┘                 └─────────────────┘
```

The parent LLM **chooses** which tool sets each child needs. It doesn't have direct access to `list_emails` or `find_slots` - it can only spawn specialized agents.

#### Implementation

```elixir
defmodule MyApp.AgentTools do
  # Tool catalog - all available tool sets
  @tool_catalog %{
    "email" => %{
      "list_emails" => &MyApp.Email.list/1,
      "read_email" => &MyApp.Email.read/1
    },
    "calendar" => %{
      "find_slots" => &MyApp.Calendar.find_slots/1,
      "create_meeting" => &MyApp.Calendar.create/1
    },
    "crm" => %{
      "get_customer" => &MyApp.CRM.get_customer/1,
      "update_customer" => &MyApp.CRM.update_customer/1
    }
  }

  @type spawn_result :: %{summary: String.t(), refs: map()}

  @spec spawn_agent(map()) :: spawn_result()
  def spawn_agent(args) do
    tool_names = args["tools"] || []
    selected_tools =
      tool_names
      |> Enum.map(&Map.get(@tool_catalog, &1, %{}))
      |> Enum.reduce(%{}, &Map.merge/2)

    {:ok, result} = PtcRunner.SubAgent.delegate(
      args["task"],
      llm: llm(),
      tools: selected_tools,
      context: args["context"] || %{}
    )

    %{summary: result.summary, refs: result.refs}
  end

  defp llm, do: MyApp.LLM.callback()
end

# Register with auto-extracted @spec
tools = %{
  "spawn_agent" => &MyApp.AgentTools.spawn_agent/1
}
```

The `@spec` enables auto-extraction. The LLM sees:
```
spawn_agent(args :map) -> {:summary :string :refs :map}
```

**Without @spec**: If you use an anonymous function or a function without `@spec`, the library warns and continues without validation. The LLM won't see type hints in the system prompt, which may lead to incorrect calls.

```elixir
# Anonymous fn - no @spec possible, LLM gets no type hints
tools = %{
  "spawn_agent" => fn args -> ... end
}
# Warning: No @spec found for anonymous function, skipping validation

# To provide hints manually:
tools = %{
  "spawn_agent" => {
    fn args -> ... end,
    "(task :string, tools [:string], context :map) -> {:summary :string :refs :map}"
  }
}
```

```elixir
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

#### Breaking Down spawn_agent

The `spawn_agent` function is just a regular Elixir function that:

1. **Receives LLM's choices** - task description, tool set names, optional context
2. **Resolves tool sets** - looks up actual tool functions from the catalog
3. **Delegates to SubAgent** - creates an isolated SubAgent with those tools
4. **Returns summary + refs** - parent sees only the distilled result

```elixir
def spawn_agent(args, tool_catalog, llm) do
  # 1. LLM specifies which tool sets it needs
  tool_names = args["tools"] || []

  # 2. Resolve to actual tool functions
  selected_tools =
    tool_names
    |> Enum.map(&Map.get(tool_catalog, &1, %{}))
    |> Enum.reduce(%{}, &Map.merge/2)

  # 3. Create and run SubAgent with those tools
  {:ok, result} = PtcRunner.SubAgent.delegate(
    args["task"],
    llm: llm,
    tools: selected_tools,
    context: args["context"] || %{}
  )

  # 4. Return only what parent needs
  %{summary: result.summary, refs: result.refs}
end
```

#### spawn_agent vs as_tool

| Aspect | `spawn_agent` (dynamic) | `as_tool` (pre-defined) |
|--------|-------------------------|-------------------------|
| Tool selection | LLM chooses at runtime | Fixed at definition |
| Flexibility | High - any combination | Low - single purpose |
| Predictability | Lower | Higher |
| Use case | Exploratory, novel tasks | Production, known domains |

#### Considerations

- **Trust boundary**: The parent LLM controls which tool sets are available via `tool_catalog`. It can't request tools not in the catalog.
- **Context passing**: Use `:context` to pass refs between spawned agents (as shown with `email_ids`).
- **Tracing**: Each spawned agent has its own trace, nested in the parent's trace.

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
{:ok, result} = PtcRunner.SubAgent.delegate(task, llm: llm, tools: tools)

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
| `tool_catalog` | map | `%{}` | Tools whose schemas are visible in prompt but not callable (for planning) |
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
{:ok, result} = PtcRunner.ToolDiscovery.run(
  "Analyze travel expenses for Q3",
  llm: llm,
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
