# System Prompt Template Specification

> **Status:** Planned
> **Scope:** `PtcRunner.SubAgent.Prompt` module

This document specifies the system prompt structure generated for SubAgent LLM calls.

---

## Overview

The system prompt is the foundation of SubAgent's communication with the LLM. It establishes:
- The agent's role and boundaries
- Available tools and their contracts
- Data available in context
- Output format requirements
- Error recovery guidance

**Design Goals:**
1. **Token-efficient** - Minimize prompt size while preserving clarity
2. **Self-contained** - LLM can work without external references
3. **Consistent** - Same structure across all SubAgent invocations
4. **Instructive** - Clear guidance on PTC-Lisp syntax and patterns

---

## Prompt Structure

The system prompt consists of 7 sections:

```
┌─────────────────────────────────────────────────────────────────┐
│                    SYSTEM PROMPT STRUCTURE                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. ROLE & PURPOSE                                               │
│     └── Defines agent as PTC-Lisp generator                      │
│                                                                  │
│  2. ENVIRONMENT RULES                                            │
│     └── Boundaries for code generation                           │
│                                                                  │
│  3. DATA INVENTORY                                               │
│     └── Typed view of ctx/ variables                            │
│                                                                  │
│  4. TOOL SCHEMAS                                                 │
│     └── Available tools with signatures                          │
│                                                                  │
│  5. PTC-LISP REFERENCE                                          │
│     └── Language syntax and built-in functions                   │
│                                                                  │
│  6. OUTPUT FORMAT                                                │
│     └── Code block requirements                                  │
│                                                                  │
│  7. MISSION PROMPT                                               │
│     └── User's task (from prompt option)                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Section 1: Role & Purpose

```markdown
# Role

You are a PTC-Lisp program generator. Your task is to write programs that accomplish
the user's mission by calling tools and processing data.

You MUST respond with a single PTC-Lisp program in a ```clojure code block.
The program will be executed, and you may see results in subsequent turns.

Your mission ends ONLY when you call the `return` or `fail` tool.
```

**Single-turn variant (max_turns: 1, no tools):**
```markdown
# Role

You are a PTC-Lisp expression evaluator. Evaluate the given expression and return
the result directly. No `return` call is needed - your expression result is the answer.
```

---

## Section 2: Environment Rules

```markdown
# Rules

1. Respond with EXACTLY ONE ```clojure code block
2. Do not include explanatory text outside the code block
3. Use `(call "tool-name" args)` to invoke tools
4. Use `ctx/key` to access context data
5. Use `memory/key` or `(memory/get :key)` for persistent state
6. Call `(return result)` when the mission is complete
7. Call `(fail {:reason :keyword :message "..."})` on unrecoverable errors
```

---

## Section 3: Data Inventory

Generated from `context` and `context_signature`:

```markdown
# Data Inventory

Available in `ctx/`:

| Key | Type | Sample |
|-----|------|--------|
| `ctx/user_id` | `:int` | `123` |
| `ctx/emails` | `[{id :int, subject :string}]` | `[{id: 1, subject: "Hello"}, ...]` (5 items) |
| `ctx/_token` | `:string` | [Hidden] |

Note: Firewalled fields (prefixed with `_`) show `[Hidden]` in the Sample column
but are available in your program at runtime.
```

**Generation Logic:**

```elixir
defmodule PtcRunner.SubAgent.Prompt do
  def generate_data_inventory(context, context_signature) do
    # Parse signature to get type info
    # Generate markdown table with:
    # - Key names from context
    # - Types from signature
    # - [Firewalled] marker for _ prefixed fields
  end
end
```

---

## Section 4: Tool Schemas

Generated from `tools` and `tool_catalog`. Each tool's signature and description are displayed to help the LLM understand available capabilities.

**Description sources (in priority order):**
1. Explicit `description:` in keyword list format
2. Auto-extracted `@doc` from function reference
3. For LLMTool: the `:description` field
4. For SubAgent-as-tool: derived from the agent's prompt

```markdown
# Available Tools

## Tools you can call

### search
```
search(query :string, limit :int?) -> [{id :int, title :string}]
```
Search for items matching query. Limit defaults to 10.

### get_user
```
get_user(id :int) -> {name :string, email :string?}
```
Fetch user by ID. Returns user object or nil if not found.

### return
```
return(data :any) -> :exit-success
```
Complete the mission successfully. Data must match your mission's signature.

### fail
```
fail(error {:reason :keyword, :message :string, :op :string?, :details :map?}) -> :exit-error
```
Terminate with an error. Use when the mission cannot be completed.

## Tools for planning (do not call)

These tools are shown for context but cannot be called directly:

### email_agent
```
email_agent(prompt :string) -> {summary :string, _ids [:int]}
```
Specialized agent for email processing.
```

---

## Section 5: PTC-Lisp Reference

```markdown
# PTC-Lisp Quick Reference

## Syntax
- Clojure-inspired syntax
- Keywords: `:keyword`
- Maps: `{:key value :key2 value2}`
- Vectors: `[1 2 3]`
- Function calls: `(function arg1 arg2)`

## Core Functions
- `call` - Invoke tools: `(call "tool-name" {:arg value})`
- `let` - Local bindings: `(let [x 1 y 2] (+ x y))`
- `if` - Conditional: `(if condition then-expr else-expr)`
- `do` - Sequential: `(do expr1 expr2 expr3)`
- `fn` - Anonymous function: `(fn [x] (* x 2))`

## Context Access
- `ctx/key` - Read from context
- `memory/key` - Read from persistent memory
- `(memory/put :key value)` - Store in memory

## Collections
- `map`, `mapv` - Transform: `(mapv :id items)`
- `filter` - Filter: `(filter #(> (:score %) 0.5) items)`
- `reduce` - Fold: `(reduce + 0 numbers)`
- `first`, `last`, `nth` - Access elements
- `count`, `empty?` - Collection info

## Common Patterns
```clojure
;; Fetch and process
(let [users (call "get_users" {:limit 10})]
  (mapv :name users))

;; Conditional logic
(if (empty? results)
  (fail {:reason :not_found :message "No results"})
  (return {:count (count results)}))

;; Multi-step with memory
(do
  (memory/put :step1 (call "search" {:q "test"}))
  (call "process" {:data memory/step1}))
```
```

---

## Section 6: Output Format

```markdown
# Output Format

Respond with a single ```clojure code block containing your program:

```clojure
(let [data (call "fetch" {:id ctx/user_id})]
  (return {:result data}))
```

Do NOT include:
- Explanatory text before or after the code
- Multiple code blocks
- Code outside of the ```clojure block
```

---

## Section 7: Mission Prompt

The user's actual task, with template placeholders expanded:

```markdown
# Mission

Find all urgent emails for {{user.name}} and draft acknowledgment replies.

Return format: {count :int, draft_ids [:int]}
```

---

## Complete Template

```elixir
defmodule PtcRunner.SubAgent.Prompt do
  @template """
  # Role

  You are a PTC-Lisp program generator. Your task is to write programs that accomplish
  the user's mission by calling tools and processing data.

  You MUST respond with a single PTC-Lisp program in a ```clojure code block.
  <%= if @mode == :agent do %>
  Your mission ends ONLY when you call the `return` or `fail` tool.
  <% else %>
  Return your expression result directly - no `return` call needed.
  <% end %>

  # Rules

  1. Respond with EXACTLY ONE ```clojure code block
  2. Do not include explanatory text outside the code block
  3. Use `(call "tool-name" args)` to invoke tools
  4. Use `ctx/key` to access context data
  5. Use `memory/key` for persistent state
  <%= if @mode == :agent do %>
  6. Call `(return result)` when the mission is complete
  7. Call `(fail {:reason :keyword :message "..."})` on unrecoverable errors
  <% end %>

  # Data Inventory

  <%= @data_inventory %>

  # Available Tools

  <%= @tool_schemas %>

  # PTC-Lisp Quick Reference

  <%= @language_reference %>

  # Output Format

  <%= @output_format %>

  # Mission

  <%= @mission %>
  """

  @spec generate(keyword()) :: String.t()
  def generate(opts) do
    mode = opts[:mode] || :agent
    context = opts[:context] || %{}
    context_signature = opts[:context_signature]
    tools = opts[:tools] || %{}
    tool_catalog = opts[:tool_catalog] || %{}
    prompt = opts[:prompt] || ""

    EEx.eval_string(@template,
      mode: mode,
      data_inventory: generate_data_inventory(context, context_signature),
      tool_schemas: generate_tool_schemas(tools, tool_catalog),
      language_reference: @language_reference,
      output_format: @output_format,
      mission: expand_template(prompt, context)
    )
  end
end
```

---

## Token Budget Considerations

| Section | Approximate Tokens | Notes |
|---------|-------------------|-------|
| Role & Purpose | ~50 | Fixed |
| Environment Rules | ~80 | Fixed |
| Data Inventory | Variable | ~10 per field |
| Tool Schemas | Variable | ~30 per tool |
| PTC-Lisp Reference | ~400 | Can be trimmed |
| Output Format | ~50 | Fixed |
| Mission Prompt | Variable | User-defined |

**Optimization Options:**

1. **Minimal mode** - Skip language reference for experienced models
2. **Tool trimming** - Show only relevant tools based on mission analysis
3. **Data sampling** - Show first 3 items of large lists with count note

```elixir
prompt_limit: %{
  list_sample: 3,      # Show first N items of lists
  string_truncate: 500, # Truncate strings at N chars
  omit_reference: true  # Skip PTC-Lisp reference section
}
```

---

## Error Recovery Prompts

When a previous turn fails, append error context:

```markdown
# Previous Turn Error

Your previous program failed with:
- **Error**: parse_error
- **Message**: Unexpected token at position 45
- **Context**: `ctx/fail` contains the full error details

Please fix the issue and try again.
```

---

## Related Documents

- [specification.md](specification.md) - SubAgent API reference
- [guides/](guides/) - Usage guides and patterns
- [signature-syntax.md](signature-syntax.md) - Signature syntax reference
- [step.md](step.md) - Step struct specification
