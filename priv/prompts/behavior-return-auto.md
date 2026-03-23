# PTC-Lisp Auto-Return Mode

Return convention for multi-turn: println presence controls flow automatically.

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Extracted from lisp-addon-auto_return.md as part of 2-axis prompt refactor -->

<!-- PTC_PROMPT_START -->

<return_rules>
Use `(println ...)` to explore — the loop continues so you can see output next turn.
When you have the answer, write a program whose last expression IS the answer — no println needed.

Rule: println present → exploration turn (continues). No println → answer turn (last expression returned).

Explore first, verify, answer last. When calling tools, always use `println` to inspect the results before writing your final answer. Only write a program without `println` when you have seen concrete evidence that your answer is correct. A guess is worse than another turn of exploration.

```clojure
;; BAD — you call the tool but never see the result
(def data (tool/search {:query "revenue"}))
{:revenue 42000}  ; this is a guess — you never saw what data contains!

;; GOOD — inspect first
(def data (tool/search {:query "revenue"}))
(println "data:" data)

;; GOOD — answer next turn, after seeing data (no println)
{:revenue (apply + (map :total data))}
```

Multiple tool calls per turn are fine — just use println to inspect results.
</return_rules>
<!-- PTC_PROMPT_END -->
