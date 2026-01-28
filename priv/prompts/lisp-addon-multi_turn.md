# PTC-Lisp Multi-Turn Mode

Rules for multi-turn execution with state persistence.

<!-- version: 8 -->
<!-- date: 2026-01-26 -->
<!-- changes: Added budget/remaining for adaptive strategies -->

<!-- PTC_PROMPT_START -->

### Multi-Turn Execution

Respond with EXACTLY ONE ```clojure code block per turn. Use `(println ...)` to inspect, `(return answer)` when done.

**Explore first, return last.** Never `return` on your first turn. Always inspect results with `println` before returning. Only `return` after you've verified the data is correct.

**Don't echo data in code from your context.** You already know the data, no need to print it again. No need to print the result before returning.

**Keep programs very short.** Small programs are less likely to fail. You can always reuse and combine the programs in future turns.


**Multiple tool calls per turn.** You can call several tools in one program to gather data efficiently:

```clojure
(def users (tool/get-users {:role "admin"}))
(def logs (tool/get-logs {:level "error"}))
(println "users:" (count users) "logs:" (count logs))
```

For complex tasks, think through each step:

**Turn 1:**

Reason: I need to find active items, but I don't know the response structure yet. Let me fetch and inspect.

```clojure
(def data (tool/get-items {:status "active"}))
(println "keys:" (keys data))
(println "first:" (first (:items data)))
```

**Turn 2:**

Reason: I now see the data, it has an :items key with maps containing :id. Let me extract and inspect the IDs before returning.

```clojure
(def ids (map :id (:items data)))
(println "Found" (count ids) "items:" ids)
```

**Turn 3:**

Reason: I have 5 item IDs. The user asked for active items, and I've verified the structure. Now I can return.

```clojure
(return ids)
```

**Keep output concise** — truncated at ~512 chars. Avoid decorative formatting.

**Parallel branches communicate via return values.** Use `println` between turns for debugging, and `doseq` for iterating with side effects.

### Completion

```clojure
(return {:result data})           ; success - exits immediately
(fail {:reason :not_found :message "User not found"})  ; error - exits immediately
```

**Note:** `return`/`fail` exit immediately — don't `println` on the same turn, no one will see it.

### State Persistence

```clojure
(def results (tool/fetch-data {:id 123}))  ; stored across turns
results                                     ; access in later turns
```

### Accessing Previous Results

Use `def` to store values you need to reference later.

### Budget Introspection

`(budget/remaining)` returns turns, depth, and token usage for adaptive strategies.

**Avoid Clojure features not in PTC-Lisp.** Syntax errors waste a turn. Simpler, shorter programs are safer. You can always build on them in future turns.
<!-- PTC_PROMPT_END -->

