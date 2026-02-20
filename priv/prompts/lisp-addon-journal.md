# PTC-Lisp Journal Addon

Journal, task caching, and semantic progress for multi-turn mode.

<!-- version: 1 -->
<!-- date: 2026-02-20 -->
<!-- changes: Extracted from lisp-base.md and lisp-addon-multi_turn.md -->

<!-- PTC_PROMPT_START -->

<journal_restrictions>
- `(task "id" expr)` — journaled execution: if ID was already completed, returns cached result; otherwise evaluates expr and records it
- `(step-done "id" "summary")` — report progress on a plan step; `(task-reset "id")` — clear a cached task
</journal_restrictions>

<journaled_tasks>
Use `(task "id" expr)` to record idempotent steps. If the task ID was already completed in a previous turn, the cached result is returned without re-executing. If the task fails, the result is NOT recorded.

```clojure
;; First execution: calls tool and records result
(task "fetch-user" (tool/get-user {:id 123}))

;; Later turn: returns cached result without calling tool again
(task "fetch-user" (tool/get-user {:id 123}))
```

Task IDs must be string literals. The Mission Log in the system prompt shows which tasks have completed.

Semantic IDs: Encode intent and data in IDs — use `"charge_order_42"` not `"step_1"`. Never use bare numbers like `"1"` or `"2"` as task IDs — these collide with plan step IDs and cause false progress. One task per side-effect; avoid nesting tasks inside other tasks.

Reusing an ID returns the cached result. If you retry with different arguments, you must use a different ID — otherwise you silently get the old result.
</journaled_tasks>

<semantic_progress>
When a plan is provided, each turn should complete one step: fetch/compute, verify the result, then call `(step-done "id" "summary")`. The step-done call marks the step as done in the Progress checklist.

Verify before marking done. If a page contains conflicting values (e.g., old examples vs. current text), search for all candidates and reason through which is correct before calling `step-done`.

Use `(task-reset "id")` to clear a cached task result from the journal. Call `step-done` at top level in `do` blocks — it does not work inside `pmap`/`pcalls`/`map` closures.

Checklist update: `step-done` summaries appear in the Progress checklist on the next turn. If the current turn errors, summaries are discarded.

```clojure
;; Typical turn: fetch, verify, mark done
(def page (task "fetch-docs" (tool/fetch_page {:url "https://example.com/docs"})))
(println "Length:" (count (:text page)))
(step-done "1" (str "Fetched docs, " (count (:text page)) " chars"))

;; Clear a cached task to re-execute it
(task-reset "fetch-docs")
```
</semantic_progress>
<!-- PTC_PROMPT_END -->
