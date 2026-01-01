# SubAgent Design Decisions

This document records architectural decisions for the SubAgent API.

Each decision follows a lightweight ADR format:
- **Context:** What prompted the decision
- **Decision:** What we chose
- **Rationale:** Why we chose it

---

## DD-1: Optional Field Syntax (`?` suffix)

**Context:** Need to distinguish optional fields from list types in signatures.

**Decision:** Use `:type?` for optional fields. `[:type]` is reserved for lists.

**Example:**
```
{:email :string?}   ; optional field
{:tags [:string]}   ; list of strings
```

**Rationale:** The `?` suffix is familiar from Elixir predicates and other languages. Overloading `[]` for both lists and optionals would be ambiguous.

---

## DD-2: Reserved Names Error at Registration

**Context:** `return` and `fail` are system tools. Users might accidentally try to register tools with these names.

**Decision:** Fail early at `run/2` if user registers `return` or `fail` tools. Returns `{:error, :reserved_tool_name}`.

**Rationale:** Early failure is better than mysterious runtime behavior. The error is clear and actionable.

---

## DD-3: Lenient Extra Fields by Default

**Context:** LLMs sometimes return additional fields beyond what's in the signature.

**Decision:** `:enabled` mode allows extra fields in return data. Use `:strict` mode for exact matching.

**Rationale:** Being lenient reduces friction during development. Strict mode is available for testing and production hardening.

---

## DD-4: Soft Failures Don't Consume Retry Budget

**Context:** Need to distinguish between infrastructure errors (network, rate limits) and logic errors (bad syntax, validation failures).

**Decision:**
- Logic errors (bad syntax, validation) use **turn budget** - LLM gets feedback
- Infrastructure errors (timeouts, rate limits) use **retry budget** - automatic retry

**Rationale:** Logic errors are recoverable by the LLM in the next turn. Infrastructure errors are transient and should be retried silently.

---

## DD-5: Auto-Chaining with Step Detection

**Context:** Chaining agents requires passing data between them. Manual extraction is verbose.

**Decision:** Passing a `Step` to `:context` auto-extracts `return` and `signature`. If the step failed, immediately return `{:error, step}` with `fail.reason: :chained_failure`.

**Example:**
```elixir
# Auto-extraction
{:ok, step2} = SubAgent.run(agent2, context: step1)

# Failed step short-circuits
{:error, failed} = SubAgent.run(failing_agent, llm: llm)
{:error, chained} = SubAgent.run(next, llm: llm, context: failed)
chained.fail.reason  #=> :chained_failure
```

**Rationale:** Reduces boilerplate. Short-circuiting on failure prevents cascading errors and makes error handling explicit.

---

## DD-6: Agents as Data

**Context:** Need to compose, reuse, and delay execution of agents.

**Decision:** SubAgents are defined as structs via `new/1`, separating definition from execution.

**Rationale:** Enables:
- Delayed execution
- Reusable agent definitions
- Composition patterns (chaining, parallel)
- Serialization and inspection

---

## DD-7: LLM Inheritance

**Context:** Nested agents need LLM access. Requiring explicit LLM everywhere is verbose.

**Decision:** Child SubAgents can inherit the parent's LLM. Resolution order:
1. Agent struct `llm` field (override)
2. `as_tool(..., llm: x)` bound LLM
3. Parent's LLM (inherited)
4. `run(..., llm: x)` (required at top level)

**Rationale:** Reduces boilerplate while allowing explicit control. Registry inheritance means you pass `llm_registry` once at the top level.

---

## DD-8: Compile Only Works with Pure Tools

**Context:** `SubAgent.compile/2` generates deterministic PTC-Lisp functions that don't require an LLM at execution time.

**Decision:** Compilation succeeds only when all tools are pure Elixir functions. Agents with `LLMTool` or `SubAgentTool` cannot be compiled.

**Rationale:** Compiled agents must be deterministic. LLM-powered tools are inherently non-deterministic.

---

## DD-9: System Tools Are Real Tools

**Context:** Need consistent invocation for `return`, `fail`, and user tools.

**Decision:** `return` and `fail` are implemented as real tools injected into the tool registry, not special keywords.

**Rationale:**
- Consistent `(call ...)` syntax for everything
- LLM sees them in the tool schema alongside user tools
- Unified handling in the interpreter

---

## DD-10: CompiledAgent.execute Always Uses Maps

**Context:** `CompiledAgent.execute` needs a consistent API regardless of parameter count.

**Decision:** The `execute` function always takes a map of named arguments.

**Example:**
```elixir
# Single parameter: (item :map) -> {score :float}
compiled.execute(%{item: item_data})

# Multiple: (item :map, threshold :float) -> {score :float}
compiled.execute(%{item: item_data, threshold: 0.5})

# No parameters: () -> {result :map}
compiled.execute(%{})
```

**Rationale:**
- Consistent API across all compiled agents
- Adding parameters doesn't break existing callers
- Clear, self-documenting invocations

---

## DD-11: Tracing Always On by Default

**Context:** Debugging agent behavior requires execution history.

**Decision:** Traces are captured by default (`trace: true`). Production optimization via `trace: :on_error` or `trace: false` is opt-in.

**Rationale:**
- Debugging agents is inherently difficult without execution history
- Memory overhead is acceptable for typical runs (< 100 turns)
- Failed runs are nearly impossible to debug without trace data
- `debug: true` enables additional expensive captures (AST, context snapshots)

---

## DD-12: Telemetry for Observability, Not Control Flow

**Context:** Need observability without affecting execution.

**Decision:** Telemetry events are fire-and-forget notifications, not callbacks that modify execution.

**Rationale:**
- Observability handlers cannot break agent execution
- No hidden control flow through telemetry
- Production monitoring doesn't affect behavior
- Clear separation between execution and observation

---

## DD-13: System Prompt Customization via Structured Options

**Context:** Users need to customize system prompts for personas, DSL variants, or additional instructions.

**Decision:** Layered customization approach:
1. **Map options** (`:prefix`, `:suffix`, `:language_spec`, `:output_format`) - safe, targeted
2. **Function transformer** - advanced modifications with full prompt access
3. **String override** - escape hatch for complete control

**Prompt assembly order (with map):**
1. prefix
2. Core PTC-Lisp instructions
3. language_spec (custom or default)
4. Error recovery section
5. Data inventory
6. Tool schemas
7. output_format (custom or default)
8. suffix

**Rationale:**
- Preserves generated sections (tools, inventory) by default
- Allows DSL variants without rewriting everything
- Provides escape hatches for power users
- Fails gracefully when internals change (map users get updates, string users don't)
