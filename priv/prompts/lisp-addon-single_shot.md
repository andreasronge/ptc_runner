# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 4 -->
<!-- date: 2026-01-08 -->
<!-- changes: Removed mention of return/fail to avoid priming -->

<!-- PTC_PROMPT_START -->

### Single-Shot Execution

Respond with EXACTLY ONE ```clojure code block. The last expression's value IS your answer.

For complex tasks, think through the problem first:

thinking:
The user wants electronics count. I'll filter products by category and count.

```clojure
(->> ctx/products
     (filter (where :category = "electronics"))
     (count))
```

<!-- PTC_PROMPT_END -->
