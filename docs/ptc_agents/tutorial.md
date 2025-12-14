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
- **Parallel execution**: Run multiple sub-agents concurrently
- **Isolation**: Each sub-agent has only the tools it needs

### How It Works: The Agentic Loop

A SubAgent runs an **agentic loop** - it may execute multiple programs before completing a task:

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
| 2 | Sees customers, generates: `(call "get_orders" 1)` | Returns orders for customer #1 |
| 3 | Sees orders, responds: "Top customer is Acme with 3 orders totaling $12K" | Done (no program) |

**Key behaviors:**

- **Multiple programs**: Complex tasks may require several steps
- **Error recovery**: If a program fails, the error is fed back and the LLM can retry
- **Automatic termination**: Loop ends when the LLM responds without a program
- **Safety limit**: `max_turns` option prevents infinite loops (default: 5)

---

## Quick Start

Here's the simplest possible example - delegate a task and get a result:

```elixir
# Define tools the sub-agent can use
tools = %{
  "get_products" => {fn ->
    [%{name: "Widget", price: 100}, %{name: "Gadget", price: 50}]
  end, "() -> [{:name :string :price :int}]"}
}

# Delegate a task
{:ok, result} = PtcDemo.SubAgent.delegate(
  "What is the most expensive product?",
  tools: tools
)

result.result   #=> "Widget"
result.summary  #=> "The most expensive product is Widget at $100"
```

The sub-agent:
1. Receives your task and available tools
2. Generates a PTC-Lisp program to solve it
3. Executes the program safely in isolation
4. Returns the result with an optional summary

---

## Example: Email Processing Pipeline

This example shows a realistic multi-step workflow where sub-agents handle different parts of an email processing task.

```elixir
# Tools for reading emails
email_tools = %{
  "list_emails" => {&MyApp.Email.list/1, "(opts :map) -> [{:id :int :from :string :subject :string :body :string :urgent :bool}]"},
  "get_email" => {&MyApp.Email.get/1, "(id :int) -> {:id :int :from :string :subject :string :body :string}"}
}

# Tools for drafting responses
drafting_tools = %{
  "draft_reply" => {&MyApp.Email.draft/2, "(email_id :int, content :string) -> {:draft_id :int :preview :string}"},
  "get_template" => {&MyApp.Templates.get/1, "(name :string) -> :string"}
}

# Step 1: Find urgent emails (sub-agent handles the filtering)
{:ok, step1} = PtcDemo.SubAgent.delegate(
  "Find all urgent emails from today",
  tools: email_tools,
  refs: %{
    email_ids: fn result -> Enum.map(result, & &1.id) end,
    count: fn result -> length(result) end
  }
)

IO.puts(step1.summary)
#=> "Found 3 urgent emails: Budget Review (CFO), Server Alert (DevOps), Client Request (Sales)"

# Step 2: Draft responses using only the IDs (not the full email bodies)
{:ok, step2} = PtcDemo.SubAgent.delegate(
  "Draft brief acknowledgment replies for these emails",
  tools: drafting_tools,
  context: %{email_ids: step1.refs.email_ids}
)

IO.puts(step2.summary)
#=> "Created 3 draft replies ready for review"
```

**What happened here:**
- Step 1 processed potentially large email bodies but returned only IDs and a summary
- Step 2 received just the IDs via `context`, keeping its input small
- The main agent never saw the raw email content - just summaries and IDs

---

## Example: Parallel Status Dashboard

This example shows how to run multiple sub-agents in parallel to gather data from different sources.

```elixir
# Define specialized tools for each data source
jira_tools = %{
  "get_sprint_issues" => {&MyApp.Jira.sprint_issues/0, "() -> [{:key :string :status :string :assignee :string}]"},
  "get_blockers" => {&MyApp.Jira.blockers/0, "() -> [{:key :string :summary :string :blocked_days :int}]"}
}

slack_tools = %{
  "get_mentions" => {&MyApp.Slack.mentions/1, "(hours :int) -> [{:channel :string :from :string :message :string}]"},
  "get_unreads" => {&MyApp.Slack.unreads/0, "() -> {:channels :int :dms :int}"}
}

github_tools = %{
  "get_prs" => {&MyApp.GitHub.open_prs/0, "() -> [{:number :int :title :string :author :string :reviews :int}]"},
  "get_failing_checks" => {&MyApp.GitHub.failing/0, "() -> [{:repo :string :workflow :string :branch :string}]"}
}

# Run all three sub-agents in parallel
tasks = [
  {"Jira", "Summarize sprint status and any blockers", jira_tools},
  {"Slack", "Check for urgent mentions in the last 4 hours", slack_tools},
  {"GitHub", "List PRs needing review and any failing checks", github_tools}
]

results =
  tasks
  |> Task.async_stream(fn {name, task, tools} ->
    {:ok, result} = PtcDemo.SubAgent.delegate(task, tools: tools)
    {name, result.summary}
  end, max_concurrency: 3)
  |> Enum.map(fn {:ok, result} -> result end)

# Display the dashboard
for {name, summary} <- results do
  IO.puts("\n## #{name}")
  IO.puts(summary)
end

#=> ## Jira
#=> Sprint 23 is 60% complete. 2 blockers: AUTH-123 (3 days), API-456 (1 day)
#=>
#=> ## Slack
#=> 5 urgent mentions: 2 in #incidents, 3 DMs from engineering
#=>
#=> ## GitHub
#=> 4 PRs need review. 1 failing check: main branch CI in ptc_runner
```

**Benefits of this approach:**
- Each sub-agent has only relevant tools (no Jira agent sees GitHub tools)
- Parallel execution - total time is max(jira, slack, github), not sum
- Main agent receives ~300 tokens total instead of ~10KB raw data

---

## Core Concepts

### Tools

Tools are functions the sub-agent can call. Provide them as a map with optional schemas:

```elixir
tools = %{
  # Simple function (no schema)
  "get_time" => fn -> DateTime.utc_now() end,

  # Function with schema (recommended - helps the LLM use it correctly)
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{:id :int :title :string :score :float}]"},

  # Arity-0 with schema
  "get_users" => {fn -> MyApp.Users.all() end, "() -> [{:id :int :name :string :role :string}]"}
}
```

### Context

Pass small values (IDs, settings) to the sub-agent without bloating the prompt:

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Get details for this order",
  tools: order_tools,
  context: %{order_id: "ORD-12345", include_history: true}
)
```

The sub-agent accesses these as `ctx/order_id` and `ctx/include_history` in its PTC program.

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

Refs are extracted deterministically (not by the LLM), so they're reliable for chaining.

### Summaries

By default, the sub-agent generates a human-readable summary of the result:

```elixir
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Analyze Q3 sales performance",
  tools: sales_tools,
  summarize: true  # default
)

result.result   #=> [%{month: "Jul", ...}, %{month: "Aug", ...}, ...]
result.summary  #=> "Q3 sales grew 15% vs Q2. August was strongest at $1.2M..."
```

Set `summarize: false` if you only need the raw result.

---

## Using SubAgents as Tools

Wrap sub-agents as tools so a main agent can orchestrate them:

```elixir
# Create sub-agent tools
main_tools = %{
  "email-agent" => PtcDemo.SubAgent.as_tool(
    description: "Find, read, and draft emails",
    tools: email_tools
  ),

  "calendar-agent" => PtcDemo.SubAgent.as_tool(
    description: "Check availability and schedule meetings",
    tools: calendar_tools
  ),

  "crm-agent" => PtcDemo.SubAgent.as_tool(
    description: "Look up customer information and history",
    tools: crm_tools
  )
}

# Now the main agent can orchestrate these sub-agents
{:ok, result} = PtcDemo.SubAgent.delegate(
  "Find emails from Acme Corp, check their customer status, and schedule a follow-up",
  tools: main_tools
)
```

The main agent decides which sub-agents to call and in what order.

---

## CLI Commands

Try SubAgents interactively in the demo CLI:

```
> /subagent "Find the employee with highest expenses"
[SubAgent] Generating program...
[SubAgent] Executing: (-> (call "get_expenses") (group-by :employee) ...)
[SubAgent] Result: "John Smith - $12,450"
Context used: ~67 tokens

> /subagent:verbose "Find top 3 products"
[SubAgent] System prompt: You are a PTC-Lisp sub-agent...
[SubAgent] Generated program: (-> (call "get_products") (sort-by :revenue :desc) (take 3))
[SubAgent] Raw result: [%{name: "Widget Pro", ...}, ...]
[SubAgent] Summary: "Top 3 by revenue: Widget Pro ($12K), Gadget X ($8K), Basic ($5K)"
Context used: ~89 tokens
```

---

## Advanced Features

### Tool Discovery (Large Registries)

When you have 50+ tools, let the sub-agent discover which ones it needs:

```elixir
{:ok, result} = PtcDemo.ToolDiscovery.run(
  "Analyze travel expenses for Q3",
  registry: all_company_tools  # 100+ tools
)

# The discovery agent found and used only: get_expenses, get_categories, sum_by
result.discovery.tools       #=> %{"get_expenses" => ..., ...}
result.discovery.discovery_turns  #=> 2
result.result               #=> %{total: 45000, by_category: %{...}}
```

### Reusable Functions

Generate a function once, run it many times with different parameters:

```elixir
{:ok, defn_code} = PtcDemo.SubAgent.generate(
  "Find top N items by revenue",
  tools: product_tools,
  params: [:n],
  name: "top-products"
)

# Use it multiple times without additional LLM calls
{:ok, top1} = PtcDemo.SubAgent.run_with_defn(defn_code, "(top-products 1)", tools: product_tools)
{:ok, top5} = PtcDemo.SubAgent.run_with_defn(defn_code, "(top-products 5)", tools: product_tools)
{:ok, top10} = PtcDemo.SubAgent.run_with_defn(defn_code, "(top-products 10)", tools: product_tools)
```

---

## Best Practices

### When to Use SubAgents

**Good fit:**
- Large data transformations (filtering, grouping, aggregating lists)
- Multi-step workflows where you want to pass IDs between steps
- Parallel data gathering from multiple sources
- Tasks where raw data is large but the answer is small

**Skip it when:**
- The task is trivial (just return a value, no transformation)
- You need the raw data in the main agent anyway
- Single tool call with no processing

### Golden Patterns

1. **Curate tool sets** - Give each sub-agent only the tools it needs
2. **Use schemas** - Help the LLM understand tool signatures: `{fn, "() -> [{:id :int :name :string}]"}`
3. **Extract refs for chaining** - Pass IDs and counts, not full objects
4. **Enable tracing when debugging** - `trace: true` shows the generated program and timings
5. **Discover tools for large registries** - Don't send 50 tool schemas when you need 3

---

## Reference

### API Overview

```elixir
# Basic delegation
{:ok, result} = PtcDemo.SubAgent.delegate(task, opts)

# Wrap as a tool for orchestration
tool = PtcDemo.SubAgent.as_tool(description: "...", tools: %{...})

# Tool discovery for large registries
{:ok, result} = PtcDemo.ToolDiscovery.run(task, registry: tools)
{:ok, discovery} = PtcDemo.ToolDiscovery.discover(task, registry: tools)

# Generate reusable functions
{:ok, defn} = PtcDemo.SubAgent.generate(task, tools: tools, params: [:x])
{:ok, result} = PtcDemo.SubAgent.run_with_defn(defn, "(fn-name arg)", tools: tools)
```

### Options for `delegate/2`

| Option | Type | Description |
|--------|------|-------------|
| `tools` | map | Tool functions the sub-agent can call |
| `context` | map | Values accessible as `ctx/key` in the program |
| `refs` | map | Paths or functions to extract values from result |
| `summarize` | boolean | Generate a summary (default: true) |
| `trace` | boolean | Include execution trace (default: false) |
| `max_turns` | integer | Maximum LLM calls before failing (default: 5) |
| `model` | string | LLM model (default: from `PTC_DEMO_MODEL` env) |
| `llm` | function | Custom LLM callback |

### Return Value

```elixir
{:ok, %{
  result: term(),           # The computed result
  summary: String.t | nil,  # Human-readable summary
  refs: map(),              # Extracted reference values
  trace: map() | nil        # Execution trace (if enabled)
}}

# Or on error:
{:error, reason}
```

When `trace: true`, the trace includes all turns:

```elixir
%{
  turns: [
    %{program: "(call \"get_data\")", result: [...], error: nil, duration_ms: 45},
    %{program: "(filter ...)", result: [...], error: nil, duration_ms: 32}
  ],
  tool_calls: [...],        # All tool calls across all turns
  total_duration_ms: 523
}
```

### Common Errors

| Error | Meaning |
|-------|---------|
| `:no_program_generated` | LLM didn't produce a valid PTC-Lisp program (on first turn) |
| `{:execution_error, reason}` | Program failed during execution |
| `:empty_response` | LLM returned empty response |
| `:max_turns_exceeded` | Reached `max_turns` limit without completing |

### LLM Providers

SubAgent uses a callback-based LLM abstraction. Use the provided helper or write your own:

```elixir
# Using ReqLLM (recommended)
llm = PtcDemo.LLM.req_llm("anthropic/claude-sonnet-4-20250514")

{:ok, result} = PtcDemo.SubAgent.delegate("task",
  tools: tools,
  llm: llm
)
```

**Custom provider** - implement the callback signature:

```elixir
fn %{system: String.t(), messages: list(), opts: keyword()} ->
  {:ok, String.t()} | {:error, term()}
end
```

See `PtcDemo.LLM` module docs for examples with OpenAI, Ollama, and other providers.

### Testing with MockLLM

For deterministic tests without API calls:

```elixir
# Fixed response
mock = PtcDemo.MockLLM.fixed(~s'```lisp\n(+ 1 2)\n```')

{:ok, result} = PtcDemo.SubAgent.delegate("add numbers",
  tools: %{},
  llm: mock
)
assert result.result == 3

# Sequence of responses (for multi-turn interactions)
mock = PtcDemo.MockLLM.sequence([
  ~s'```lisp\n(call "get_data")\n```',
  "Summary of the data"
])
```

---

## Further Reading

- [GitHub Epic #275](https://github.com/andreasronge/ptc_runner/issues/275) - Full specification and related issues
- [PtcRunner Guide](../guide.md) - Core PTC-Lisp documentation
