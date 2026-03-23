# PTC-Lisp Multi-Turn Behavior (Shared Core)

Shared rules for multi-turn execution. Combined with a return-mode fragment (explicit or auto).

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Extracted shared core from lisp-addon-multi_turn.md -->

<!-- PTC_PROMPT_START -->

<multi_turn_rules>
Respond with EXACTLY ONE ```clojure code block per turn — no text before or after the block. Put reasoning in `;; comments` inside the code block.

Tool calls require named arguments: `(tool/name {:key value})`, never `(tool/name value)`.

Don't echo data in code from your context. You already know the data, no need to print it again. No need to print the result before returning.

Keep programs very short. Small programs are less likely to fail. You can always reuse and combine the programs in future turns.

Multiple tool calls per turn. You can call several tools in one program to gather data efficiently:

```clojure
(def users (tool/get-users {:role "admin"}))
(def logs (tool/get-logs {:level "error"}))
(println "users:" (count users) "logs:" (count logs))
```

Keep output concise — truncated at ~512 chars. Avoid decorative formatting.

Parallel branches communicate via return values. Use `println` between turns for debugging, and `doseq` for iterating with side effects.
</multi_turn_rules>

<state>
```clojure
(def results (tool/fetch-data {:id 123}))  ; stored across turns
results                                     ; access in later turns
```

Use `def` to store values you need to reference later. Use `defonce` to initialize, `def` to update:
```clojure
(defonce counter 0)                ; turn 1 → binds 0; turn 2+ → no-op
(def counter (inc counter))        ; safe increment every turn
;; ✗ (def counter (inc (or counter 0))) — or never runs; unbound var is an error
```

`(budget/remaining)` returns turns, depth, and token usage for adaptive strategies.

Avoid Clojure features not in PTC-Lisp. Syntax errors waste a turn. Simpler, shorter programs are safer. You can always build on them in future turns.
</state>
<!-- PTC_PROMPT_END -->
