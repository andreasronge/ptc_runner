# PTC-JSON Language Specification

**Version:** 1.0.0
**Status:** Stable
**Purpose:** A JSON-based DSL for LLM-generated data transformation programs

---

## 1. Overview

PTC-JSON is a JSON-based domain-specific language designed for Programmatic Tool Calling. Programs are JSON objects that describe data transformation operations.

### Execution Model

A PTC-JSON program is a **pure function** that transforms input data:

- **Input**: Context variables and registered tools
- **Output**: A result value
- **Semantics**: Functional, all operations are pure transformations

### Design Goals

1. **Universal compatibility**: JSON is supported by all programming languages and LLMs
2. **Safe**: No side effects, sandboxed execution with resource limits
3. **Debuggable**: Exact error positions, clear operation names
4. **LLM-friendly**: Structured format that LLMs generate reliably

### Non-Goals

- Turing completeness
- Complex control flow
- State mutation

---

## 2. Program Structure

### 2.1 Basic Format

Every program is a JSON object with a `program` key:

```json
{
  "program": {
    "op": "operation_name",
    ...operation_parameters
  }
}
```

### 2.2 Operations

Operations are the building blocks of programs. Each operation has:

- `op`: The operation type (required)
- Additional parameters specific to the operation

---

## 3. Data Types

PTC-JSON supports standard JSON data types:

| Type | JSON Representation | Example |
|------|---------------------|---------|
| Null | `null` | `null` |
| Boolean | `true`, `false` | `true` |
| Number | Integer or float | `42`, `3.14` |
| String | Double-quoted | `"hello"` |
| Array | Square brackets | `[1, 2, 3]` |
| Object | Curly braces | `{"a": 1}` |

---

## 4. Truthiness

Only `null` and `false` are **falsy**. Everything else is **truthy**:

| Value | Truthy? |
|-------|---------|
| `null` | No |
| `false` | No |
| `true` | Yes |
| `0` | Yes |
| `""` (empty string) | Yes |
| `[]` (empty array) | Yes |
| `{}` (empty object) | Yes |

---

## 5. Operations Reference

### 5.1 Data Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `literal` | Literal value | `{"op": "literal", "value": 42}` |
| `var` | Reference a variable | `{"op": "var", "name": "expenses"}` |
| `load` | Load from context | `{"op": "load", "name": "data"}` |
| `let` | Bind a value to a name | `{"op": "let", "name": "x", "value": ..., "in": ...}` |

#### `literal`

Returns a literal value.

```json
{"op": "literal", "value": 42}
{"op": "literal", "value": "hello"}
{"op": "literal", "value": [1, 2, 3]}
```

#### `var`

References a variable bound by `let`.

```json
{"op": "var", "name": "expenses"}
```

#### `load`

Loads data from the execution context (external data passed to `run/2`).

```json
{"op": "load", "name": "data"}
```

#### `let`

Binds a value to a name for use in the body expression.

```json
{
  "op": "let",
  "name": "total",
  "value": {"op": "sum", "field": "amount"},
  "in": {"op": "var", "name": "total"}
}
```

### 5.2 Collection Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `pipe` | Chain operations | `{"op": "pipe", "steps": [...]}` |
| `filter` | Keep matching items | `{"op": "filter", "where": {...}}` |
| `reject` | Remove matching items | `{"op": "reject", "where": {...}}` |
| `map` | Transform each item | `{"op": "map", "expr": {...}}` |
| `select` | Pick specific fields | `{"op": "select", "fields": ["id", "name"]}` |
| `sort_by` | Sort by field | `{"op": "sort_by", "field": "price", "order": "asc"}` |
| `first` | Get first item | `{"op": "first"}` |
| `last` | Get last item | `{"op": "last"}` |
| `nth` | Get nth item (0-indexed) | `{"op": "nth", "index": 2}` |
| `count` | Count items | `{"op": "count"}` |

#### `pipe`

Chains multiple operations together. Each step receives the output of the previous step.

```json
{
  "op": "pipe",
  "steps": [
    {"op": "load", "name": "expenses"},
    {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
    {"op": "sum", "field": "amount"}
  ]
}
```

#### `filter`

Keeps items where the condition is truthy.

```json
{
  "op": "filter",
  "where": {"op": "eq", "field": "status", "value": "active"}
}
```

#### `reject`

Removes items where the condition is truthy (inverse of `filter`).

```json
{
  "op": "reject",
  "where": {"op": "eq", "field": "deleted", "value": true}
}
```

#### `map`

Transforms each item using the expression.

```json
{
  "op": "map",
  "expr": {"op": "get", "path": ["name"]}
}
```

#### `select`

Picks specific fields from each item.

```json
{
  "op": "select",
  "fields": ["id", "name", "email"]
}
```

#### `sort_by`

Sorts items by a field.

```json
{"op": "sort_by", "field": "price", "order": "asc"}
{"op": "sort_by", "field": "created_at", "order": "desc"}
```

### 5.3 Aggregation Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `sum` | Sum a field | `{"op": "sum", "field": "amount"}` |
| `avg` | Average a field | `{"op": "avg", "field": "amount"}` |
| `min` | Minimum value | `{"op": "min", "field": "amount"}` |
| `max` | Maximum value | `{"op": "max", "field": "amount"}` |
| `min_by` | Row with min value | `{"op": "min_by", "field": "price"}` |
| `max_by` | Row with max value | `{"op": "max_by", "field": "years"}` |

#### Empty Collection Behavior

| Operation | Empty List Result |
|-----------|------------------|
| `sum` | `0` |
| `count` | `0` |
| `avg` | `null` |
| `min` | `null` |
| `max` | `null` |
| `min_by` | `null` |
| `max_by` | `null` |
| `sort_by` | `[]` |

### 5.4 Access Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `get` | Get single field | `{"op": "get", "field": "name"}` |
| `get` | Get nested field | `{"op": "get", "path": ["user", "profile", "email"]}` |
| `get` | Get with default | `{"op": "get", "field": "x", "default": 0}` |

#### `get`

Accesses a field or nested path.

```json
{"op": "get", "field": "name"}
{"op": "get", "path": ["user", "profile", "email"]}
{"op": "get", "field": "missing", "default": "unknown"}
```

**Path semantics:**
- Path elements are always **string keys** for maps
- For arrays, use `nth` operation (not `get` with numeric path)
- `{"op": "get", "path": ["0"]}` looks for key `"0"`, not index 0
- Empty path `[]` returns the current value

### 5.5 Introspection Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `keys` | Get sorted keys of a map | `{"op": "keys"}` |
| `typeof` | Get type of current value | `{"op": "typeof"}` |

#### `typeof` Return Values

| Input Type | Return Value |
|------------|--------------|
| Map | `"object"` |
| Array | `"list"` |
| String | `"string"` |
| Number | `"number"` |
| Boolean | `"boolean"` |
| Null | `"null"` |

### 5.6 Comparison Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `eq` | Equals | `{"op": "eq", "field": "status", "value": "active"}` |
| `neq` | Not equals | `{"op": "neq", "field": "status", "value": "deleted"}` |
| `gt` | Greater than | `{"op": "gt", "field": "age", "value": 18}` |
| `gte` | Greater than or equal | `{"op": "gte", "field": "score", "value": 100}` |
| `lt` | Less than | `{"op": "lt", "field": "price", "value": 50}` |
| `lte` | Less than or equal | `{"op": "lte", "field": "quantity", "value": 10}` |
| `contains` | String/list contains | `{"op": "contains", "field": "tags", "value": "urgent"}` |

#### `contains` Behavior by Type

- On **array**: checks if value is a member (`value in array`)
- On **string**: checks substring (`String.contains?/2`)
- On **object**: checks if key exists (`Map.has_key?/2`)
- On other types: returns `false`

#### Field-Based Comparisons

- All comparison ops use `field` to access the current item
- To compare the current value directly, use `field: null` or omit `field`

### 5.7 Logic Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `and` | Logical AND | `{"op": "and", "conditions": [...]}` |
| `or` | Logical OR | `{"op": "or", "conditions": [...]}` |
| `not` | Logical NOT | `{"op": "not", "condition": {...}}` |
| `if` | Conditional | `{"op": "if", "condition": ..., "then": ..., "else": ...}` |

#### `if`

Two-branch conditional. The `else` branch is **required**.

```json
{
  "op": "if",
  "condition": {"op": "gt", "field": "total", "value": 1000},
  "then": {"op": "literal", "value": "high_value"},
  "else": {"op": "literal", "value": "low_value"}
}
```

### 5.8 Tool Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `call` | Call a registered tool | `{"op": "call", "tool": "get_users", "args": {...}}` |

#### `call`

Invokes a registered tool function.

```json
{"op": "call", "tool": "get_users"}
{"op": "call", "tool": "get_expenses", "args": {"year": 2024}}
{"op": "call", "tool": "search", "args": {"query": "foo", "limit": 10}}
```

**Tool behavior:**
- Tools receive `args` as a map (may be empty `{}`)
- Tools may have side effects (external API calls, database queries)
- Tool errors propagate as execution errors
- Tool results count toward memory limit

### 5.9 Combine Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `merge` | Merge objects | `{"op": "merge", "objects": [...]}` |
| `concat` | Concatenate lists | `{"op": "concat", "lists": [...]}` |
| `zip` | Zip lists together | `{"op": "zip", "lists": [...]}` |

#### `merge`

Merges objects. Later objects override earlier objects (last wins).

```json
{
  "op": "merge",
  "objects": [
    {"op": "var", "name": "defaults"},
    {"op": "var", "name": "overrides"}
  ]
}
```

#### `concat`

Concatenates arrays.

```json
{
  "op": "concat",
  "lists": [
    {"op": "var", "name": "list1"},
    {"op": "var", "name": "list2"}
  ]
}
```

#### `zip`

Combines arrays into tuples. Stops at the shortest array length.

```json
{
  "op": "zip",
  "lists": [
    {"op": "literal", "value": [1, 2, 3]},
    {"op": "literal", "value": ["a", "b"]}
  ]
}
```

Result: `[[1, "a"], [2, "b"]]`

---

## 6. Variable Bindings and Context

### 6.1 `load` vs `var`

- `load` reads from the **context** passed to `run/2` (external data)
- `var` reads from **let bindings** within the program (internal variables)
- Both return `null` if the name doesn't exist (no error)

### 6.2 `let` Scoping

- Inner `let` bindings shadow outer bindings with the same name
- Bindings are only visible within the `in` expression

### 6.3 Context Usage

```elixir
# Running with pre-bound context
PtcRunner.run(program,
  context: %{
    "previous_expenses" => [...],
    "user_preferences" => %{...}
  },
  tools: %{
    "get_expenses" => &MyApp.get_expenses/1
  }
)
```

---

## 7. Complete Examples

### 7.1 Filter and Sum Expenses

```json
{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "expenses"},
      {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
      {"op": "sum", "field": "amount"}
    ]
  }
}
```

### 7.2 Query Voice Call Transcripts

```json
{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "call", "tool": "get_voice_calls"},
      {"op": "filter", "where": {"op": "eq", "field": "status", "value": "completed"}},
      {"op": "filter", "where": {"op": "gt", "field": "duration_ms", "value": 60000}},
      {"op": "select", "fields": ["id", "transcript", "duration_ms"]}
    ]
  }
}
```

### 7.3 Combine Data from Multiple Sources

```json
{
  "program": {
    "op": "let",
    "name": "users",
    "value": {"op": "call", "tool": "get_users"},
    "in": {
      "op": "let",
      "name": "orders",
      "value": {"op": "call", "tool": "get_orders"},
      "in": {
        "op": "pipe",
        "steps": [
          {"op": "var", "name": "orders"},
          {"op": "filter", "where": {"op": "gt", "field": "total", "value": 100}},
          {"op": "map", "expr": {
            "op": "merge",
            "objects": [
              {"op": "get", "path": []},
              {"op": "pipe", "steps": [
                {"op": "var", "name": "users"},
                {"op": "filter", "where": {"op": "eq", "field": "id", "value": {"op": "get", "path": ["user_id"]}}},
                {"op": "first"},
                {"op": "select", "fields": ["name", "email"]}
              ]}
            ]
          }}
        ]
      }
    }
  }
}
```

### 7.4 Conditional Logic

```json
{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "invoice"},
      {"op": "let", "name": "total", "value": {"op": "get", "path": ["total"]}, "in": {
        "op": "if",
        "condition": {"op": "gt", "field": "total", "value": 1000},
        "then": {"op": "literal", "value": "high_value"},
        "else": {
          "op": "if",
          "condition": {"op": "gt", "field": "total", "value": 100},
          "then": {"op": "literal", "value": "medium_value"},
          "else": {"op": "literal", "value": "low_value"}
        }
      }}
    ]
  }
}
```

### 7.5 Multi-Turn Conversation

```elixir
# Turn 1: Get expenses
{:ok, expenses, _metrics} = PtcRunner.run(
  ~s({"program": {"op": "call", "tool": "get_expenses"}}),
  tools: tools
)

# Turn 2: Use previous result
{:ok, total, _metrics} = PtcRunner.run(
  ~s({
    "program": {
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "previous_expenses"},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
        {"op": "sum", "field": "amount"}
      ]
    }
  }),
  context: %{"previous_expenses" => expenses},
  tools: tools
)
```

---

## 8. Semantic Specifications

### 8.1 Pipe Behavior

**Empty `pipe`:**
- `{"op": "pipe", "steps": []}` returns `null`

**`pipe` input:**
- First step receives `null` as input (unless it's `load`, `var`, `call`, or `literal`)
- Each subsequent step receives the previous step's output

**Current item in `map`:**
- Inside a `map` expression, `{"op": "get", "path": []}` returns the current item

### 8.2 Type Handling

**Collection operations on wrong types:**
- `filter`, `map`, `reject` on non-array → `{:error, {:execution_error, "..."}}`
- `select` on non-object → error
- Operations fail fast with descriptive errors

**`nth` with invalid index:**
- Negative indices → error (not supported)
- Out of bounds → returns `null`

### 8.3 Aggregation Edge Cases

**Non-numeric fields:**
- `avg` skips non-numeric values entirely (not counted in denominator)
- `sum` errors on non-numeric values
- `min`, `max` use Elixir's term ordering
- `min_by`, `max_by` skip items with `null` field values and return the entire row

---

## 9. Error Handling

### 9.1 Error Types

| Error Type | Cause |
|------------|-------|
| `parse_error` | Invalid JSON syntax |
| `validation_error` | Invalid program structure |
| `execution_error` | Runtime error |
| `timeout` | Execution time exceeded |
| `memory_exceeded` | Memory limit exceeded |

### 9.2 Error Format

```elixir
{:error, {:parse_error, "Unexpected token at position 42"}}
{:error, {:validation_error, "Unknown operation 'filer'. Did you mean 'filter'?"}}
{:error, {:execution_error, "Cannot access field 'name' on null"}}
{:error, {:timeout, 1000}}
{:error, {:memory_exceeded, 10485760}}
```

---

## 10. Resource Limits

### 10.1 Default Limits

| Resource | Default | Notes |
|----------|---------|-------|
| Timeout | 1,000 ms | Execution time limit |
| Max Heap | ~10 MB | Memory limit (1,250,000 words) |
| Max Depth | 50 | Nesting depth limit |

### 10.2 Configuring Limits

```elixir
PtcRunner.run(program,
  timeout: 5000,      # 5 seconds
  max_heap: 5_000_000 # ~40MB
)
```

---

## 11. Out of Scope

These features are intentionally excluded:

| Feature | Reason |
|---------|--------|
| `group_by` | Use tools for grouping |
| String operations | Use tools |
| Regex matching | Use tools |
| Arithmetic operations | Use tools or `let` with literals |
| Parallel tool execution | Tools execute sequentially |
| Anonymous functions | Not supported in JSON DSL |
| Closures | Not supported in JSON DSL |

---

## 12. Comparison with PTC-Lisp

| Aspect | PTC-JSON | PTC-Lisp |
|--------|----------|----------|
| **Status** | Stable, production-ready | Experimental |
| **Token efficiency** | ~1x (baseline) | ~3-5x better |
| **Parser complexity** | `JSON.decode` (1 line) | NimbleParsec (~500 LOC) |
| **Error location** | Exact position | Harder to pinpoint |
| **LLM familiarity** | Universal | Clojure subset |
| **Anonymous functions** | Not supported | `(fn [x] body)` |
| **Closures** | Not supported | Yes |

### When to Prefer Each

**Use PTC-JSON if:**
- Stability and proven implementation matter most
- Simple pipelines (filter → transform → aggregate) suffice
- Universal tooling and logging are priorities

**Use PTC-Lisp if:**
- Token costs are significant (3-5x reduction)
- Complex predicates with combinators are common
- Closures and dynamic predicates are needed

---

## Appendix A: Operation Quick Reference

### Data
- `literal` — `{"op": "literal", "value": v}`
- `var` — `{"op": "var", "name": "x"}`
- `load` — `{"op": "load", "name": "x"}`
- `let` — `{"op": "let", "name": "x", "value": ..., "in": ...}`

### Collections
- `pipe` — `{"op": "pipe", "steps": [...]}`
- `filter` — `{"op": "filter", "where": {...}}`
- `reject` — `{"op": "reject", "where": {...}}`
- `map` — `{"op": "map", "expr": {...}}`
- `select` — `{"op": "select", "fields": [...]}`
- `sort_by` — `{"op": "sort_by", "field": "x", "order": "asc"|"desc"}`
- `first` — `{"op": "first"}`
- `last` — `{"op": "last"}`
- `nth` — `{"op": "nth", "index": n}`
- `count` — `{"op": "count"}`

### Aggregation
- `sum` — `{"op": "sum", "field": "x"}`
- `avg` — `{"op": "avg", "field": "x"}`
- `min` — `{"op": "min", "field": "x"}`
- `max` — `{"op": "max", "field": "x"}`
- `min_by` — `{"op": "min_by", "field": "x"}`
- `max_by` — `{"op": "max_by", "field": "x"}`

### Access
- `get` — `{"op": "get", "field": "x"}` or `{"op": "get", "path": [...]}`
- `keys` — `{"op": "keys"}`
- `typeof` — `{"op": "typeof"}`

### Comparison
- `eq` — `{"op": "eq", "field": "x", "value": v}`
- `neq` — `{"op": "neq", "field": "x", "value": v}`
- `gt` — `{"op": "gt", "field": "x", "value": v}`
- `gte` — `{"op": "gte", "field": "x", "value": v}`
- `lt` — `{"op": "lt", "field": "x", "value": v}`
- `lte` — `{"op": "lte", "field": "x", "value": v}`
- `contains` — `{"op": "contains", "field": "x", "value": v}`

### Logic
- `and` — `{"op": "and", "conditions": [...]}`
- `or` — `{"op": "or", "conditions": [...]}`
- `not` — `{"op": "not", "condition": {...}}`
- `if` — `{"op": "if", "condition": ..., "then": ..., "else": ...}`

### Tools
- `call` — `{"op": "call", "tool": "name", "args": {...}}`

### Combine
- `merge` — `{"op": "merge", "objects": [...]}`
- `concat` — `{"op": "concat", "lists": [...]}`
- `zip` — `{"op": "zip", "lists": [...]}`

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024-XX-XX | Initial stable release, extracted from architecture.md |
