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

You can call several tools in one program to gather data efficiently:

```clojure
(def users (tool/get-users {:role "admin"}))
(def logs (tool/get-logs {:level "error"}))
(println "users:" (count users) "logs:" (count logs))
```

Keep output concise — truncated at ~512 chars. Avoid decorative formatting.
Use `println` between turns for debugging.
</multi_turn_rules>

<state>
```clojure
(def results (tool/fetch-data {:id 123}))  ; stored across turns
results                                     ; access in later turns
```

`(budget/remaining)` returns turns, depth, and token usage for adaptive strategies.
</state>
<!-- PTC_PROMPT_END -->
