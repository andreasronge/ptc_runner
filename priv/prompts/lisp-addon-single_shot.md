# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 2 -->
<!-- date: 2026-01-08 -->
<!-- changes: Added thinking example, moved rules from base -->

<!-- PTC_PROMPT_START -->

### Single-Shot Execution

Respond with EXACTLY ONE ```clojure code block. The expression result IS your answer.

For complex tasks, think through the problem first:

thinking:
The user wants electronics count. I'll filter products by category and count.

```clojure
(->> ctx/products
     (filter (where :category = "electronics"))
     (count))
```

<!-- PTC_PROMPT_END -->
