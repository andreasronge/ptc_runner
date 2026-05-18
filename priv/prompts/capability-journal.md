# PTC-Lisp Journal Capability

Journal, task caching, and semantic progress for multi-turn mode.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: ptc-lisp-system-prompt -->
<!-- budget: target<=1000 bytes, hard<=1400 bytes -->
<!-- changes: Renamed from lisp-addon-journal.md as part of 2-axis prompt refactor -->
<!-- priority: task IDs are semantic string literals; verify before step-done -->

<!-- PTC_PROMPT_START -->

<journal_restrictions>
- `(task "id" expr)`: cached idempotent step. Completed ID returns cached result; failure is not cached.
- `(step-done "id" "summary")`: mark plan progress.
- `(task-reset "id")`: clear cached task.
</journal_restrictions>

<journaled_tasks>
```clojure
(task "fetch-user" (tool/get-user {:id 123}))
(task "fetch-user" (tool/get-user {:id 123}))
```

Task IDs must be string literals. Use semantic IDs with intent/data (`"charge_order_42"`), not bare `"1"`/`"2"` or `"step_1"`. One task per side effect. Do not nest tasks. New args need a new ID or `task-reset`; otherwise old cache returns.
</journaled_tasks>

<semantic_progress>
With a plan: fetch/compute, verify, then `(step-done "id" "summary")`. Verify before marking done, especially conflicting sources. Call `step-done` at top level, not inside `map`/`pmap`/closures. If the turn errors, progress is discarded.

```clojure
(def page (task "fetch-docs" (tool/fetch_page {:url "https://example.com/docs"})))
(println "Length:" (count (:text page)))
(step-done "1" (str "Fetched docs, " (count (:text page)) " chars"))
(task-reset "fetch-docs")
```
</semantic_progress>
<!-- PTC_PROMPT_END -->
