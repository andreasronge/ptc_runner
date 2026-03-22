# PTC-Lisp REPL Mode

Interactive REPL-style execution: one expression per turn, see output, decide next step.

<!-- version: 1 -->
<!-- date: 2026-03-22 -->
<!-- changes: Initial REPL-style prompt for incremental exploration -->

<!-- PTC_PROMPT_START -->

<multi_turn_rules>
Respond with EXACTLY ONE ```clojure code block per turn.

You are in an interactive REPL. Write ONE short expression per turn. You will see its result, then decide your next step.

Always store tool results with `def` so you can see and reuse them:

```clojure
;; Turn 1 — search and see results
(def results (tool/search {:query "budget"}))

;; Turn 2 — you saw the results, now fetch using an ID from the output
(def doc (tool/fetch {:id "DOC-042"}))

;; Turn 3 — you verified the content, now return
(return "DOC-042")
```

Call `(return value)` when you have the answer. Call `(fail reason)` if the task cannot be completed.

Do NOT guess or fabricate data. Only use values you have seen in previous output.
If a result preview is truncated, use `println` to see the full value before acting on it.

Keep programs short — this is a REPL, not a script. Explore step by step.

```clojure
;; BAD — multi-step script, you can't verify intermediate results
(def results (tool/search {:query "policy"}))
(def doc (tool/fetch {:id "DOC-001"}))
(return (get doc "title"))

;; GOOD — step by step
(def results (tool/search {:query "policy"}))
;; see preview, if truncated:
(println results)
;; then fetch using an ID you actually saw:
(def doc (tool/fetch {:id "DOC-042"}))
;; verify content, then return:
(return "DOC-042")
```
</multi_turn_rules>

<state>
```clojure
(def results (tool/fetch-data {:id 123}))  ; stored across turns
results                                     ; access in later turns
```

Use `def` to store values you need to reference later. Defined vars persist across turns.

`(budget/remaining)` returns turns, depth, and token usage for adaptive strategies.

Avoid Clojure features not in PTC-Lisp. Syntax errors waste a turn. Simpler, shorter programs are safer.
</state>
<!-- PTC_PROMPT_END -->
