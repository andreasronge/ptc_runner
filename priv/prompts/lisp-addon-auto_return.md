# PTC-Lisp Auto-Return Mode

Rules for multi-turn execution with automatic return based on println presence.

<!-- version: 1 -->
<!-- date: 2026-03-21 -->
<!-- changes: Initial auto-return addon -->

<!-- PTC_PROMPT_START -->

<multi_turn_rules>
Respond with EXACTLY ONE ```clojure code block per turn.

Use `(println ...)` to explore — the loop continues so you can see output next turn.
When you have the answer, write a program whose last expression IS the answer — no println needed.

Rule: println present → exploration turn (continues). No println → answer turn (last expression returned).

Explore first, answer last. Never write your final answer in the same program as println — you won't see the println output, so your answer would be a guess.

```clojure
;; GOOD — inspect first
(def data (tool/search {:query "revenue"}))
(println "data:" data)

;; GOOD — answer next turn (no println)
{:revenue (apply + (map :total data))}
```

Keep programs very short. Small programs are less likely to fail.
Multiple tool calls per turn are fine — just use println to inspect results.

Keep output concise — truncated at ~512 chars. Avoid decorative formatting.
</multi_turn_rules>

<state>
```clojure
(def results (tool/fetch-data {:id 123}))  ; stored across turns
results                                     ; access in later turns
```

Use `def` to store values you need to reference later. Use `defonce` to initialize, `def` to update:
```clojure
(defonce counter 0)
(def counter (inc counter))
```

`(budget/remaining)` returns turns, depth, and token usage for adaptive strategies.

Avoid Clojure features not in PTC-Lisp. Syntax errors waste a turn. Simpler, shorter programs are safer.
</state>
<!-- PTC_PROMPT_END -->
