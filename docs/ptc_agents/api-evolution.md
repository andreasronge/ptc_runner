# SubAgent API Evolution: The Functional Agent Model (Refined)

This document outlines the refined evolution of the `PtcRunner.SubAgent` API. It incorporates feedback to harmonize the new "Functional Agent" concepts with the existing multi-turn agentic loop and the core `Lisp.run` runtime.

## The Universal "Step" Model

The biggest design shift is the unification of LLM-driven agents and Developer-driven Lisp programs into a single **Step** model. Whether a mission is solved by an LLM loop or a static script, it returns a standardized result structure.

### 1. The Universal `Step` Result
Both `SubAgent.delegate` and `PtcRunner.Lisp.run` now return a consistent result structure (a `Step` struct).

**Success Result (`{:ok, step}`):**
- `step.return`: The data map returned (matches signature/contract).
- `step.signature`: The schema that was fulfilled (string).
- `step.mem`: The final state of private working memory.
- `step.usage`: Resource consumption (tokens, time, heap).
- `step.trace`: Execution audit (turns or program steps).

**Failure Result (`{:error, step}`):**
- `step.fail`: The error data (reason, message). Includes `(call "fail" ...)` and runtime crashes.
- `step.signature`: The contract context.
- `step.trace`: Audit trail leading to the failure.

---

## Aligning `PtcRunner.Lisp.run`

To achieve consistency, `Lisp.run` now supports the same **Boundary Tools** (`return` and `fail`) and returns the shared `Step` structure.

### Example: Scripted Step
```elixir
source = """
(if-let [u (call "get-user" {:id ctx/user_id})]
  (call "return" {:status :ok :user u})
  (call "fail" {:reason :not_found}))
"""

{:ok, step} = PtcRunner.Lisp.run(source, 
  context: %{user_id: 123}, 
  signature: "() -> {status :keyword, user :map}"
)

# Access result just like an agent:
step.return.user #=> %{name: "Alice", ...}
```

---

## Detailed Chaining Data Flow

### 1. Linear Chaining & Type Propagation
Chaining becomes predictable because every "Step" carries its own "Mirror" (the signature).

```elixir
# Agentic Step (The LLM)
{:ok, step1} = SubAgent.delegate("Find emails", 
  signature: "() -> {count :int, _ids [:int]}", ...)

# Scripted Step (The Developer)
# 'context_signature' accepts the previous agent's signature. 
# The system automatically extracts the return part (e.g., "{count :int, _ids [:int]}") 
# to describe the 'context' map in the next turn's Data Inventory.
{:ok, step2} = Lisp.run(my_lisp_logic, 
  context: step1.return, 
  context_signature: step1.signature
)
```

### 2. The Context Firewall (`_` marker)
The `_` marker defines the firewall boundary. 
- In the **Parent's Text Context**: The value is hidden.
- In the **Lisp Context (`ctx/`)**: The value is fully available for tool calls.

---

## Unified Namespace & State

We are standardizing the Lisp namespaces for clarity:
- **`ctx/`**: Immutable mission inputs (context) and special loop variables:
    - `ctx/fail`: Details of the last turn's error.
- **`mem/`**: Persistent working memory for the agent.

---

## The Agentic Loop & Orchestration

The "Functional Agent" model supports two levels of agentic behavior: the **Intra-Agent Loop** (ReAct) and **Inter-Agent Orchestration**.

### 1. Intra-Agent Loop (Iterative Troubleshooting)
Within a single `delegate` call, the LLM can generate multiple programs. It uses the `mem/` namespace to maintain state across turns.

```clojure
;; Turn 1: Broad search
(let [items (call "search" {:query "billing"})]
  (if (empty? items)
    (call "return" {:status :not_found})
    (do 
      (mem/put :raw_items items)
      "I found some items, let me check the details...")))

;; (Turn 2 generates a new program)
(let [urgent (filter :urgent mem/raw_items)]
  (call "return" {
    :summary (str "Found " (count urgent) " urgent emails")
    :count (count urgent)
    :_ids (mapv :id urgent)
  }))
```

---

## Tool Integration & Planning

### Tool Catalog for Planning
Agents can be provided with a `tool_catalog` (non-callable tools). The `signature` of these tools is used to help the LLM create execution plans without actually executing them.

### Unified Tool Configuration
 
A tool is defined by a `prompt` and a `signature`. The distinction between a "Judgment Tool" (single-turn) and an "Agent Tool" (multi-turn) is implicit: if `tools:` is provided in the configuration, it executes as a full SubAgent loop.
 
- **Prompt**: A templated string mission (e.g., `"Analyze: {{text}}"`).
- **Signature**: The functional contract. Inputs match prompt placeholders.
- **Nested Types**: Signatures support maps and lists (e.g., `(user {id :int})`).

---

## Simplified API Summary

- **Signatures**: Provided as a single string: `"(param :type) -> {field :type}"`.
- **The `_` Marker**: Hides sensitive or heavy data from the LLM prompt while keeping it in the Lisp context.
- **The `return` & `fail` Tools**: The explicit boundaries for success and failure inside the agent.
- **`step.return` & `step.fail`**: The Elixir result keys that mirror the Lisp tool calls.
- **Namespace Consistency**: `ctx/` for inputs, `mem/` for internal state.
- **`context_signature`**: Propagates type metadata between chained agents.

---

## Production & Safety

| Option | Default | Description |
| :--- | :--- | :--- |
| `max_turns` | 5 | (Agent only) Max iterations before a mission failure. |
| `timeout` | 5000 | Max milliseconds for a single program execution. |
| `prompt_limit` | %{list: 5, string: 1000} | Truncation limits for the LLM's conversation history view. |
