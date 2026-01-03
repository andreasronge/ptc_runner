# SubAgent Evaluation Tests

Implementation plan for multi-turn and SubAgent tests in the demo folder.

## Goals

1. Validate SubAgent API features with real LLMs
2. Expose edge cases and failure modes
3. Provide "wow factor" demos for users
4. Create regression tests for prompt/API changes

## Test Categories

### 1. Error Recovery (Self-Correction)

**What we're testing:** Agent receives error feedback via `ctx/fail` and generates a corrected program.

**Implementation Clue: "Two-Turn Trap"**

```elixir
%{
  name: "error-recovery-empty-result",
  level: 3,
  multi_turn: true,
  queries: [
    # Turn 1: Valid query that returns empty result
    "Calculate the average price of products with status 'discontinued'",
    # Turn 2: Agent should notice empty result and handle it
    # (This query is optional - agent might self-correct in turn 1 retry)
  ],
  expect: :number,
  constraint: {:gte, 0},
  # NEW: Verify the agent actually recovered, not just got lucky
  assertions: [
    {:turn_count, :gte, 2},           # Must have taken multiple turns
    {:program_changed, true}           # Turn 2 program differs from Turn 1
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Apology Loop | Same AST in Turn N and Turn N+1 | Detect duplicate programs, inject "generate NEW code" prompt |
| Hallucinated Fix | Uses non-existent function | Error message must list available functions |
| Over-Explaining | >200 tokens before code | Prompt: "Respond ONLY with code" |

**Test Runner Changes:**

```elixir
defmodule PtcDemo.TestRunner.Assertions do
  def check({:turn_count, op, n}, result) do
    actual = length(result.programs)
    compare(op, actual, n)
  end

  def check({:program_changed, true}, result) do
    programs = result.programs
    length(Enum.uniq_by(programs, &normalize_ast/1)) > 1
  end
end
```

**Error Message Design:**

```
# BAD - Too technical, causes hallucination
"CompileError: undefined function avg-by/2"

# GOOD - Actionable, lists alternatives
"Unknown function 'avg-by'. Available aggregation functions: count, sum, average, min, max"
```

---

### 2. Multi-Turn Memory Persistence

**What we're testing:** Agent stores intermediate results and retrieves them correctly across turns.

**Implementation Clue: Explicit Memory Schema**

```elixir
%{
  name: "memory-accumulation-revenue",
  level: 3,
  multi_turn: true,
  queries: [
    "Store the total revenue from orders with status 'completed' as 'completed-revenue' in memory",
    "Store the total revenue from orders with status 'pending' as 'pending-revenue' in memory",
    "Calculate what percentage of total revenue (completed + pending) is from pending orders. Use memory/completed-revenue and memory/pending-revenue."
  ],
  expect: :number,
  constraint: {:between, 0, 100},
  assertions: [
    {:memory_keys_used, ["completed-revenue", "pending-revenue"]}
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Naming Drift | `memory/get` key doesn't match `memory/put` key | Provide `(memory/keys)` introspection; include stored keys in turn prompt |
| Type Drift | Stored `{:count 42}`, retrieved as `42` | Include value schema in memory: `{:key "x", :value 42, :type :integer}` |
| Lost in the Middle | Turn 5 forgets Turn 1 schema | Summarize memory state at start of each turn prompt |

**Memory Introspection Helper:**

```elixir
# Add to system prompt for multi-turn tests:
"""
Current memory state:
#{format_memory_state(memory)}

Available keys: #{inspect(Map.keys(memory))}
"""
```

**Test for Naming Drift:**

```elixir
%{
  name: "memory-naming-consistency",
  level: 3,
  queries: [
    "Count employees in Engineering and store as 'eng-count'",
    "Count employees in Sales and store as 'sales-count'",
    # Intentionally use slightly different naming to see if LLM drifts
    "What is the ratio of engineering to sales employees? Use the stored counts."
  ],
  assertions: [
    {:no_memory_miss, true}  # memory/get never returned nil
  ]
}
```

---

### 3. Context Firewall (`_` prefix)

**What we're testing:** Agent can operate on firewalled data without seeing its contents.

**Implementation Clue: Metadata Alongside Hidden Data**

```elixir
# Test setup - what goes into ctx/
context = %{
  # Visible to LLM in prompt
  customer_count: 150,
  email_domains: ["gmail.com", "company.com", "yahoo.com"],

  # Hidden from LLM prompt, but accessible in programs
  _customer_emails: ["alice@gmail.com", "bob@company.com", ...]
}
```

```elixir
%{
  name: "firewall-count-hidden",
  level: 3,
  setup: {:firewall_context, :customer_emails},
  query: "Count how many customer emails are from gmail.com domains",
  expect: :integer,
  constraint: {:gt, 0},
  assertions: [
    {:accessed_firewalled, ["_customer_emails"]},  # Did use the hidden data
    {:no_leak, ["_customer_emails"]}               # Didn't return raw values
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Helpful Narcissist | LLM says "I can't see the emails" | Prompt: "The runtime can access fields you cannot see. Use `ctx/_fieldname`." |
| Data Leak | Program returns `(first ctx/_emails)` | Filter firewalled values from `:return` before next turn |
| Probe Attempts | LLM tries `(println ctx/_emails)` | Sandbox blocks side-effect functions on firewalled data |

**Firewall Leak Detection:**

```elixir
defmodule PtcDemo.TestRunner.FirewallCheck do
  def check_no_leak(result, firewalled_keys) do
    return_value = result.return

    # Deep check: no firewalled values appear in return
    firewalled_keys
    |> Enum.all?(fn key ->
      original_value = get_in(result.context, [key])
      not contains_value?(return_value, original_value)
    end)
  end
end
```

**Prompt Addition for Firewall Tests:**

```
Some context fields are prefixed with '_' (e.g., ctx/_emails).
You cannot see their contents, but your programs CAN access them.
The PTC runtime will evaluate expressions like (count ctx/_emails) correctly.
Never try to return or display firewalled data directly.
```

---

### 4. Nested Agents (SubAgent.as_tool)

**What we're testing:** Orchestrator agent correctly delegates to sub-agents via tool calls.

**Implementation Clue: Inject Sub-Agent as Tool**

```elixir
# Phase 1: Define the specialist agent
classifier = SubAgent.new(
  prompt: "Rate the priority of an expense category from 1-10 based on business criticality",
  signature: "category:string -> priority:integer"
)

# Phase 2: Create orchestrator test
%{
  name: "nested-agent-delegation",
  level: 4,
  setup: fn tools ->
    Map.put(tools, "rate_priority", SubAgent.as_tool(classifier, name: "rate_priority"))
  end,
  query: "For each unique expense category, get its priority rating, then return categories with priority >= 7",
  expect: :list,
  assertions: [
    {:tool_called, "rate_priority", :gte, 1},  # Must have used the sub-agent
    {:no_inline_classification, true}           # Didn't try to classify itself
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Tool Hesitation | Orchestrator classifies inline | Prompt: "You MUST use the rate_priority tool. Do NOT classify items yourself." |
| Context Bloat | 50 sub-agent calls explode context | Limit items processed; use batch tool variant |
| Tool Blindness | Sub-agent tool not called when it's #7 in list | Put delegated tools first in tools list; test with different orderings |

**Tool Usage Detection:**

```elixir
defmodule PtcDemo.TestRunner.ToolTracker do
  def track_tool_calls(execution_trace) do
    execution_trace
    |> Enum.filter(&match?({:tool_call, _, _}, &1))
    |> Enum.group_by(fn {:tool_call, name, _} -> name end)
    |> Enum.map(fn {name, calls} -> {name, length(calls)} end)
    |> Map.new()
  end
end
```

**Batching Strategy for Context Bloat:**

```elixir
# Instead of: classify each of 50 items individually
# Use: batch classifier that takes list

batch_classifier = SubAgent.new(
  prompt: "Rate priority 1-10 for each category in the list",
  signature: "categories:list[string] -> ratings:list[{category:string, priority:integer}]"
)
```

---

### 5. Compiled Agents (SubAgent.compile)

**What we're testing:** LLM generates a reusable function that works deterministically without further LLM calls.

**Implementation Clue: Two-Phase Test**

```elixir
%{
  name: "compiled-tax-calculator",
  level: 4,
  mode: :compile,

  # Phase 1: Compilation prompt
  compile_prompt: """
  Write a function that calculates sales tax for a US state.
  Input: {amount: number, state: string}
  Output: {tax: number, total: number}

  Tax rates: CA=7.25%, TX=6.25%, NY=8%, FL=6%
  For unknown states, use 5%.
  """,

  # Phase 2: Deterministic execution (no LLM)
  test_cases: [
    {%{amount: 100, state: "CA"}, %{tax: 7.25, total: 107.25}},
    {%{amount: 100, state: "TX"}, %{tax: 6.25, total: 106.25}},
    {%{amount: 100, state: "XX"}, %{tax: 5.0, total: 105.0}},  # Unknown state
    {%{amount: 0, state: "CA"}, %{tax: 0, total: 0}},          # Edge case
  ],

  assertions: [
    {:no_llm_calls_in_phase_2, true},
    {:all_test_cases_pass, true}
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Hardcoding | Returns `(* amount 0.08)` ignoring state | Include 3+ diverse examples in prompt; verify with unknown state test case |
| Incomplete Function | Missing `(fn [input] ...)` wrapper | Prompt: "Your response must be a function: `(fn [{:keys [amount state]}] ...)`" |
| Lookup Table Miss | Hardcodes known states, fails on unknown | Always include "unknown/default" test case |

**Compilation Validation:**

```elixir
defmodule PtcDemo.TestRunner.CompileValidator do
  def validate_compiled_function(ast) do
    case ast do
      {:fn, _, _} -> :ok
      {:defn, _, _} -> :ok
      _ -> {:error, "Expected function definition, got: #{inspect(ast)}"}
    end
  end

  def run_test_cases(compiled_fn, test_cases) do
    Enum.map(test_cases, fn {input, expected} ->
      actual = PtcRunner.eval(compiled_fn, %{input: input})
      %{input: input, expected: expected, actual: actual, pass: actual == expected}
    end)
  end
end
```

**Anti-Hardcoding Prompt:**

```
Write a GENERIC function that works for ANY state, not just the examples.
Your function must:
1. Accept a map with :amount and :state keys
2. Look up the tax rate from a rates map
3. Handle unknown states with a default rate
4. Return both tax amount and total

DO NOT hardcode specific calculations like (* amount 0.0725).
```

---

### 6. Turn Budget & Early Termination

**What we're testing:** Agent uses `(return ...)` to terminate early; doesn't waste turns.

**Implementation Clue: Verify Turn Efficiency**

```elixir
%{
  name: "early-termination",
  level: 3,
  max_turns: 5,
  query: "What is the total count of all products?",  # Simple query, should take 1 turn
  expect: :integer,
  constraint: {:gt, 0},
  assertions: [
    {:turn_count, :lte, 2},           # Should not use all 5 turns
    {:used_return, true}               # Must have called (return ...)
  ]
}

%{
  name: "no-unnecessary-verification",
  level: 3,
  max_turns: 5,
  query: "Sum the prices of all products in the 'Electronics' category",
  expect: :number,
  assertions: [
    {:turn_count, :lte, 2},
    {:no_duplicate_computation, true}  # Didn't re-run same calculation
  ]
}
```

**Edge Cases to Handle:**

| Edge Case | Detection | Mitigation |
|-----------|-----------|------------|
| Turn Inflation | Uses all 5 turns for 1-turn task | Assert `turn_count <= expected`; flag for prompt tuning |
| Verification Loop | "Let me verify..." -> same calc | Detect duplicate ASTs across turns |
| Premature Return | Returns before task complete | Validate return value against constraints |

---

### 7. Signature Validation

**What we're testing:** Agent receives type errors and fixes return value to match signature.

**Implementation Clue: Type Mismatch Recovery**

```elixir
%{
  name: "signature-type-fix",
  level: 3,
  signature: "-> count:integer",  # Expects integer
  query: "Count the products",
  # Agent might initially return {:count 42} instead of just 42
  assertions: [
    {:final_return_matches_signature, true},
    {:received_type_error, :maybe}  # Might have gotten error and fixed it
  ]
}

%{
  name: "signature-structure-fix",
  level: 3,
  signature: "-> {total:number, average:number}",
  query: "Get the total and average price of all products",
  assertions: [
    {:return_has_keys, [:total, :average]},
    {:values_are_numbers, [:total, :average]}
  ]
}
```

---

## Test Runner Infrastructure

### New Modules Needed

```
demo/lib/ptc_demo/test_runner/
├── assertions.ex        # Check turn_count, tool_called, etc.
├── firewall_check.ex    # Detect data leaks
├── tool_tracker.ex      # Track sub-agent/tool usage
├── compile_validator.ex # Two-phase compile tests
└── memory_tracker.ex    # Track memory/put and memory/get
```

### Result Structure Extension

```elixir
defmodule PtcDemo.TestRunner.Result do
  defstruct [
    :name,
    :pass,
    :return_value,
    :programs,           # List of all programs tried
    :turn_count,
    :tool_calls,         # %{"tool_name" => count}
    :memory_operations,  # [{:put, key, value}, {:get, key, result}]
    :firewalled_access,  # ["_field1", "_field2"]
    :errors_received,    # List of error messages agent saw
    :assertions_results  # %{assertion_name => :pass | {:fail, reason}}
  ]
end
```

### Test Modes

```elixir
# Fast mode: cheaper models, basic tests only
mix ptc_demo.eval --mode fast

# Full mode: reasoning models, all test categories
mix ptc_demo.eval --mode full

# Category mode: run specific test category
mix ptc_demo.eval --category error_recovery
mix ptc_demo.eval --category nested_agents
```

---

## Implementation Sequence

### Phase 1: Error Recovery (Week 1)
1. Add `assertions` field to test case struct
2. Implement `Assertions.check/2` for basic assertions
3. Create 3-5 error recovery test cases
4. Add duplicate program detection
5. Tune error messages for actionability

### Phase 2: Memory Persistence (Week 1-2)
1. Implement `MemoryTracker` module
2. Add memory state to turn prompts
3. Create 3-5 memory accumulation tests
4. Add naming drift detection

### Phase 3: Context Firewall (Week 2)
1. Implement `FirewallCheck` module
2. Add firewall leak detection to sandbox
3. Create 3-5 firewall test cases
4. Add prompt instructions for firewalled access

### Phase 4: Nested Agents (Week 3)
1. Implement `ToolTracker` module
2. Add setup function support for injecting tools
3. Create 2-3 nested agent tests
4. Add context bloat monitoring

### Phase 5: Compiled Agents (Week 3-4)
1. Implement `CompileValidator` module
2. Add two-phase test execution
3. Create 2-3 compile tests
4. Add anti-hardcoding detection

### Phase 6: Polish (Week 4)
1. Add turn budget tests
2. Add signature validation tests
3. Create `--mode` and `--category` CLI options
4. Write user-facing documentation

---

## Success Metrics

| Category | Target Pass Rate | Notes |
|----------|------------------|-------|
| Error Recovery (Easy) | 95%+ | Empty result handling |
| Error Recovery (Hard) | 80%+ | Function name traps - strong models pass on 1st try |
| Memory Persistence | 90%+ | Naming drift is fixable |
| Context Firewall | 95%+ | Security-critical |
| Nested Agents | 70%+ | Complex orchestration |
| Compiled Agents | 85%+ | Hardcoding is common |
| Turn Budget | 90%+ | Efficiency metric |

## Implemented Tests (as of 2026-01)

### Error Recovery Tests (7 total)

**Easy (Empty Result Handling):**
1. Average price of 'archived' products → 0
2. Average bonus in 'legal' department → 0
3. Count 'bitcoin' orders → 0

**Hard (Function Name Traps):**
4. "length of products list" → should use `count`
5. "sum of all prices" → should use `sum-by`
6. "average of totals" → should use `avg-by`
7. "first product in 'luxury' category" → nil chain handling

**Observation:** Strong models (Gemini, Haiku, DeepSeek) pass all traps on first attempt because the system prompt documents available functions. These tests are valuable for:
- Regression detection if prompt quality degrades
- Catching weaker models that don't follow system prompts
- Documenting terminology that could confuse LLMs

---

## Model-Specific Notes

| Model | Expected Behavior | Mitigations |
|-------|-------------------|-------------|
| Claude Sonnet 3.5 | Strong on error recovery, occasional tool hesitation | Explicit delegation prompts |
| Claude Opus 4 | Best overall, may over-think simple tasks | Lower max_turns for simple tests |
| GPT-4o | Good tool use, verbose explanations | "Code only" prompt suffix |
| GPT-4o-mini | Apology loops, hardcoding in compile | Skip compile tests or use for baseline |

---

## Open Questions

1. **Firewall security**: Should firewalled data ever be allowed in `:return`? Current plan: hard block.

2. **Nested agent depth**: Should we test 3-level nesting (agent -> agent -> agent)? Probably overkill for v1.

3. **Parallel execution**: Test `Task.async_stream` patterns? Adds complexity, defer to Phase 2.

4. **Cost tracking**: Should tests fail if they exceed token budget? Useful for regression detection.



----


What is the length of the products list? Return the total number of items.








(count ctx/products)







Andreas
Calculate the sum of all product prices. Just add up every price value.








(sum-by :price ctx/products)







Andreas
Compute the average of all order totals. What is the mean value?







(avg-by :total ctx/orders)







Andreas
What is the average price of products with status 'archived'? If there are no such products, return 0.








(if-let [filtered (filter (where :status = "archived") ctx/products)]
  (avg-by :price filtered)
  0)







Andreas
Get the name of the first product in the 'luxury' category. If no such product exists, return the string 'none'.








(if-let [luxury-products (filter (where :category = "luxury") ctx/products)]
  (get (first luxury-products) :name)
  "none")







Andreas
What is the total discount across all products?







(sum-by :discount ctx/products)