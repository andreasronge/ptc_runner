# PTC-Lisp Memory Addon

Multi-turn state and result access.

<!-- version: 6 -->
<!-- date: 2026-01-07 -->
<!-- changes: println-only feedback - expression results no longer shown -->

<!-- PTC_PROMPT_START -->

### Multi-Turn Rules

- Each turn: write code, use `(println ...)` to inspect, continue or `(return answer)`
- **Every turn MUST include a code block** — if done, use `(return value)`
- Before calling more tools, check if you already have the answer
- **Only `println` output is shown** — expression results are NOT displayed

### Inspecting Values

```clojure
(def results (ctx/search {:q "x"}))
(println "Found:" (count results))    ; shown in feedback
(println "First:" (first results))    ; shown in feedback
results                                ; NOT shown (use println to see it)
```

**Keep println concise** — output is truncated (~512 chars). Avoid decorative formatting like `"\n=== Header ==="`.

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
