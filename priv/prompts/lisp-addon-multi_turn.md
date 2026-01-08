# PTC-Lisp Multi-Turn Mode

Rules for multi-turn execution with state persistence.

<!-- version: 3 -->
<!-- date: 2026-01-08 -->
<!-- changes: Added "Explore Before Deciding" - don't hardcode thresholds, inspect data first -->

<!-- PTC_PROMPT_START -->

### Multi-Turn Execution

- Each turn: write code, inspect with `(println ...)`, continue or `(return answer)`
- **Every turn MUST include a code block** — if done, use `(return value)`
- Before calling more tools, check if you already have the answer

### Explore First

Use early turns to inspect data with `println`, then decide in later turns.

### Inspecting Values (Important!)

**You cannot see expression results** — use `println` to see what your code produced:

```clojure
(def results (ctx/search {:q "x"}))
(println "Found:" (count results))    ; ✓ you see: "Found: 42"
(println "First:" (first results))    ; ✓ you see: "{:id 1, :name ...}"
results                                ; ✗ you see nothing!
```

Without `println`, you're blind to intermediate results. Always inspect data before processing it.

**Keep output concise** — truncated at ~512 chars. Avoid decorative formatting.

### Completion

```clojure
(return {:result data})           ; success - ends execution
(fail {:reason :not_found :message "User not found"})  ; error - ends execution
```

### State Persistence

```clojure
(def results (ctx/search {:q "x"}))   ; stored across turns
results                                ; access in later turns
```

### Accessing Previous Results

| Symbol | Meaning |
|--------|---------|
| `*1` | Previous turn's result |
| `*2` | Two turns ago |
| `*3` | Three turns ago |

Use `def` to store values you need to reference later.

### Critical: Never Embed Observed Data

You see println output, but **cannot copy data into code**.

**Wrong:**
```clojure
(let [data [{:id 1 :name "Alice"}]]  ; NO - embedding observed data
  (count data))
```

**Right:**
```clojure
(def users (ctx/get-users))           ; store, then reference
(println "count:" (count users))      ; inspect
(filter (where :active) users)        ; use the stored value
```

<!-- PTC_PROMPT_END -->
