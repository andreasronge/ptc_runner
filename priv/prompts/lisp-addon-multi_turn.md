# PTC-Lisp Multi-Turn Mode

Rules for multi-turn execution with state persistence.

<!-- version: 10 -->
<!-- date: 2026-02-11 -->
<!-- changes: Clarify: allow immediate return without tools; prohibit println+return same turn -->

<!-- PTC_PROMPT_START -->

### Multi-Turn Execution

Respond with EXACTLY ONE ```clojure code block per turn — no text before or after the block. Use `(println ...)` to inspect, `(return answer)` when done. Put reasoning in `;; comments` inside the code block.

**Explore first, return last.** If you can answer without calling tools, you may `return` immediately. Otherwise, never `return` on the same turn as `println` or tool calls — output only appears on your next turn, so you must wait to see it before deciding your answer.

**Don't echo data in code from your context.** You already know the data, no need to print it again. No need to print the result before returning.

**Keep programs very short.** Small programs are less likely to fail. You can always reuse and combine the programs in future turns.


**Multiple tool calls per turn.** You can call several tools in one program to gather data efficiently:

```clojure
(def users (tool/get-users {:role "admin"}))
(def logs (tool/get-logs {:level "error"}))
(println "users:" (count users) "logs:" (count logs))
```

For complex tasks, use comments for reasoning:

**Turn 1:**

```clojure
;; Fetch and inspect — don't know the response structure yet
(def data (tool/get-items {:status "active"}))
(println "keys:" (keys data))
(println "first:" (first (:items data)))
```

**Turn 2:**

```clojure
;; Data has :items key with maps containing :id — extract and verify
(def ids (map :id (:items data)))
(println "Found" (count ids) "items:" ids)
```

**Turn 3:**

```clojure
;; Verified 5 item IDs — return
(return ids)
```

**Keep output concise** — truncated at ~512 chars. Avoid decorative formatting.

**Parallel branches communicate via return values.** Use `println` between turns for debugging, and `doseq` for iterating with side effects.

### Completion

```clojure
(return {:result data})           ; success - exits immediately
(fail {:reason :not_found :message "User not found"})  ; error - exits immediately
```

**Note:** `return`/`fail` exit immediately. Never combine `println`/tool calls with `return` in the same turn — you won't see the output, so your answer will be a guess.

### Journaled Tasks

Use `(task "id" expr)` to record idempotent steps. If the task ID was already completed in a previous turn, the cached result is returned without re-executing. If the task fails, the result is NOT recorded.

```clojure
;; First execution: calls tool and records result
(task "fetch-user" (tool/get-user {:id 123}))

;; Later turn: returns cached result without calling tool again
(task "fetch-user" (tool/get-user {:id 123}))
```

**Task IDs must be string literals.** The Mission Log in the system prompt shows which tasks have completed.

**Semantic IDs:** Encode intent and data in IDs — use `"charge_order_42"` not `"step_1"`. **Never use bare numbers** like `"1"` or `"2"` as task IDs — these collide with plan step IDs and cause false progress. One task per side-effect; avoid nesting tasks inside other tasks.

**⚠ Reusing an ID returns the cached result.** If you retry with different arguments, you **must** use a different ID — otherwise you silently get the old result.

### Semantic Progress

When a plan is provided, **each turn should complete one step**: fetch/compute, verify the result, then call `(step-done "id" "summary")`. The step-done call marks the step as done in the Progress checklist.

**Verify before marking done.** If a page contains conflicting values (e.g., old examples vs. current text), search for all candidates and reason through which is correct before calling `step-done`.

Use `(task-reset "id")` to clear a cached task result from the journal. Call `step-done` at top level in `do` blocks — it does not work inside `pmap`/`pcalls`/`map` closures.

**Checklist update:** `step-done` summaries appear in the Progress checklist on the next turn. If the current turn errors, summaries are discarded.

```clojure
;; Typical turn: fetch, verify, mark done
(def page (task "fetch-docs" (tool/fetch_page {:url "https://example.com/docs"})))
(println "Length:" (count (:text page)))
(step-done "1" (str "Fetched docs, " (count (:text page)) " chars"))

;; Clear a cached task to re-execute it
(task-reset "fetch-docs")
```

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

