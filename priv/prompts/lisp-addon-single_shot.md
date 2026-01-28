# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 5 -->
<!-- date: 2026-01-28 -->
<!-- changes: Removed where from example, use standard Clojure pattern -->

<!-- PTC_PROMPT_START -->

### Single-Shot Execution

Respond with EXACTLY ONE ```clojure code block. The last expression's value IS your answer.

For complex tasks, think through the problem first:

thinking:
The user wants electronics count. I'll filter products by category and count.

```clojure
(->> data/products
     (filter #(= (:category %) "electronics"))
     (count))
```

<!-- PTC_PROMPT_END -->
