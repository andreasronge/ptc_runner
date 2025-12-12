# PTC-JSON Language Specification

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
| `take` | Take first N items | `{"op": "take", "count": 5}` |
| `drop` | Drop first N items | `{"op": "drop", "count": 5}` |
| `distinct` | Remove duplicates | `{"op": "distinct"}` |
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

#### `take`

Takes the first N items from a list.

```json
{"op": "take", "count": 5}
```

- `count` (required, non-negative integer): Number of items to take from the beginning
- Returns the first `count` items, or the entire list if `count` exceeds the list length
- Returns `[]` if applied to an empty list or if `count` is 0

#### `drop`

Drops (skips) the first N items from a list.

```json
{"op": "drop", "count": 5}
```

- `count` (required, non-negative integer): Number of items to skip
- Returns the remaining items after dropping the first `count` items
- Returns `[]` if `count` is greater than or equal to the list length
- Returns the entire list if `count` is 0

#### `distinct`

Removes duplicate values from a list, preserving the first occurrence order.

```json
{"op": "distinct"}
```

- Works with values of any type (numbers, strings, objects, etc.)
- Uses structural equality for comparison (e.g., objects with the same content are equal)
- Returns a list with duplicates removed while maintaining the order of first occurrences
- Returns `[]` if applied to an empty list

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

### 5.7 Arithmetic Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `add` | Add two numbers | `{"op": "add", "left": 5, "right": 3}` |
| `sub` | Subtract two numbers | `{"op": "sub", "left": 10, "right": 3}` |
| `mul` | Multiply two numbers | `{"op": "mul", "left": 5, "right": 3}` |
| `div` | Divide two numbers (returns float) | `{"op": "div", "left": 10, "right": 4}` |
| `round` | Round to N decimal places | `{"op": "round", "value": 3.14159, "precision": 2}` |
| `pct` | Calculate percentage | `{"op": "pct", "part": 50, "whole": 100}` |

#### `add`

Adds two numbers. Both operands are expressions (recursively evaluated).

```json
{"op": "add", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 3}}
```

Result: `8`

#### `sub`

Subtracts the right operand from the left operand.

```json
{"op": "sub", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 3}}
```

Result: `7`

#### `mul`

Multiplies two numbers.

```json
{"op": "mul", "left": {"op": "literal", "value": 5}, "right": {"op": "literal", "value": 3}}
```

Result: `15`

#### `div`

Divides the left operand by the right operand. Always returns a float (Elixir's `/` operator behavior). Returns an error if the divisor is zero.

```json
{"op": "div", "left": {"op": "literal", "value": 10}, "right": {"op": "literal", "value": 4}}
```

Result: `2.5`

**Note:** For integer division, use `div` followed by `round` with `precision: 0`.

#### `round`

Rounds a number to a specified number of decimal places. Precision defaults to 0 (round to nearest integer). Precision must be a non-negative integer (0-15).

```json
{"op": "round", "value": {"op": "literal", "value": 3.14159}, "precision": 2}
```

Result: `3.14`

**Precision examples:**
- `"precision": 0` — round to nearest integer
- `"precision": 1` — round to tenths
- `"precision": 2` — round to hundredths
- `"precision": 3` — round to thousandths

#### `pct`

Calculates a percentage: `(part / whole) * 100`. This is a convenience operation for the common case of calculating ratios as percentages. Returns an error if `whole` is zero.

```json
{"op": "pct", "part": {"op": "literal", "value": 50}, "whole": {"op": "literal", "value": 100}}
```

Result: `50.0`

**With variables (memory):**

```json
{
  "op": "let",
  "name": "delivered",
  "value": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "orders"},
      {"op": "filter", "where": {"op": "eq", "field": "status", "value": "delivered"}},
      {"op": "count"}
    ]
  },
  "in": {
    "op": "let",
    "name": "total",
    "value": {
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "orders"},
        {"op": "count"}
      ]
    },
    "in": {
      "op": "pct",
      "part": {"op": "var", "name": "delivered"},
      "whole": {"op": "var", "name": "total"}
    }
  }
}
```

Result (with 2 delivered out of 3 orders): `66.66666...`

#### Arithmetic Operation Semantics

- All arithmetic operations work with both integers and floats
- Operations take **expressions** as operands (not just literals) — operands are recursively evaluated
- Non-numeric operands → `{:error, {:execution_error, "...requires numeric operands..."}}`
- Division by zero → `{:error, {:execution_error, "division by zero"}}`
- Percentage with zero whole → `{:error, {:execution_error, "division by zero"}}`

### 5.8 Logic Operations

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

### 5.9 Tool Operations

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

### 5.10 Combine Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `object` | Construct object with evaluated values | `{"op": "object", "fields": {...}}` |
| `merge` | Merge objects | `{"op": "merge", "objects": [...]}` |
| `concat` | Concatenate lists | `{"op": "concat", "lists": [...]}` |
| `zip` | Zip lists together | `{"op": "zip", "lists": [...]}` |

#### `object`

Constructs a map from literal and expression field values. Field values that are objects with an `"op"` field are evaluated as expressions; other values are passed through as literals.

```json
{
  "op": "object",
  "fields": {
    "count": {"op": "var", "name": "n"},
    "name": "test"
  }
}
```

Result: `{"count": <value of n>, "name": "test"}`

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
PtcRunner.Json.run(program,
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
{:ok, expenses, _metrics} = PtcRunner.Json.run(
  ~s({"program": {"op": "call", "tool": "get_expenses"}}),
  tools: tools
)

# Turn 2: Use previous result
{:ok, total, _metrics} = PtcRunner.Json.run(
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
PtcRunner.Json.run(program,
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
| Modulo / bitwise operations | Can add if needed |
| Math functions (sqrt, pow, log) | Use tools for advanced math |
| Parallel tool execution | Tools execute sequentially |
| Anonymous functions | Not supported in JSON DSL |
| Closures | Not supported in JSON DSL |

---

## 12. Comparison with PTC-Lisp

| Aspect | PTC-JSON | PTC-Lisp |
|--------|----------|----------|
| **Status** | Stable | Stable (v0.3.0+) |
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

### Arithmetic
- `add` — `{"op": "add", "left": ..., "right": ...}`
- `sub` — `{"op": "sub", "left": ..., "right": ...}`
- `mul` — `{"op": "mul", "left": ..., "right": ...}`
- `div` — `{"op": "div", "left": ..., "right": ...}`
- `round` — `{"op": "round", "value": ..., "precision": n}`
- `pct` — `{"op": "pct", "part": ..., "whole": ...}`

### Logic
- `and` — `{"op": "and", "conditions": [...]}`
- `or` — `{"op": "or", "conditions": [...]}`
- `not` — `{"op": "not", "condition": {...}}`
- `if` — `{"op": "if", "condition": ..., "then": ..., "else": ...}`

### Tools
- `call` — `{"op": "call", "tool": "name", "args": {...}}`

### Combine
- `object` — `{"op": "object", "fields": {...}}`
- `merge` — `{"op": "merge", "objects": [...]}`
- `concat` — `{"op": "concat", "lists": [...]}`
- `zip` — `{"op": "zip", "lists": [...]}`

