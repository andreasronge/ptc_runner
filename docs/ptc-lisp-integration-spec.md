# PTC-Lisp Integration Specification

This document specifies how the layers work together, expected transformations at each stage, and test scenarios to validate the design.

**Related Documents:**
- [ptc-lisp-specification.md](ptc-lisp-specification.md) — Language specification
- [ptc-lisp-parser-plan.md](ptc-lisp-parser-plan.md) — Parser implementation
- [ptc-lisp-analyze-plan.md](ptc-lisp-analyze-plan.md) — Validation/desugaring layer
- [ptc-lisp-eval-plan.md](ptc-lisp-eval-plan.md) — Interpreter implementation

---

## 1. Pipeline Overview

```
Source (string)
    │
    ▼
┌─────────────────┐
│     Parser      │  NimbleParsec: source → RawAST
└─────────────────┘
    │
    ▼
┌─────────────────┐
│    Analyze      │  Validate + desugar: RawAST → CoreAST
└─────────────────┘
    │
    ▼
┌─────────────────┐
│      Eval       │  Interpret: CoreAST → value
└─────────────────┘
    │
    ▼
┌─────────────────┐
│ Memory Contract │  Apply result contract: value → (result, delta, new_memory)
└─────────────────┘
```

---

## 2. Reference Example: High-Paid Employees

This example exercises the full pipeline:

```clojure
(let [high-paid (->> (call "find-employees" {})
                     (filter (where :salary > 100000)))]
  {:high-paid high-paid
   :count (count high-paid)
   :result (pluck :email high-paid)})
```

**What it exercises:**
- Tool call (`call "find-employees"`)
- Threading (`->>`)
- `where` predicate with comparison operator
- `filter` with predicate
- `let` binding
- Map literal return with `:result` key (memory contract)
- Multiple builtins (`count`, `pluck`)

---

## 3. Layer-by-Layer Transformation

### 3.1 Parser Output (RawAST)

Input source produces tagged tuples:

```
{:list, [
  {:symbol, :let},
  {:vector, [
    {:symbol, :"high-paid"},
    {:list, [
      {:symbol, :->>},
      {:list, [{:symbol, :call}, {:string, "find-employees"}, {:map, []}]},
      {:list, [
        {:symbol, :filter},
        {:list, [{:symbol, :where}, {:keyword, :salary}, {:symbol, :>}, 100000]}
      ]}
    ]}
  ]},
  {:map, [
    {{:keyword, :"high-paid"}, {:symbol, :"high-paid"}},
    {{:keyword, :count}, {:list, [{:symbol, :count}, {:symbol, :"high-paid"}]}},
    {{:keyword, :result}, {:list, [{:symbol, :pluck}, {:keyword, :email}, {:symbol, :"high-paid"}]}}
  ]}
]}
```

### 3.2 Analyze Output (CoreAST)

After validation and desugaring:

```
{:let,
  [{:binding, {:var, :"high-paid"},
    {:call, {:var, :filter}, [
      {:where, {:field, [{:keyword, :salary}]}, :gt, 100000},
      {:call_tool, "find-employees", {:map, []}}
    ]}}
  ],
  {:map, [
    {{:keyword, :"high-paid"}, {:var, :"high-paid"}},
    {{:keyword, :count}, {:call, {:var, :count}, [{:var, :"high-paid"}]}},
    {{:keyword, :result}, {:call, {:var, :pluck}, [{:keyword, :email}, {:var, :"high-paid"}]}}
  ]}
}
```

**Key transformations:**
- `->>` desugared: `(->> x (f a))` → `{:call, {:var, :f}, [a, x]}`
- `where` recognized: `(where :field op val)` → `{:where, path, op_tag, val}`
- Symbols resolved: `high-paid` → `{:var, :"high-paid"}`
- `call` validated: tool name is string → `{:call_tool, name, args}`

### 3.3 Eval Execution

Given tools:
```
tools = %{
  "find-employees" => fn _ ->
    [%{id: 1, name: "Alice", salary: 150000, email: "alice@ex.com"},
     %{id: 2, name: "Bob", salary: 80000, email: "bob@ex.com"}]
  end
}
```

**Execution trace:**

1. **Evaluate `let` binding**
   - Evaluate `{:call, {:var, :filter}, [where_ast, tool_call_ast]}`
   - First evaluate args left-to-right:
     - `{:where, ...}` → predicate closure: `fn row -> row.salary > 100000 end`
     - `{:call_tool, ...}` → invoke tool → `[%{...Alice...}, %{...Bob...}]`
   - Apply `filter(pred, employees)` → `[%{id: 1, ...Alice...}]`

2. **Bind in environment**
   - `env = %{:"high-paid" => [%{id: 1, ...}]}`

3. **Evaluate map body**
   - Key `:high-paid` → value from `{:var, :"high-paid"}` → `[%{...}]`
   - Key `:count` → `count([%{...}])` → `1`
   - Key `:result` → `pluck(:email, [%{...}])` → `["alice@ex.com"]`

**Eval output:**
```
%{
  :"high-paid" => [%{id: 1, name: "Alice", salary: 150000, email: "alice@ex.com"}],
  :count => 1,
  :result => ["alice@ex.com"]
}
```

### 3.4 Memory Contract

The returned map has `:result` key, so:

| Field | Value |
|-------|-------|
| `result` | `["alice@ex.com"]` |
| `delta` | `%{:"high-paid" => [...], :count => 1}` |
| `new_memory` | `Map.merge(old_memory, delta)` |

**Final return:**
```
{:ok, ["alice@ex.com"], %{:"high-paid" => [...], :count => 1}, new_memory}
```

---

## 4. Test Scenarios

### 4.1 Parser Tests

| Scenario | Input | Expected RawAST |
|----------|-------|-----------------|
| Nil literal | `nil` | `nil` |
| Integer | `42` | `42` |
| Negative float | `-3.14` | `-3.14` |
| String with escape | `"hello\nworld"` | `{:string, "hello\nworld"}` |
| Keyword | `:status` | `{:keyword, :status}` |
| Symbol | `filter` | `{:symbol, :filter}` |
| Operator symbol | `->>` | `{:symbol, :->>}` |
| Namespaced symbol | `ctx/input` | `{:ns_symbol, :ctx, :input}` |
| Empty vector | `[]` | `{:vector, []}` |
| Map with pairs | `{:a 1}` | `{:map, [{{:keyword, :a}, 1}]}` |
| List (call) | `(+ 1 2)` | `{:list, [{:symbol, :+}, 1, 2]}` |
| Comment ignored | `42 ; comment` | `42` |
| Comma as whitespace | `[1, 2, 3]` | `{:vector, [1, 2, 3]}` |

**Error cases:**
- Unclosed string → parse error
- Unclosed vector → parse error
- Odd map elements → parse error
- Multiline string (literal newline) → parse error
- Namespaced keyword `:foo/bar` → parse error

### 4.2 Analyze Tests

| Scenario | Input (RawAST) | Expected CoreAST |
|----------|----------------|------------------|
| Symbol → var | `{:symbol, :x}` | `{:var, :x}` |
| ctx namespace | `{:ns_symbol, :ctx, :input}` | `{:ctx, :input}` |
| memory namespace | `{:ns_symbol, :memory, :data}` | `{:memory, :data}` |
| `when` desugars | `(when cond body)` | `{:if, cond, body, nil}` |
| `cond` desugars | `(cond a 1 b 2 :else 3)` | `{:if, a, 1, {:if, b, 2, 3}}` |
| `->>` desugars | `(->> x (f a) (g))` | `{:call, g, [{:call, f, [a, x]}]}` |
| `where` with op | `(where :f = v)` | `{:where, {:field, [{:keyword, :f}]}, :eq, v}` |
| `where` truthy | `(where :active)` | `{:where, {:field, ...}, :truthy, nil}` |
| `all-of` combinator | `(all-of p1 p2)` | `{:pred_combinator, :all_of, [p1, p2]}` |
| Empty `all-of` | `(all-of)` | `{:pred_combinator, :all_of, []}` |
| `call` tool | `(call "name" {})` | `{:call_tool, "name", {:map, []}}` |

**Error cases:**
- `(if cond then)` → invalid arity (requires 3 args)
- `(where :field badop val)` → invalid where operator
- `(call :name {})` → tool name must be string
- `(let [x])` → odd binding count

### 4.3 Eval Tests

#### Literals and Collections

| Scenario | CoreAST | Expected Value |
|----------|---------|----------------|
| Nil | `nil` | `nil` |
| Boolean | `true` | `true` |
| String | `{:string, "hi"}` | `"hi"` |
| Keyword | `{:keyword, :foo}` | `:foo` |
| Vector | `{:vector, [1, 2]}` | `[1, 2]` |
| Map | `{:map, [{{:keyword, :a}, 1}]}` | `%{a: 1}` |

#### Variable Access

| Scenario | Setup | CoreAST | Expected |
|----------|-------|---------|----------|
| Local var | `env = %{x: 42}` | `{:var, :x}` | `42` |
| ctx access | `ctx = %{input: [1,2]}` | `{:ctx, :input}` | `[1, 2]` |
| memory access | `memory = %{cached: "v"}` | `{:memory, :cached}` | `"v"` |
| Missing ctx key | `ctx = %{}` | `{:ctx, :missing}` | `nil` |

#### `where` Predicates

| Scenario | Predicate | Data | Matches? |
|----------|-----------|------|----------|
| Equality | `(where :status = "active")` | `%{status: "active"}` | true |
| Equality | `(where :status = "active")` | `%{status: "inactive"}` | false |
| Greater than | `(where :age > 18)` | `%{age: 20}` | true |
| Greater than | `(where :age > 18)` | `%{age: 15}` | false |
| Nil field (gt) | `(where :age > 18)` | `%{name: "Bob"}` | false (safe) |
| Nil equality | `(where :field = nil)` | `%{field: nil}` | **true** |
| Nil equality | `(where :field = nil)` | `%{field: "x"}` | false |
| Truthy check | `(where :active)` | `%{active: true}` | true |
| Truthy check | `(where :active)` | `%{active: false}` | false |
| Truthy check | `(where :active)` | `%{active: nil}` | false |
| Nested path | `(where [:user :age] > 18)` | `%{user: %{age: 25}}` | true |
| `in` operator | `(where :status in ["a" "b"])` | `%{status: "a"}` | true |
| `includes` (list) | `(where :tags includes "urgent")` | `%{tags: ["urgent"]}` | true |
| `includes` (string) | `(where :name includes "Ali")` | `%{name: "Alice"}` | true |

#### Predicate Combinators

| Scenario | Combinator | Predicates | Data | Matches? |
|----------|------------|------------|------|----------|
| all-of (both match) | `all-of` | `[:a = 1, :b = 2]` | `%{a: 1, b: 2}` | true |
| all-of (one fails) | `all-of` | `[:a = 1, :b = 2]` | `%{a: 1, b: 3}` | false |
| any-of (one matches) | `any-of` | `[:x = 1, :y = 1]` | `%{x: 1, y: 2}` | true |
| any-of (none match) | `any-of` | `[:x = 1, :y = 1]` | `%{x: 2, y: 2}` | false |
| none-of (none match) | `none-of` | `[:deleted = true]` | `%{active: true}` | true |
| Empty all-of | `all-of` | `[]` | any | true |
| Empty any-of | `any-of` | `[]` | any | false |
| Empty none-of | `none-of` | `[]` | any | true |

#### Short-Circuit Logic

| Scenario | Expression | Expected |
|----------|------------|----------|
| and all truthy | `(and 1 2 3)` | `3` |
| and first falsy | `(and 1 nil 3)` | `nil` |
| and empty | `(and)` | `true` |
| or first truthy | `(or nil 2 3)` | `2` |
| or all falsy | `(or nil false)` | `false` |
| or empty | `(or)` | `nil` |

#### Closures and `fn`

| Scenario | Expression | Expected |
|----------|------------|----------|
| Simple fn | `((fn [x] (+ x 1)) 5)` | `6` |
| Multi-param | `((fn [a b] (+ a b)) 2 3)` | `5` |
| Closure capture | `(let [n 10] (filter (fn [x] (> x n)) [5 15]))` | `[15]` |

#### Keyword as Function

| Scenario | Expression | Expected |
|----------|------------|----------|
| Single arg | `(:name {:name "Alice"})` | `"Alice"` |
| Missing key | `(:missing {:name "Alice"})` | `nil` |
| With default | `(:missing {:a 1} "default")` | `"default"` |
| Nil map | `(:name nil)` | `nil` |

#### Variadic Builtins

| Scenario | Expression | Expected |
|----------|------------|----------|
| `(+ 1 2 3)` | variadic add | `6` |
| `(+)` | zero args | `0` |
| `(+ 5)` | one arg | `5` |
| `(* 2 3 4)` | variadic mult | `24` |
| `(*)` | zero args | `1` |
| `(- 10 3 2)` | variadic sub | `5` |
| `(- 5)` | unary negation | `-5` |
| `(max 1 5 3)` | variadic max | `5` |
| `(min 1 5 3)` | variadic min | `1` |
| `(max)` | zero args | **error** |
| `(concat [1] [2] [3])` | variadic concat | `[1, 2, 3]` |

### 4.4 Memory Contract Tests

| Scenario | Eval Result | Expected Output |
|----------|-------------|-----------------|
| Non-map (number) | `42` | `result=42, delta=%{}, memory unchanged` |
| Non-map (vector) | `[1, 2]` | `result=[1,2], delta=%{}, memory unchanged` |
| Map without :result | `%{count: 5}` | `result=%{count: 5}, delta=%{count: 5}, memory merged` |
| Map with :result | `%{result: "done", x: 1}` | `result="done", delta=%{x: 1}, memory merged` |
| Map with :result only | `%{result: %{a: 1}}` | `result=%{a: 1}, delta=%{}, memory unchanged` |

---

## 5. Edge Cases and Gotchas

### 5.1 Nil Semantics

| Context | Expression | Result |
|---------|------------|--------|
| `where` equality | `nil = nil` | `true` (explicit nil match) |
| `where` ordering | `nil > 5` | `false` (safe, no error) |
| Direct comparison | `(> nil 5)` | **type error** |
| Arithmetic | `(+ 1 nil)` | **type error** |
| Map access | `(get nil :key)` | `nil` |

### 5.2 Symbol Boundaries

Parser must not match keywords as prefixes:

| Input | Expected | NOT |
|-------|----------|-----|
| `nil` | `nil` literal | — |
| `nilly` | `{:symbol, :nilly}` | NOT `nil` + "ly" |
| `true?` | `{:symbol, :true?}` | NOT `true` |
| `false-positive` | `{:symbol, :"false-positive"}` | NOT `false` |

### 5.3 Threading Order

Thread-last (`->>`) inserts value as **last** argument:

```clojure
(->> x (f a) (g b))
;; Step 1: (f a x)
;; Step 2: (g b (f a x))
```

Thread-first (`->`) inserts value as **first** argument:

```clojure
(-> x (f a) (g b))
;; Step 1: (f x a)
;; Step 2: (g (f x a) b)
```

### 5.4 Atom Kebab-Case

Elixir atoms preserve kebab-case:

| PTC-Lisp | Elixir Atom |
|----------|-------------|
| `:high-paid` | `:"high-paid"` |
| `high-paid` (symbol) | `:"high-paid"` |

This is correct behavior but worth noting for debugging.

---

## 6. Error Messages

Errors should be structured for LLM feedback:

```
{:error, {:parse_error, message}}
{:error, {:validation_error, message}}
{:error, {:type_error, expected, got}}
{:error, {:arity_error, message}}
{:error, {:unbound_var, name}}
{:error, {:tool_error, tool_name, reason}}
{:error, {:timeout, milliseconds}}
```

Example formatted for LLM:

```
parse-error at line 3, column 15:
  (filter (where :status "active") coll)
                 ^
  Expected operator (=, >, <, etc.) after field name.

  Hint: Use (where :status = "active")
```

---

## 7. Implementation Checklist

### Parser
- [ ] All literal types (nil, bool, number, string, keyword)
- [ ] Symbols with special chars (`->>`, `>=`, `empty?`)
- [ ] Namespaced symbols (`ctx/x`, `memory/y`)
- [ ] Collections (vector, map, list)
- [ ] Whitespace and comments
- [ ] Error recovery with line/column

### Analyze
- [ ] Symbol → var resolution
- [ ] Namespace symbol dispatch
- [ ] `let` with destructuring
- [ ] `if` (3 args required)
- [ ] `when` → `if` desugaring
- [ ] `cond` → nested `if`
- [ ] `->` and `->>` threading
- [ ] `where` validation
- [ ] `all-of`, `any-of`, `none-of`
- [ ] `call` tool name validation
- [ ] `fn` parameter extraction

### Eval
- [ ] Literal passthrough
- [ ] Collection evaluation
- [ ] Variable lookup
- [ ] `ctx/` and `memory/` access
- [ ] `let` binding with pattern match
- [ ] `if` conditional (truthy semantics)
- [ ] `and`/`or` short-circuit
- [ ] `fn` closure creation
- [ ] Function application (normal, variadic, keyword)
- [ ] `where` predicate builder
- [ ] Predicate combinators
- [ ] Tool invocation
- [ ] Nil-safe comparisons in `where`

### Memory Contract
- [ ] Non-map → no update
- [ ] Map without `:result` → merge all
- [ ] Map with `:result` → merge rest, return result
- [ ] Delta tracking

### Runtime Builtins
- [ ] Collection ops (filter, map, pluck, etc.)
- [ ] Ordering (sort, sort-by, reverse)
- [ ] Subsetting (first, last, take, drop, take-while, drop-while)
- [ ] Aggregation (count, sum-by, avg-by, min-by, max-by, group-by)
- [ ] Map ops (get, get-in, assoc, merge, etc.)
- [ ] Arithmetic (+, -, *, /, inc, dec, abs, max, min)
- [ ] Comparison (=, not=, <, >, <=, >=)
- [ ] Logic (not) — `and`/`or` are special forms
- [ ] Type predicates (nil?, string?, map?, etc.)
- [ ] Numeric predicates (zero?, pos?, neg?, even?, odd?)

---

## 8. Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1.0 | — | Initial integration specification |
