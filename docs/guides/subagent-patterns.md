# Composition Patterns

This guide covers how to compose SubAgents into larger workflows: chaining, hierarchical delegation, LLM-powered tools, and orchestration patterns.

## Chaining SubAgents

### Using `with` (Recommended)

The idiomatic pattern for sequential chains:

```elixir
with {:ok, step1} <- SubAgent.run(finder, llm: llm),
     {:ok, step2} <- SubAgent.run(drafter, llm: llm, context: step1),
     {:ok, step3} <- SubAgent.run(sender, llm: llm, context: step2) do
  {:ok, step3}
else
  {:error, %{fail: %{reason: :not_found}}} -> {:error, :no_data}
  {:error, step} -> {:error, step.fail}
end
```

Benefits:
- Short-circuits on first error
- Pattern matching in `else` for specific error handling
- Auto-chaining via `context: step` extracts both return data and signature

### Using Pipes (`run!` and `then!`)

When you want to crash on failure:

```elixir
SubAgent.run!(finder, llm: llm)
|> SubAgent.then!(drafter, llm: llm)
|> SubAgent.then!(sender, llm: llm)
```

`then!/2` automatically sets `context:` to the previous step.

### Field Description Flow in Chains

When agents are chained, `field_descriptions` from upstream agents automatically flow to downstream agents. This enables self-documenting chains:

```elixir
# Agent A defines output descriptions
agent_a = SubAgent.new(
  prompt: "Double {{n}}",
  signature: "(n :int) -> {result :int}",
  field_descriptions: %{result: "The doubled value"}
)

# Agent B receives those descriptions as input context
agent_b = SubAgent.new(
  prompt: "Add 10 to result",
  signature: "(result :int) -> {final :int}",
  field_descriptions: %{final: "The final computed value"}
)

# When chained, agent_b's LLM sees "The doubled value" description for data/result
step_a = SubAgent.run!(agent_a, llm: llm, context: %{n: 5})
step_b = SubAgent.then!(step_a, agent_b, llm: llm)

# Each step carries its own field_descriptions for downstream use
step_a.field_descriptions  #=> %{result: "The doubled value"}
step_b.field_descriptions  #=> %{final: "The final computed value"}
```

This is useful when building multi-agent pipelines where each agent benefits from understanding what the previous agent produced.

### Mixing Text and PTC-Lisp Modes

Text mode and PTC-Lisp mode use the same signature syntax, enabling seamless piping:

```elixir
# Text mode for extraction
extractor = SubAgent.new(
  prompt: "Extract name and age from: {{text}}",
  output: :text,
  signature: "(text :string) -> {name :string, age :int}"
)

# PTC-Lisp mode for computation
processor = SubAgent.new(
  prompt: "Calculate birth year assuming current year 2024",
  signature: "(age :int) -> {birth_year :int}"
)

# Chain them - works seamlessly
{:ok, step1} = SubAgent.run(extractor, llm: llm, context: %{text: "Alice is 30"})
{:ok, step2} = SubAgent.run(processor, llm: llm, context: step1)
step2.return.birth_year  #=> 1994
```

### Parallel Execution

For concurrent agents, use standard Elixir patterns:

```elixir
agents = [email_agent, calendar_agent, crm_agent]

results =
  agents
  |> Task.async_stream(&SubAgent.run(&1, llm: llm))
  |> Enum.map(fn {:ok, result} -> result end)
```

## SubAgents as Tools

Wrap a SubAgent so other agents can call it:

```elixir
main_tools = %{
  "customer-finder" => SubAgent.as_tool(
    SubAgent.new(
      description: "Finds customer by description",
      prompt: "Find customer matching: {{description}}",
      signature: "(description :string) -> {customer_id :int}",
      tools: %{"search" => &MyApp.CRM.search/1}
    )
  ),

  "order-fetcher" => SubAgent.as_tool(
    SubAgent.new(
      description: "Fetches recent orders for customer",
      prompt: "Get recent orders for customer {{customer_id}}",
      signature: "(customer_id :int) -> {orders [:map]}",
      tools: %{"list_orders" => &MyApp.Orders.list/1}
    )
  )
}

# Main agent orchestrates the sub-agents
{:ok, step} = SubAgent.run(
  "Find our top customer and get their orders",
  signature: "{summary :string}",
  tools: main_tools,
  llm: llm
)
```

The main agent sees typed tool signatures and can compose them:

```clojure
(let [customer (tool/customer-finder {:description "highest revenue"})
      orders (tool/order-fetcher {:customer_id (:customer_id customer)})]
  (return {:summary (str "Found " (count orders) " orders")}))
```

### LLM Inheritance

SubAgents can inherit their LLM from the parent. Atoms like `:haiku` or `:sonnet` are resolved via the `:llm_registry` option - a map from atoms to callback functions that you provide:

```elixir
# Define your LLM callbacks
registry = %{
  haiku: &MyApp.LLM.haiku/1,
  sonnet: &MyApp.LLM.sonnet/1
}

# Resolution order (first non-nil wins):
# 1. agent.llm - Struct override
# 2. as_tool(..., llm: x) - Bound at tool creation
# 3. Parent's llm - Inherited at runtime
# 4. run(..., llm: x) - Required at top level

# Always uses haiku (struct override)
classifier = SubAgent.new(
  prompt: "Classify {{text}}",
  signature: "(text :string) -> {category :string}",
  llm: :haiku
)

# Inherits from parent (no llm specified)
finder = SubAgent.new(
  prompt: "Find {{item}}",
  signature: "(item :string) -> {id :int}",
  tools: search_tools
)

tools = %{
  "classify" => SubAgent.as_tool(classifier),        # Uses haiku
  "find" => SubAgent.as_tool(finder),                # Inherits parent
  "summarize" => SubAgent.as_tool(summarizer, llm: :haiku)  # Bound
}

# Parent uses sonnet; finder inherits it, others use haiku
# Registry passed once at top level, inherited by all children
{:ok, step} = SubAgent.run(orchestrator,
  llm: :sonnet,
  llm_registry: registry,
  tools: tools
)
```

See `PtcRunner.SubAgent.run/2` for details on setting up the registry.

## LLM-Powered Tools

For tools needing LLM judgment (classification, evaluation, summarization):

```elixir
alias PtcRunner.SubAgent.LLMTool

tools = %{
  "list_emails" => &MyApp.Email.list/1,

  "evaluate_importance" => LLMTool.new(
    prompt: """
    Evaluate if this email requires immediate attention.

    Consider:
    - Is it from a VIP customer? (Tier: {{customer_tier}})
    - Is it about billing or money?
    - Does it express urgency?

    Email subject: {{email.subject}}
    Email body: {{email.body}}
    """,
    signature: "(email {subject :string, body :string}, customer_tier :string) ->
                {important :bool, priority :int, reason :string}",
    description: "Evaluate if an email requires immediate attention based on VIP status and content"
  )
}
```

The main agent calls it like any other tool:

```clojure
(let [emails (tool/list_emails {:limit 10})]
  (mapv (fn [e]
          (assoc e :eval
            (tool/evaluate_importance
              {:email e :customer_tier "Silver"})))
        emails))
```

### Batch Classification

Process multiple items in one LLM call. The input list is passed via the
context data inventory (not template expansion), so the prompt describes
what to do with the data:

```elixir
"classify_batch" => LLMTool.new(
  prompt: """
  Classify each email by urgency.
  For each email in the input list, determine its urgency level
  and provide a brief reason.
  """,
  signature: "(emails [{id :int, subject :string, from :string}]) ->
              [{id :int, urgency :string, reason :string}]",
  description: "Classify a batch of emails by urgency"
)
```

### LLM Selection for Tools

Atoms like `:haiku` resolve via the `llm_registry` passed at the top-level `run/2` call:

```elixir
# Uses caller's LLM (default)
"deep_analysis" => LLMTool.new(prompt: "...", signature: "...")

# Uses cheaper model for simple tasks (resolved via registry)
"quick_triage" => LLMTool.new(
  prompt: "Is '{{subject}}' urgent?",
  signature: "(subject :string) -> {priority :string}",
  llm: :haiku
)
```

### Response Templates

When an LLMTool makes a simple judgment (boolean, category), `response_template` lets you
define the Lisp logic yourself while the LLM only fills in the data. The LLM returns JSON,
the template produces a typed Lisp value.

```elixir
"semantic_judge" => LLMTool.new(
  prompt: "Is '{{interests1}}' compatible with '{{interests2}}'?",
  signature: "(interests1 :string, interests2 :string) -> :keyword",
  json_signature: "(interests1 :string, interests2 :string) -> {compatible :bool}",
  response_template: "(if {{compatible}} :compatible :unrelated)",
  description: "Returns :compatible or :unrelated"
)
```

Three fields work together:

- `:json_signature` — The internal contract for the LLM call (returns `{compatible :bool}`)
- `:response_template` — PTC-Lisp with Mustache placeholders filled from the JSON result
- `:signature` — The public contract seen by the parent agent (returns `:keyword`)

The parent agent sees a clean typed result:

```clojure
(if (= :compatible (tool/semantic_judge {:interests1 i1 :interests2 i2}))
  (conj! pairs (str id1 "-" id2))
  pairs)
```

The template runs in a no-tools sandbox (`PtcRunner.Lisp.run/2` with no tools or context),
so built-in functions work but tool calls and data references do not.

Use `response_template` for primitive transformations (booleans, numbers, keywords).
Avoid string interpolation where quotes could break Lisp parsing.

## Builtin Ad-Hoc LLM Queries (`llm_query`)

For quick LLM judgments without defining an `LLMTool` struct, enable the builtin `tool/llm-query`:

```elixir
agent = SubAgent.new(
  prompt: "Classify each item and return the urgent ones",
  signature: "(items [:map]) -> {urgent [:map]}",
  llm_query: true,
  max_turns: 5
)

{:ok, step} = SubAgent.run(agent, llm: llm, context: %{items: items})
```

The agent can now call `tool/llm-query` from PTC-Lisp for classification, judgment, or extraction:

```clojure
;; Simple query (default signature: ":string")
(tool/llm-query {:prompt "Is this urgent? {{text}}" :text "Server is down!"})

;; With structured output
(tool/llm-query {:prompt "Classify: {{text}}"
                 :signature "{category :string, score :float}"
                 :text "Revenue dropped 50%"})

;; Batch judgment with pmap
(pmap (fn [item]
        (tool/llm-query {:prompt "Rate urgency: {{desc}}"
                         :signature "{urgent :bool}"
                         :desc (:description item)}))
      data/items)
```

### Control Keys

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `:prompt` | Yes | — | Template with `{{placeholders}}` |
| `:signature` | No | `":string"` | Output type contract |
| `:llm` | No | Parent's LLM | Model override (atom or function) |
| `:response_template` | No | — | PTC-Lisp template with `{{placeholders}}` from JSON result |

All other keys are template arguments available as `{{key}}` in the prompt.

### When to Use `llm_query` vs `LLMTool`

| | `llm_query: true` | `LLMTool.new/1` |
|---|---|---|
| Definition | No struct needed | Explicit struct |
| Prompt | Written by agent at runtime | Fixed at definition time |
| Reuse | Ad-hoc, single agent | Shareable across agents |
| Use case | Agent needs dynamic LLM judgment | Known, reusable LLM tool |

Use `llm_query` when the agent itself decides what to ask the LLM. Use `LLMTool` when you define the prompt upfront in Elixir.

## Builtin Utility Tools (`builtin_tools`)

Enable utility tool families with `builtin_tools`:

```elixir
agent = SubAgent.new(
  prompt: "Find all error lines in the log",
  builtin_tools: [:grep],
  max_turns: 3
)
```

Each atom expands to one or more tools:

| Family | Tools added | Description |
|--------|------------|-------------|
| `:grep` | `tool/grep`, `tool/grep-n` | Regex line search (plain and line-numbered) |

The agent calls these as named-arg tools: `(tool/grep {:pattern "error" :text data/log})`. User-defined tools with the same name take precedence over builtins.

## Orchestration Patterns

### Pattern 1: Dynamic Agent Creation (`spawn_agent`)

Let the LLM create SubAgents on-the-fly:

```elixir
@tool_registry %{
  "email" => %{
    "list_emails" => &MyApp.Email.list/1,
    "read_email" => &MyApp.Email.read/1
  },
  "calendar" => %{
    "find_slots" => &MyApp.Calendar.find_slots/1,
    "create_meeting" => &MyApp.Calendar.create/1
  }
}

def spawn_agent(args, registry, llm) do
  tool_names = args["tools"] || []

  selected_tools =
    tool_names
    |> Enum.map(&Map.get(registry, &1, %{}))
    |> Enum.reduce(%{}, &Map.merge/2)

  {:ok, step} = SubAgent.run(
    args["prompt"],
    llm: llm,
    tools: selected_tools,
    context: args["context"] || %{}
  )

  step.return
end

# Register meta-tool
tools = %{
  "spawn_agent" => {
    fn args -> spawn_agent(args, @tool_registry, llm) end,
    "(prompt :string, tools [:string], context :map) -> :map"
  }
}
```

The LLM decides which tool sets each child needs:

```clojure
(let [emails (tool/spawn_agent {:prompt "Find urgent emails"
                                :tools ["email"]})
      meetings (tool/spawn_agent {:prompt "Schedule follow-ups"
                                  :tools ["calendar"]
                                  :context emails})]
  (return {:scheduled (count meetings)}))
```

### Pattern 2: Pre-defined SubAgents

For predictable workflows, define agents upfront:

```elixir
tools = %{
  "email-agent" => SubAgent.as_tool(
    SubAgent.new(
      prompt: "Find urgent emails needing follow-up",
      signature: "() -> {_email_ids [:int]}",
      tools: email_tools
    )
  ),

  "calendar-agent" => SubAgent.as_tool(
    SubAgent.new(
      prompt: "Schedule meetings for emails: {{email_ids}}",
      signature: "(email_ids [:int]) -> {_meeting_ids [:int]}",
      tools: calendar_tools
    )
  )
}
```

### Pattern 3: Plan Then Execute

Use the `plan:` field for built-in progress tracking. The LLM reports step completions via `(step-done "id" "summary")` and sees a progress checklist between turns.

```elixir
def plan_and_execute(prompt, opts) do
  llm = Keyword.fetch!(opts, :llm)
  tools = Keyword.fetch!(opts, :tools)

  # Phase 1: Plan (no tools)
  {:ok, plan} = SubAgent.run(
    """
    Task: #{prompt}

    Think through your approach. What steps are needed?
    Output a numbered plan. Do NOT execute yet.
    """,
    signature: "{steps [:string]}",
    llm: llm
  )

  # Phase 2: Execute with plan and progress tracking
  SubAgent.run(
    """
    Execute: #{prompt}
    Follow your plan, calling step-done after each step completes.
    """,
    plan: plan.return.steps,
    tools: tools,
    llm: llm,
    context: Keyword.get(opts, :context, %{})
  )
end
```

The `plan:` field accepts a string list (auto-numbered) or `{id, description}` tuples. See [Navigator Pattern](subagent-navigator.md#semantic-progress-with-plans) for details.

### Pattern 4: Structured Plan Executor

LLM generates a plan structure, Elixir executes deterministically:

```elixir
defmodule PlanExecutor do
  def run(plan, tool_registry, llm) do
    Enum.reduce(plan.steps, %{}, fn step, context ->
      tools =
        step.tools
        |> Enum.flat_map(&Map.get(tool_registry, &1, %{}))
        |> Map.new()

      step_context = Map.take(context, step.needs || [])

      {:ok, result} = SubAgent.run(
        step.prompt,
        llm: llm,
        tools: tools,
        context: step_context
      )

      Map.merge(context, result.return || %{})
    end)
  end
end

# Plan structure (generated by LLM or defined manually)
plan = %{
  steps: [
    %{id: :find, prompt: "Find urgent emails",
      tools: [:email], needs: []},
    %{id: :draft, prompt: "Draft acknowledgments",
      tools: [:email], needs: [:email_ids]}
  ]
}

PlanExecutor.run(plan, tool_registry, llm)
```

## Choosing a Pattern

| Task Type | Pattern | Why |
|-----------|---------|-----|
| Simple query | Direct `run/2` | One tool call, no orchestration |
| 2-3 step chain | Pre-defined SubAgents | Known flow, predictable |
| Complex multi-item | Plan then execute | LLM plans batching strategy |
| Novel/exploratory | Dynamic `spawn_agent` | Flexibility to compose |
| Production pipeline | Plan executor | Deterministic, auditable |

## See Also

- [Navigator Pattern](subagent-navigator.md) - Journaled tasks for crash-safe workflows
- [Meta Planner](subagent-meta-planner.md) - Autonomous planning with self-correction
- [Text Mode Guide](subagent-text-mode.md) - Text mode, structured output, and native tool calling
- [Advanced Topics](subagent-advanced.md) - Multi-turn ReAct and compile pattern
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [RLM Patterns](subagent-rlm-patterns.md) - Recursive Language Model patterns
- [Signature Syntax](../signature-syntax.md) - Full signature syntax reference
- [Core Concepts](subagent-concepts.md) - Context, memory, and the firewall
- `PtcRunner.SubAgent` - API reference
