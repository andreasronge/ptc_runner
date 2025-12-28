# PTC SubAgents Tutorial

**Notice:** This API isn’t implemented yet.
This tutorial describes the planned “SubAgents” API and exists to validate the design early—so it’s ergonomic, consistent, and pleasant to use before we commit to the implementation.

A practical guide to building context-efficient agentic workflows with PTC SubAgents.

> **API Location**: `PtcRunner.SubAgent` (core library)
> **Specification**: See [specification.md](specification.md) for full API reference

## What is a SubAgent?

A **SubAgent** is an isolated worker that handles a specific **mission** using a strict **Functional Contract** (Signature). Think of it as a "context firewall" - the sub-agent does the heavy lifting with large datasets, then returns only what was promised in its signature.

```
┌─────────────┐                      ┌─────────────┐
│ Main Agent  │ ── "Find urgent  ──> │  SubAgent   │
│ (strategic) │     emails"          │ (isolated)  │
│             │                      │             │
│  Context:   │      CONTRACT:       │  Has tools: │
│  ~100 tokens│     (id) -> Result   │  - get_emails│
│             │                      │  - search   │
│             │ <── signature ─────  │             │
│             │     validated data   │             │
└─────────────┘                      └─────────────┘
```

**Why use SubAgents?**

- **Type Safety**: The Orchestrator knows exactly what shape of data Step 1 will return.
- **Context efficiency**: Body text might be 50KB; the firewalled reference is just an ID.
- **Isolation**: Each sub-agent has only the tools it needs.
- **Explicit Exit**: The mission is complete only when the agent calls the `return` tool.

---

## Architecture Overview

### The Agentic Loop & The "Return" Tool

A SubAgent runs an **agentic loop** (`PtcRunner.SubAgent.Loop` module). Unlike simple chat, a SubAgent is successful only if it fulfills its contract by calling the built-in `return` tool.

```
┌─────────────────────────────────────────────────────────────────┐
│                        SubAgent Loop                            │
├─────────────────────────────────────────────────────────────────┤
│  Turn 1: LLM generates program → execute → get result           │
│      ↓                                                          │
│  Turn 2: LLM sees result, generates next program                │
│      ↓                                                          │
│  Turn 3: LLM calls (call "return" {valid_data}) → DONE          │
└─────────────────────────────────────────────────────────────────┘
```

**Example:** "Find the top customer and their recent orders"

| Turn | LLM Action | Result |
|------|------------|--------|
| 1 | Generates: `(call "get_customers")` | Returns list of customers |
| 2 | Generates: `(call "get_orders" {:id 1})` | Returns orders for customer #1 |
| 3 | Generates: `(call "return" {:name "Acme" :orders [...]})` | **Mission Fulfilled** |

**Key behaviors:**

- **Termination**: The loop ends **only** when `return` (success) or `fail` (failure) is called.
- **Validation**: If the `return` data doesn't match the `signature`, the LLM is given the error and a chance to retry.
- **Universal Step**: Every delegation returns a `PtcRunner.Step` struct. Intermediate turns also produce "internal" steps that chain together.

### How It Works

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│  delegate/2 │ ───> │ Agentic Loop │ ───> │   Step      │
│  (mission)  │      │  (LLM ↔ Lisp)│      │ (+ result)  │
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
| `delegate/2` | Run a mission with tools in isolation fulfilling a signature contract |
| `as_tool/1` | Wrap a SubAgent config as a callable tool for orchestration |

**Design philosophy**: The library provides primitives, not patterns. You compose these into whatever orchestration pattern fits your use case.

```
┌─────────────────────────────────────────────────────────────────┐
│                       Core Functions                             │
│                                                                  │
│   delegate/2 ──── Run mission in isolation                      │
│   as_tool/1  ──── Make SubAgent callable as a tool              │
│                                                                  │
├─────────────────────────────────────────────────────────────────┤
│                    Patterns (you build)                          │
│                                                                  │
│   Chained ──────────── Pass results between steps                │
│   Hierarchical ─────── SubAgents calling SubAgents              │
│   Planning ─────────── Generate plan, then execute              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Execution Modes: Judgment vs. Agent

SubAgents operate in two primary modes depending on the task complexity.

### 1. Judgment Mode (Mappings & Classification)
Used for single-turn tasks like classifying text or mapping a context object to a specific signature.
- **Trigger**: No `tools` provided and `max_turns` is 1 or 2.
- **Behavior**: The LLM provides a single PTC-Lisp expression (a map).
- **Self-Correction**: If `max_turns: 2` (default), the agent gets one extra turn to fix its output if validation fails.
- **Simplicity**: No need to call `(call "return" ...)`; the expression result is returned directly.

### 2. Agent Mode (Investigation & Tool Use)
Used for multi-turn tasks, using tools, or exploring large datasets in the context.
- **Trigger**: `tools` provided OR `max_turns > 2`.
- **Behavior**: A full **Agentic Loop**. The mission ends ONLY when the agent explicitly calls `(call "return" ...)` or `(call "fail" ...)`.
- **Investigation Agent**: Even without tools, an agent can use multiple turns to investigate context data (e.g., searching a list) before returning a result.

| Mode | Purpose | Stop Signal |
|------|---------|-------------|
| **Judgment** | Quick mapping | Expression result |
| **Agent** | Tool use / Analysis | `(call "return" ...)` |

### Example: Investigation Agent (Zero Tools)
Sometimes you have all the data you need in the `context`, but it's too large for the LLM to process in one go. An investigation agent can "walk" the data over multiple turns.

```elixir
data = %{
  reports: [ # thousands of items ... ]
}

# max_turns > 1 triggers Agent Mode, requiring an explicit 'return'
{:ok, step} = PtcRunner.SubAgent.delegate(
  "Find the report with the highest anomaly score and explain why",
  signature: "{report_id :int, reasoning :string}",
  context: data,
  max_turns: 5,
  llm: llm
)
```

**LLM Strategy**:
- **Turn 1**: `(mapv (fn [r] {:id (:id r) :score (:score r)}) ctx/reports)` (Extracts only IDs and scores to find the max).
- **Turn 2**: `(first (filter #(= (:id %) 123) ctx/reports))` (Fetch the full detail for the identified report).
- **Turn 3**: `(call "return" {:report_id 123 :reasoning "..."})` (Final answer).

---

## Quick Start

Here's how to delegate a prompt with a functional contract:

```elixir
# 1. Define the mission and its contract
prompt = "What is the most expensive product?"
signature = "() -> {name :string, price :float}"

# 2. Delegate
# (Note: product_tools here must provide @specs or explicit signatures)
{:ok, step} = PtcRunner.SubAgent.delegate(prompt,
  signature: signature,
  tools: my_tools,
  llm: my_llm
)

# 3. Access type-safe results
IO.puts "Top product: #{step.return.name}"
   #=> "Widget"
step.return.price  #=> 100.0
```

The sub-agent:
1. Receives the prompt and expands any `{{templates}}` from context.
2. Generates programs until it can call `(call "return" {...})`.
3. Validates the return data against the signature.
4. Returns the `Step` struct to Elixir.

---

## LLM Integration

SubAgent is provider-agnostic. You supply a callback function that calls your LLM.

### Callback Interface

```elixir
# Type signature
@type llm_callback :: (%{
  system: String.t(),
  messages: [map()],
  turn: integer(),
  prompt: String.t(),
  tool_names: [String.t()],
  llm_opts: map()
} -> {:ok, String.t()} | {:error, term()})

# Example implementation structure
fn %{system: system, messages: messages} = params ->
  # Optional fields available in params:
  # :turn, :prompt, :tool_names, :llm_opts
  
  # Call your LLM provider
  {:ok, response_text}
end
```

### ReqLLM Example

```elixir
# Add {:req_llm, "~> 1.0"} to your deps
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
PtcRunner.SubAgent.delegate(prompt, llm: llm, tools: tools)

# With options
PtcRunner.SubAgent.delegate(prompt,
  llm: llm,
  tools: tools,
  llm_opts: %{temperature: 0.2}
)
```

---

## Example: Email Processing Pipeline (with Firewall)

This example shows how the **Context Firewall** works via signatures. We pass IDs between steps without ever exposing the full email content to the parent agent.

```elixir
# Step 1: Find urgent emails (Firewalled)
# Use '_' to hide heavy email content from the prompt
signature = "() -> {summary :string, count :int, _email_ids [:int]}"

{:ok, step1} = PtcRunner.SubAgent.delegate(
  "Find all urgent emails",
  signature: signature,
  tools: email_tools,
  llm: llm
)

IO.puts(step1.return.summary)
#=> "Found 2 urgent emails: Server Down, Customer Complaint"

# Step 2: Draft responses using Linear Chaining
# We pass Step 1's return data AND its signature. 
# The system automatically extracts the 'return' part of Step 1's signature 
# to populate the Data Inventory for Step 2.
{:ok, step2} = PtcRunner.SubAgent.delegate(
  "Draft brief acknowledgment replies for these {{count}} emails",
  context: step1.return,
  context_signature: step1.signature,
  tools: drafting_tools,
  llm: llm
)

IO.puts(step2.return.summary)
#=> "Created 2 draft replies ready for review"
```

### Usability: Shorthand Signatures

If your mission has no input parameters (common for top-level delegations), you can omit the `() -> ` prefix:

```elixir
# These are equivalent:
signature: "() -> {summary :string}"
signature: "{summary :string}"
```

### Usability: Auto-Chaining

Passing a previous `Step` struct directly to the `context:` option automatically sets both the `context` and the `context_signature`:

```elixir
# Instead of this:
delegate(prompt, context: step1.return, context_signature: step1.signature)

# You can do this:
delegate(prompt, context: step1)
```
 
### The Firewall Convention (`_` prefix)

Fields prefixed with `_` in a signature are "firewalled." They follow these visibility rules:

- **✓ Available in Lisp context**: Fully accessible via `ctx/_field_name`.
- **✓ Transferred between steps**: Preserved when passing `context` between SubAgents.
- **✓ Available to Elixir code**: When calling `delegate/2` directly from Elixir, firewalled fields are included in `step.return`.
- **✗ Hidden from LLM prompt text**: Shown as `<Firewalled>` in conversation history.
- **✗ Hidden from parent LLM schema**: If a SubAgent is used as a tool by another LLM, its firewalled fields are omitted from the parent LLM's view of the tool's return shape.

**Key insight:** Firewalls protect LLM context windows, not Elixir code. Your application can always access firewalled data; the firewall only prevents LLMs from seeing the raw values in their conversation history.

**The Firewall at work:**
- In Step 2, the LLM **knows** there are 2 emails (public data).
- The LLM **cannot see** the list of IDs (hidden via `_`), but it can use the variable `ctx/_email_ids` in its tool calls because they are present in the Lisp context.
- The parent orchestrator stays lean, only handling small summaries and typed keys.

**What the Step 2 LLM sees in its prompt:**
 
When `context_signature` is provided, the system:
 
1. **Parses the return portion** of the provided signature.
2. **Generates a "Data Inventory"** section in the prompt.
3. **Enables the LLM to reason about types** and keys without seeing the actual values.
 
Notice that Step 2's LLM knows `_email_ids` is a list of integers, even though it can't see the actual values in the text prompt. This allows it to confidently generate code like `(call "draft_reply" {:id (first ctx/_email_ids)})`.
 
- By passing `context_signature`, Step 2 also received the **type metadata**, enabling it to reason about the data it was processing.

---

## The System Prompt Structure

To understand exactly what the LLM receives, here is the structure of the system prompt generated by the SubAgent:

1.  **Role & Purpose**: Defines the agent as a PTC-Lisp generator.
2.  **Environment Rules**: Boundaries for using `clojure` blocks.
3.  **Data Inventory**: Generated from the `context_signature`.
    ```text
    DATA INVENTORY (Available in ctx/):
    - results ([:map]): List of research results.
    - _token ([:string]): Firewalled access tokens.
    ```
4.  **Tools**: Generated from the `tools` map.
    ```text
    AVAILABLE TOOLS:
    - search(query :string) -> [:map]
    - return(data :any) -> stops loop
    - fail(params {reason :keyword, message :string, op :string?, details :map?}) -> stops loop
    ```
5.  **PTC-Lisp Language Instructions**: A technical reference explaining the syntax (Clojure-subset), built-in functions (`call`, `ctx/`, `memory/`), and control flow (`if`, `let`, `do`, `fn`).
6.  **Output Format**: Strict instructions to provide thought reasoning followed by a single ` ```clojure ` block containing the program.
7.  **Boundary Reminders**: Text to discourage conversational filler and remind the agent of its active mission.

---

## Core Concepts

### Tools & Model Registry

Tools are functions the sub-agent can call. Provide them as a map.

#### Model Registry

You can specify models using aliases like `:haiku` or `:gpt4`. These are resolved via the `PtcRunner.Config` registry:

```elixir
# Configuration
config :ptc_runner, :models, %{
  haiku: [model: "claude-3-haiku-20240307", provider: :anthropic],
  gpt4: [model: "gpt-4-turbo", provider: :openai]
}

# Usage in LLMTool
LLMTool.new(
  prompt: "Summarize this",
  signature: "{summary :string}",
  llm: :haiku
)
```

#### Template Syntax & Validation

The `prompt` and `LLMTool` prompts use a Mustache-style template syntax for context interpolation.

**Critical Rule**: Every `{{placeholder}}` in the prompt MUST have a matching parameter in the `signature`. The system validates this **immediately** when `delegate/2` or `as_tool/1` is called. If a placeholder is missing from the provided context or signature, it will return an error or raise before any LLM call is made.

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

#### Template Syntax
 
 The `prompt` and `LLMTool` prompts use a Mustache-style template syntax for context interpolation:
 
 | Syntax | Description | Example |
 | :--- | :--- | :--- |
 | `{{var}}` | Simple interpolation | `Find emails for {{user_name}}` |
 | `{{a.b}}` | Dot notation for nested access | `Hello {{user.first_name}}` |
 | `{{#list}}` | Start iteration over a collection | `{{#emails}} - {{subject}} {{/emails}}` |
 | `{{/list}}` | End iteration | |

> **Note**: If a list is empty, the entire `{{#list}}...{{/list}}` block renders as an **empty string**.
 
Every `{{key}}` in the `prompt` MUST have a matching parameter in the `signature`. This contract ensures that the LLM is always provided with the necessary context to fulfill its mission.
 
```elixir
prompt: "Find emails for {{user.name}} about {{topic}}"
signature: "(user {name :string}, topic :string) -> {summary :string}"
#           ^^^^                  ^^^^^
#           Every placeholder MUST match a signature input parameter.
```
 
The orchestrator (or parent agent) must provide these arguments in the tool call:
`(call "my-agent" {:user {:name "Alice"} :topic "billing"})`

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

### Tool Definition Comparison
 
Depending on your use case, you can define tools in several ways:
 
| Syntax | When to Use |
| :--- | :--- |
| `&Module.fun/n` | Existing Elixir functions with `@spec`. |
| `{&fun/n, "..."}` | When you need to override or simplify the auto-extracted spec. |
| `%{prompt:, signature:}` | Single-turn "Judgment" tools or "SubAgents" as tools. |
| `SubAgent.as_tool(...)` | Pre-defined, complex SubAgents used for hierarchical delegation. |
 
#### The Unified Tool Model

Internally, all tool definitions (function refs, strings, structs) are normalized into a single `Tool` structure. This ensures that validation and schema generation are consistent across all patterns.

The string shorthand `"(...) -> ..."` is a convenient way to populate a `ToolSpec` without verbose Elixir syntax:

```elixir
tools = %{
  # These are equivalent internally:
  "search" => {
    &MyApp.search/2,
    "(query :string, limit :int) -> [{:id :int :title :string}]"
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
PtcRunner.SubAgent.delegate(prompt,
  tools: tools,
  signature_validation: :enabled  # default
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

PtcRunner uses a **hybrid schema system** based on Malli. See [malli-schema.md](malli-schema.md) for the full specification.

**Shorthand Syntax (recommended):**

```
Primitives:
  :string :int :float :bool :keyword :any

Collections:
  [:int]                          ; list of ints
  [{:id :int :name :string}]      ; list of maps

Maps:
  {:id :int :name :string}        ; map with typed fields
  :map                            ; any map

Optional (use ? suffix):
  {:id :int :email :string?}      ; email is optional (nil allowed)

Nested:
  {:customer {:id :int :address {:city :string :zip :string}}}
```

**Malli Data (advanced):**

For schemas that shorthand can't express (enums, unions, refinements):

```elixir
# Enum types
signature: [:=> [:cat :string] [:map [:status [:enum "low" "medium" "high"]]]]

# Constrained values
signature: [:=> [:cat] [:map [:score [:and :int [:> 0] [:< 100]]]]]
```

#### SubAgent-as-Tool Contracts
 
The "Context Firewall" relies on the **Signature** to define the bridge between agents.
 
#### 1. In the Signature
 
Use a `_` prefix for any field that should be firewalled.
 
```elixir
email_agent = %{
  prompt: "Find and filter emails for {{user.name}}",
  signature: "(user {name :string}) -> {summary :string, count :int, _email_ids [:int]}",
  llm: llm,
  tools: email_tools
}
```
 
When used as a tool, the parent LLM only sees the public parts of the signature:
```
email_agent(user {name :string}) -> {summary :string, count :int}
```
Notice that `email_ids` is hidden from the parent's text inventory because of the `_` marker, but it remains available for Lisp-level chaining.
 
#### Dynamic `delegate` and Planning
 
For dynamic agent creation, the orchestrator can provide tools that wrap `delegate/2` with specific signatures, or a generic meta-tool:
 
```elixir
# A generic meta-tool with a standard return structure
tools = %{
  "run_sub_agent" => %{
      prompt: "Handle the following mission: {{prompt}}",
      signature: "(prompt :string, tools [:string], context :map) -> {return :map}",
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

### Context & State

The sub-agent has access to several built-in context variables that help manage state and data flow across multi-turn executions.

#### `ctx/key`

Any values passed to `context:` in the `delegate/2` call are available via the `ctx/` prefix:

```elixir
{:ok, result} = PtcRunner.SubAgent.delegate(
  "Get details for this order",
  llm: llm,
  tools: order_tools,
  context: %{order_id: "ORD-12345"}
)
```

Usage in PTC-Lisp: `(call "get_order" {:id ctx/order_id})`.

#### `ctx/fail`
 
If the previous turn failed (syntax error, tool arity mismatches, or **Tool Validation Errors**), the details are available in `ctx/fail`. 
 
```clojure
(if ctx/fail
  (call "cleanup" {:failed_op (:op ctx/fail)})
  (call "proceed" ctx/items))
```
 
**Note**: The error is also automatically appended to the LLM's message history as text, but `ctx/fail` allows the *program* to branch based on failure.

#### `ctx/fail` structure when a turn fails:
```elixir
%{
  reason: :parse_error | :tool_error | :validation_error,
  message: "Human-readable error description",
  op: "tool_name" | nil,  # If tool-related
  details: %{}            # Additional context (e.g., validation paths)
}
```

---

### Error Handling & Escalation
 
SubAgents handle errors at three different levels.
 
#### 1. Turn Errors (Recoverable)
 
Errors like Lisp syntax mistakes, tool arity mismatches, or **Tool Validation Errors** are fed back to the SubAgent's LLM. The LLM sees the error in its history and can use `ctx/fail` to adapt.
 
#### 2. Mission Failures (Escalatable)
 
Sometimes a SubAgent realize it cannot complete the mission (e.g., "Database connection refused" or "No user found").
 
Use the built-in **`fail` tool** to explicitly exit the loop:
 
```clojure
(let [user (call "get_user" {:id 123})]
  (if (nil? user)
    (call "fail" {:reason :not_found :message "User 123 does not exist"})
    (call "process" user)))
```
 
**Result**:
- The `Loop` stops immediately.
- `delegate/2` returns `{:error, step}` where `step.fail` contains the error data.
 
#### 3. Built-in Tools: `return` and `fail`
 
These tools are the only way for the agent to terminate its mission.
 
- **`return`**: Fulfills the mission contract.
  - **Signature**: `return(data :any)`
  - **Validation**: The `data` value MUST match the output portion of the agent's `signature`.
  - **Result**: `{:ok, %PtcRunner.Step{return: data}}`
 
- **`fail`**: Terminates the mission with an error.
  - **Signature**: `fail(params {reason :keyword, message :string, op :string?, details :map?})`
  - **Result**: `{:error, %PtcRunner.Step{fail: %{reason: atom, message: string, op: string | nil, details: map}}}`
 
#### 4. Hard Crashes
 
Programming bugs in your Elixir tool functions (crashes) follow the "Let it crash" philosophy. They are returned as internal errors and should be fixed by a developer.





### Memory (Scoped Scratchpad)
 
Each agent has private memory that persists across turns within a single `delegate` call. This is accessible via the `memory/` prefix.
 
```elixir
# In PTC-Lisp, the agent can:
(memory/put :cached-data result)   # Store a value
(memory/get :cached-data)          # Retrieve it later
memory/cached-data                 # Shorthand access
```
 
**Important:** Memory is scoped per-agent. SubAgents do not share memory with their parent or siblings.

### Available PTC-Lisp Functions

SubAgents use PTC-Lisp, a Clojure-inspired DSL. Here are the available functions:

**Core Functions:**
- `call` - Call a tool: `(call "tool_name" {:arg value})`
- `ctx/key` - Access context values: `ctx/user_id`
- `memory/put`, `memory/get` - Scoped memory operations
- `do` - Sequential execution: `(do expr1 expr2)`
- `let` - Local bindings: `(let [x 1 y 2] (+ x y))`
- `if`, `when`, `cond` - Conditionals
- `fn` - Anonymous functions: `(fn [x] (* x 2))`

**Collection Functions:**
- `map`, `mapv` - Transform collections
- `filter`, `remove` - Filter collections
- `reduce` - Fold collections
- `first`, `second`, `last`, `nth` - Access elements
- `count`, `empty?` - Collection info
- `conj`, `cons` - Add elements
- `concat` - Join collections
- `sort`, `sort-by` - Sort collections
- `group-by` - Group by key function
- `take`, `drop` - Subsequences

**Map Functions:**
- `get`, `get-in` - Access values
- `assoc`, `assoc-in` - Add/update keys
- `dissoc` - Remove keys
- `keys`, `vals` - Extract keys/values
- `merge` - Combine maps
- `select-keys` - Pick specific keys

**String Functions:**
- `str` - Concatenate strings
- `str/includes?` - Check substring
- `str/starts-with?`, `str/ends-with?` - Check prefix/suffix
- `str/split`, `str/join` - Split/join strings
- `str/trim` - Remove whitespace

**Math & Comparison:**
- `+`, `-`, `*`, `/`, `mod` - Arithmetic
- `<`, `>`, `<=`, `>=`, `=`, `not=` - Comparison
- `and`, `or`, `not` - Logical

**Type Conversion:**
- `parse-long` - String to integer (returns nil on failure)
- `parse-double` - String to float (returns nil on failure)

**Predicates:**
- `nil?`, `some?` - Nil checks
- `number?`, `string?`, `map?`, `vector?` - Type checks

> **Note:** For the complete language reference, see [PtcRunner Guide](../guide.md).

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

## Multi-Turn Patterns (ReAct)
 
 The SubAgent loop naturally supports the **ReAct pattern** (Reason + Act). The agent can execute multiple programs, observe results, and adapt its approach across turns.
 
 ### The Step-wise loop
 
 The `Loop` treats every turn as a **Step**. The key to its power is **Implicit Chaining**: the result of Turn N is automatically merged into the context (`ctx/`) of Turn N+1.
  
 #### How Merging Works
  
 1. **Lisp Execute**: LLM provides a program, it runs and returns data.
 2. **Context Merge**: That data is added to the `ctx/` namespace.
 3. **Data Inventory**: The system updates the "Data Inventory" in the next prompt so the LLM knows which new keys are available.
  
 ### Example: Discovery & Reasoning
  
 In this example, we use a search tool and the agent iterates until it finds what it needs.
  
 **Tool Signature**:
 `search_emails(query :string) -> [{id :int, subject :string, _body :string}]`
  
 ```elixir
 # Agent Signature: () -> {summary :string, _ids [:int]}
 {:ok, step} = PtcRunner.SubAgent.delegate(
   "Find urgent emails from Acme",
   signature: "() -> {summary :string, _ids [:int]}",
   llm: llm,
   tools: %{
     "search_emails" => &MyApp.Email.search/1,
     "count_results" => &MyApp.Email.count/1
   }
 )
 ```
  
 **Turn 1: Discovery**
  
 ```clojure
 ;; Turn 1: Discovery
 ;; Return a map to merge results into ctx/results
 {:results (call "search_emails" {:query "Acme Corp"})}
 ```
  
 **What the LLM sees in the prompt:**
 > **Program Result:**
 > `{:results [{id: 101, subject: "Urgent...", _body: <Firewalled>}, {id: 102, ...}]}`
 > _(8 more items omitted. Full dataset available to your next program in `ctx/results`)_
  
 **Turn 2: Reasoning & Refinement**
 Notice that even though the **LLM prompt** was trimmed, the **Lisp context** (`ctx/results`) contains all 10 items, including the full `body` text.
  
 ```clojure
 ;; The LLM can process all results directly from ctx/results
 (let [urgent (filter (fn [e] (str/includes? (:subject e) "Urgent")) ctx/results)]
   (if (empty? urgent)
      "I found emails but none are urgent. Let me try a broader search..."
      (do
        ;; Store the full urgent set in memory
        (memory/put :urgent_emails urgent)
        ;; Return public summary + firewalled IDs
        (call "return" {
          :summary (str "Found " (count urgent) " urgent emails")
          :_ids (mapv :id urgent)
        })))
 ```
 
### Public vs Private Visibility
 
To protect your context window and ensure data privacy, the loop maintains two distinct views of the mission state:
 
1.  **Lisp Program (Full View)**: The PTC-Lisp evaluator has access to the *entire* dataset. This includes heavy fields (like email bodies), sensitive data (firewalled via `_`), and the complete list of search results.
2.  **LLM Prompt (Public View)**: The conversation history only shows a **Context-Safe Preview**. This view is filtered by the signature and automatically **Omitted** (trimmed) if it exceeds safety limits.
 
#### Visibility Rules
  
 | Feature | Lisp Context (`ctx/`) | LLM Text History |
 | :--- | :--- | :--- |
 | **Normal Fields** | Full Value | Visible |
 | **Firewalled (`_`)** | Full Value | *Hidden* (Shown as `<Firewalled>`) |
 | **Large Lists** | Full List | *Omitted Sample* (e.g., first 2 items) |
 | **Large Strings** | Full String | *Omitted Snippet* (Trimmed after N bytes) |
 | **Memory (`memory/`)** | Full Value | *Hidden* |
 
 When data is omitted, the loop automatically appends a system notification to the LLM:
 *" ... [98 more items omitted. Full data available in ctx/results]"*
 
 This ensures the LLM knows it can still process the full dataset using PTC-Lisp.
 
> **Configurable Limits**: Truncation behavior is controlled via the `:prompt_limit` option.
 
### Strict Termination & The Boundary Reminder
 
Because the mission only ends on `return` or `fail`, the LLM cannot simply "talk" its way out of a mission. If the LLM provides reasoning text without a code block or a terminal tool call:
 
1. The loop records the reasoning.
2. The loop appends a **Boundary Reminder**: *"Your mission is still active. Please provide a PTC-Lisp program or call 'return' to finish."*
3. The LLM is forced to provide a functional result to Elixir.

---

## LLM-Powered Tools

Sometimes a tool needs LLM judgment—classification, summarization, or evaluation. Use `LLMTool.new/1` to create tools that call an LLM:

```elixir
alias PtcRunner.SubAgent.LLMTool

tools = %{
  "list_emails" => &MyApp.Email.list/1,

  # LLM tool - uses the same LLM as the SubAgent by default
  "evaluate_importance" => LLMTool.new(
    prompt: """
    Evaluate if this email requires immediate attention.
 
    Consider:
    - Is it from a VIP customer? (Tier: {{customer_tier}})
    - Is it about billing or money?
    - Does it express urgency or frustration?
 
    Email subject: {{email.subject}}
    Email body: {{email.body}}
    """,
    signature: "(email {subject :string, body :string}, customer_tier :string) -> {important :bool, priority :int, reason :string}"
  )
}
```

### Type Signatures

The `:signature` is the **single source of truth** for both inputs and outputs. `LLMTool` validates that template placeholders match the signature:

```
## Tools you can call
- list_emails(limit :int) -> [{:id :int :subject :string :body :string}]
- evaluate_importance(email {:subject :string :body :string}, customer_tier :string) -> {:important :bool :priority :int :reason :string}
```

The main agent sees typed inputs (from the signature) and typed outputs (from the signature), enabling it to reason about data flow correctly.

### Template Validation

Template placeholders are validated against the signature at registration time:

```elixir
# ✓ Valid: placeholders match signature
LLMTool.new(
  prompt: "Analyze {{user.name}} (tier: {{tier}})",
  signature: "(user {name :string}, tier :string) -> {analysis :string}"
)

# ✗ Invalid: placeholder not in signature
LLMTool.new(
  prompt: "Analyze {{user.email}}",  # 'email' not in signature!
  signature: "(user {name :string}) -> {analysis :string}"
)
# => {:error, {:template_error, "placeholder {{user.email}} not found in signature; user has fields: name"}}

# ✓ Valid: unused signature params are allowed (e.g., for hidden context)
LLMTool.new(
  prompt: "Hello {{name}}",  # 'debug_id' not used in prompt, but that's OK
  signature: "(name :string, debug_id :int) -> {greeting :string}"
)
```

### Compile-Time Validation with `~PROMPT`

For compile-time placeholder extraction, use the `~PROMPT` sigil:

```elixir
import PtcRunner.SubAgent.Sigils

# Compile error if {{...}} syntax is malformed
@importance_prompt ~PROMPT"""
Evaluate if this email requires immediate attention.

Consider:
- Is it from a VIP customer? (Tier: {{customer_tier}})
- Does it express urgency?

Email subject: {{email.subject}}
Email body: {{email.body}}
"""

tools = %{
  "evaluate_importance" => LLMTool.new(
    prompt: @importance_prompt,
    signature: "(email {subject :string, body :string}, customer_tier :string) -> {important :bool, reason :string}"
  )
}
```

The sigil extracts placeholders at compile time, providing:
- Compile-time syntax validation of `{{...}}` patterns
- Faster runtime validation (placeholders pre-extracted)
- IDE support through struct-based introspection

### Using LLM Tools in Multi-Turn Flow
 
```clojure
;; Turn 1: Get emails and save to ctx/emails
{:emails (call "list_emails" {:limit 20})}
```
 
```clojure
;; Turn 2: Evaluate each one using LLM judgment
(let [emails ctx/emails]
  {:evaluated 
    (mapv (fn [e]
            (assoc e :eval
              (call "evaluate_importance"
                {:email e :customer_tier "Silver"})))
          emails)})
```
 
```clojure
;; Turn 3: Filter to important ones and summarize
(let [evaluated ctx/evaluated
      important (filter #(:important (:eval %)) evaluated)]
  (call "return" {
    :count (count important)
    :top_priority (first (sort-by #(- (:priority (:eval %))) important))
  }))
```

### LLM Selection

By default, LLM tools use the same LLM as the SubAgent. You can specify a different model:

```elixir
tools = %{
  # Uses caller's LLM (default)
  "deep_analysis" => LLMTool.new(
    prompt: "...",
    signature: "() -> {result :string}"
  ),

  # Uses a cheaper/faster model for simple classification
  "quick_triage" => LLMTool.new(
    prompt: "Is '{{subject}}' urgent? Answer: urgent/normal/low",
    signature: "(subject :string) -> {priority :string}",
    llm: :haiku
  ),

  # Uses a specific LLM callback
  "specialized" => LLMTool.new(
    prompt: "...",
    signature: "() -> {result :map}",
    llm: my_custom_llm_callback
  )
}
```

### Batch Classification

For efficiency, process multiple items in one LLM call:

```elixir
  "classify_batch" => LLMTool.new(
    prompt: """
    Classify each email by urgency.
 
    Emails:
    {{#emails}}
    - ID {{id}}: "{{subject}}" from {{from}}
    {{/emails}}
 
    Return a list with urgency for each email ID.
    """,
    signature: "(emails [{id :int, subject :string, from :string}]) -> [{id :int, urgency :string, reason :string}]"
  )
```

```clojure
;; Single LLM call to classify all emails
(let [emails (call "list_emails" {:limit 50})
      classifications (call "classify_batch" {:emails emails})]
  ;; Merge classifications back
  (mapv (fn [e c] (assoc e :classification c)) emails classifications))
```

> **Warning on Batch Correspondence**: When using batch tools, the system does not automatically verify that the LLM returned exactly one result for each input ID in the correct order. The tool's `signature` should return a list of maps including the `id`, and the caller should use PTC-Lisp logic (like `filter` or `find`) to correctly associate results if order isn't guaranteed.

### Full Example: Smart Email Triage

```elixir
llm = MyApp.LLM.callback(:sonnet)

tools = %{
  "list_emails" => &MyApp.Email.list/1,
  "get_customer" => &MyApp.CRM.get_customer/1,
  "archive_email" => &MyApp.Email.archive/1,

  # Expensive model to evaluate importance with context
  "evaluate" => LLMTool.new(
    prompt: """
    Should this email be flagged for immediate response?
    Customer: {{customer.name}}
    Subject: {{email.subject}}
    """,
    signature: "(customer {name :string}, email {subject :string}) -> {flag :bool, reason :string}"
  )
}
 
{:ok, step} = PtcRunner.SubAgent.delegate(
  "Review my inbox. Archive spam, flag anything urgent from enterprise customers.",
  signature: "() -> {summary :string}",
  llm: llm,
  tools: tools
)
```

The agent can now:
1. List emails
2. Quick-filter spam with cheap model
3. Look up customer data for non-spam
4. Use expensive model to evaluate importance with context
5. Take actions (archive, flag)
6. Iterate until inbox is processed

---

## Using SubAgents as Tools

Wrap sub-agents as tools so a main agent can orchestrate them:

```elixir
alias PtcRunner.SubAgent.LLMTool
llm = MyApp.LLM.callback()

# Create sub-agent tools
main_tools = %{
  "customer-finder" => PtcRunner.SubAgent.as_tool(
    prompt: "Find the customer ID for the person described as: {{description}}",
    signature: "(description :string) -> {customer_id :int}",
    llm: llm,
    tools: %{"search_customers" => &MyApp.CRM.search/1}
  ),
 
  "order-fetcher" => PtcRunner.SubAgent.as_tool(
    prompt: "Get all recent orders for customer {{customer_id}}",
    signature: "(customer_id :int) -> {orders [:map]}",
    llm: llm,
    tools: %{"list_orders" => &MyApp.Orders.list/1}
  )
}

# Now the main agent can orchestrate these sub-agents
{:ok, step} = PtcRunner.SubAgent.delegate(
  "Find the top customer and get their orders",
  signature: "() -> {summary :string}",
  llm: llm,
  tools: main_tools
)
```

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
    prompt: "Find all urgent emails that need attention",
    signature: "() -> {count :int, _email_ids [:int]}",
    llm: llm,
    tools: email_tools
  ),
  "email-reader" => PtcRunner.SubAgent.as_tool(
    prompt: "Read the full body content for emails: {{email_ids}}",
    signature: "(email_ids [:int]) -> {bodies :map}",
    llm: llm,
    tools: %{"read_email" => &MyApp.read_email/1}
  ),
  "reply-drafter" => PtcRunner.SubAgent.as_tool(
    prompt: "Draft acknowledgment replies for the email bodies: {{bodies}}",
    signature: "(bodies :map) -> {draft_ids [:int]}",
    llm: llm,
    tools: %{"draft_reply" => &MyApp.draft_reply/1}
  )
}

{:ok, result} = PtcRunner.SubAgent.delegate(
  """
  Create a plan to:
  1. Find all urgent emails
  2. Read their full bodies
  3. Draft acknowledgment replies

  Use the "create_plan" tool to submit your plan.
  Each step should have: :id, :prompt, :tools, :needs (dependencies), :output
  """,
  llm: llm,
  tools: planning_tools,
  tool_catalog: domain_tools  # Schemas visible, not callable
)
```

**What the LLM sees in its system prompt:**

```
## Tools you can call
- create_plan(steps [{id :keyword, prompt :string, tools [:string], needs [:keyword], output :map}]) -> {status :string, plan_id :string}
 
## Tools available for planning (do not call directly)
- email-finder: (prompt :string) -> {summary :string, count :int, _email_ids [:int]}
- email-reader: (prompt :string, email_ids [:int]) -> {bodies :map}
- reply-drafter: (prompt :string, bodies :map) -> {draft_ids [:int]}
```
 
The LLM can see the exact input/output types of each tool, enabling it to plan correct data flow between steps.

**Observed LLM output** (Gemini 2.5 Flash):

```elixir
%{
  goal: "Find urgent emails, read bodies, draft acknowledgments",
  steps: [
    %{id: "find_urgent_emails",
      prompt: "Find all urgent emails",
      tools: ["email-finder"],
      needs: [],
      output: %{urgent_emails: "List of urgent email IDs"}},
    %{id: "read_email_bodies",
      prompt: "Read full body for each urgent email",
      tools: ["email-reader"],
      needs: ["find_urgent_emails"],
      output: %{email_bodies: "Map of email ID to body"}},
    %{id: "draft_acknowledgments",
      prompt: "Draft acknowledgment for each email",
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
      {:ok, step} = PtcRunner.SubAgent.delegate(
        step.prompt,
        llm: llm,
        tools: tools,
        context: step_context
      )
 
      # Merge returned data into context
      Map.merge(context, step.return)
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
│  Available tool: spawn_agent(prompt, tools, context)                     │
│                                                                          │
│  LLM decides:                                                            │
│    1. I need email tools -> spawn_agent({prompt: "Find urgent...",       │
│                                         tools: ["email"]})              │
│    2. I need calendar tools -> spawn_agent({prompt: "Schedule...",       │
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

  @type spawn_result :: %{return: map()}

  @spec spawn_agent(map(), map(), llm()) :: spawn_result()
  def spawn_agent(args, tool_catalog, llm_callback) do
    tool_names = args["tools"] || []
    
    # 1. Resolve selected tool sets from catalog
    selected_tools =
      tool_names
      |> Enum.map(&Map.get(tool_catalog, &1, %{}))
      |> Enum.reduce(%{}, &Map.merge/2)

    # 2. Delegate to an isolated SubAgent
    {:ok, step} = PtcRunner.SubAgent.delegate(
      args["prompt"],
      llm: llm_callback,
      tools: selected_tools,
      context: args["context"] || %{}
    )
 
    # 3. Return only the distilled mission results
    step.return
  end
end

# Register the meta-tool
# Note: we pass the catalog and llm into the tool via closure
tools = %{
  "spawn_agent" => fn args -> 
    MyApp.AgentTools.spawn_agent(args, @tool_catalog, MyApp.LLM.callback())
  end
}
```

The `@spec` enables auto-extraction. The LLM sees:
```
spawn_agent(args :map) -> {summary :string, return :map}
```

**Without @spec**: If you use an anonymous function or a function without `@spec`, the library warns and continues without validation.

```elixir
# To provide hints manually:
tools = %{
  "spawn_agent" => {
    fn args -> ... end,
    "(prompt :string, tools [:string], context :map) -> {summary :string, return :map}"
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
# (let [search (call "spawn_agent" {:prompt "Find urgent emails"
#                                   :tools ["email"]})
#       meetings (call "spawn_agent" {:prompt "Schedule meetings"
#                                     :tools ["calendar"]
#                                     :context search})]
#   {:emails (:email_ids search) :meetings meetings})
```
 
#### as_tool vs spawn_agent

| Aspect | `spawn_agent` (dynamic) | `as_tool` (pre-defined) |
|--------|-------------------------|-------------------------
| Tool selection | LLM chooses at runtime | Fixed at definition |
| Flexibility | High - any combination | Low - single purpose |
| Predictability | Lower | Higher |
| Use case | Exploratory, novel tasks | Production, known domains |

#### Considerations

- **Trust boundary**: The parent LLM controls which tool sets are available via `tool_catalog`. It can't request tools not in the catalog.
- **Context passing**: Use `:context` to pass results between spawned agents.
- **Tracing**: Each spawned agent has its own trace, nested in the parent's trace.

**When to use**: Exploratory tasks, user-defined automation, when you can't predict which tool combinations are needed.

### Pattern 2: Pre-defined SubAgents

Wrap known SubAgent configurations as tools upfront:

```elixir
# Pre-defined SubAgents for known domains
tools = %{
  "email-agent" => PtcRunner.SubAgent.as_tool(
    prompt: "Find all urgent emails that need follow-up",
    signature: "() -> {_email_ids [:int]}",
    llm: llm,
    tools: email_tools
  ),

  "calendar-agent" => PtcRunner.SubAgent.as_tool(
    prompt: "Schedule follow-up meetings for emails: {{email_ids}}",
    signature: "(email_ids [:int]) -> {_meeting_ids [:int]}",
    llm: llm,
    tools: calendar_tools
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
  def hybrid(prompt, opts) do
    llm = Keyword.fetch!(opts, :llm)
    tools = Keyword.fetch!(opts, :tools)
 
    # Phase 1: Planning (no tools)
    {:ok, plan} = PtcRunner.SubAgent.delegate(
      """
      Prompt: #{prompt}
 
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
      Execute: #{prompt}
 
      Your plan:
      #{plan.return.summary}
 
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
      {:ok, step} = PtcRunner.SubAgent.delegate(
        step.prompt,
        llm: llm,
        tools: tools,
        context: step_context
      )
 
      # Merge results into context for next step
      Map.merge(context, step.return || %{})
    end)
  end
end

# Usage: First, have LLM generate a plan structure
# Then execute it deterministically
plan = %{
  steps: [
    %{id: :find_emails, prompt: "Find urgent emails",
      tools: [:email], needs: []},
    %{id: :draft_replies, prompt: "Draft acknowledgments",
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

All patterns compose from the same primitives: `delegate/2`, `LLMTool` (implicit), and `memory/*`.

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
  program: "(call \"customer-finder\" {:prompt \"find top customer\"})",
  tool_calls: [
    %{name: "customer-finder",
      args: %{prompt: "find top customer"},
      result: %{
        summary: "Top customer is Top Client",
        return: %{customer_id: 501},
        trace: [...]  # SubAgent's internal trace
      }}
  ]
}
```

### Usage Accounting

Token usage and execution metrics are tracked and aggregated:

```elixir
step.usage
#=> %{
#     duration_ms: 2340,
#     memory_bytes: 102400,
#     input_tokens: 15442,
#     output_tokens: 1108,
#     total_tokens: 16550,
#     requests: 5
#   }
```

---

## API Reference

See [specification.md](specification.md) for full type definitions.

### PtcRunner.SubAgent.delegate/2

```elixir
{:ok, step} = PtcRunner.SubAgent.delegate(prompt, opts)
```

**Required Options:**

| Option | Type | Description |
|--------|------|-------------|
| `llm` | function | LLM callback `fn %{system:, messages:} -> {:ok, text}` |

**Optional:**

| Option | Type | Description |
|--------|------|-------------|
| `signature` | string | Desired return structure |
| `tools` | map | Callable tools |
| `tool_catalog`| map | Schemas for planning |
| `context` | map | Input available as `ctx/` |
| `context_signature` | string | Type info for `context` |
| `mission_timeout`| integer | Max ms for total mission |
| `llm_retry` | map | LLM callback retry config |
| `prompt_limit` | map | Truncation limits for conversation view |

**Quick Reference: Option Defaults**

| Option | Default |
| :--- | :--- |
| `max_turns` | `5` |
| `timeout` | `5000` |
| `mission_timeout` | `60000` |
| `prompt_limit` | `%{list: 5, string: 1000}` |
| `llm_retry` | `%{max_attempts: 3, backoff: :exponential}` |

**Return value (`{:ok, step}` or `{:error, step}`):**
 
```elixir
%PtcRunner.Step{
  return: map(),       # Data matching signature
  fail: map(),         # Error if agent called "fail"
  signature: string(), # The contract used
  memory: map(),       # Final memory state
  usage: map(),        # Token/resource usage
  trace: list()        # Turn-by-turn history
}
```

### PtcRunner.SubAgent.as_tool/1

Wrap a SubAgent configuration as a callable tool:

```elixir
tool = PtcRunner.SubAgent.as_tool(
  prompt: "Find the best matching item",
  signature: "() -> {id :int}",
  llm: llm,
  tools: %{"search" => &MyApp.search/1}
)
```

The returned function takes a map of parameters defined in its signature and returns the `return` value from the mission. It **raises** if the mission fails.

---

## Derive & Apply Pattern (Planned)

For highly repetitive tasks (batch processing), you can separate the **cognitive step** (writing the logic) from the **execution step** (running it at scale).

### 1. Derive Phase
The LLM analyzes a sample of your data and generates a pure PTC-Lisp function that fulfills a signature.

```elixir
# derive a reusable tool once
{:ok, compiled} = PtcRunner.SubAgent.compile(
  mission: "Extract anomaly score and reasoning from report",
  signature: "(report :map) -> {score :float, reason :string}",
  llm: llm,
  sample: sample_reports  # helps LLM see the actual data structure
)

# Inspect the generated logic
IO.puts(compiled.source)
#=> (fn [report] (let [...] {...}))
```

### 2. Validation (Optional)
Before scaling, you can validate the derived function against a set of test cases to ensure it behaves correctly across edge cases.

```elixir
# Returns :ok or {:error, failed_cases}
case PtcRunner.SubAgent.validate_compiled(compiled, test_reports) do
  :ok -> 
    IO.puts("Agent verified!")
  {:error, failures} ->
    Logger.warning("Agent failed on #{length(failures)} test cases")
end
```

### 3. Apply Phase
You now have a plain, pre-bound Elixir function (`compiled.execute`) that you can run 1,000 times without ever calling an LLM again.

```elixir
# zero LLM tokens/cost per execution
results = Enum.map(all_reports, &compiled.execute/1)

# For multiple parameters, pass a map:
# Signature: (report :map, threshold :float) -> ...
# compiled.execute(%{report: report, threshold: 0.5})
```

### Persistence (Planned)
Since the derived agent is just code, you can save it for version control or reuse:

```elixir
# Save the inspectable Lisp source
File.write!("agents/anomaly_scorer.lisp", compiled.source)

# Load and rebuild later
{:ok, compiled} = PtcRunner.SubAgent.load(
  File.read!("agents/anomaly_scorer.lisp"),
  signature: "(report :map) -> {score :float, reason :string}"
)
```

---

## Glossary

- **Mission**: A task delegated to a SubAgent.
- **Signature**: A functional contract defining inputs (`params`) and outputs (`returns`).
- **Step**: The result of a mission (a `PtcRunner.Step` struct containing `return`, `fail`, `mem`, and `trace`).
- **Firewall**: The `_` prefix convention that hides data from LLM prompts while keeping it available for Lisp programs.
- **Data Inventory**: The type information section in the prompt that tells the LLM what data is available in `ctx/`.

---

## Further Reading

- [Specification](specification.md) - Full SubAgent API reference
- [Step Struct](step.md) - Shared result struct specification
- [Lisp API Updates](lisp-api-updates.md) - Changes to existing Lisp API
- [Malli Schema](malli-schema.md) - Schema validation system based on Malli
- [Spike Summary](spike-summary.md) - Validation results and architectural decisions
- [PtcRunner Guide](../guide.md) - Core PTC-Lisp documentation
