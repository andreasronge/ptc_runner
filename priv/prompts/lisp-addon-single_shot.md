# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 1 -->
<!-- date: 2026-01-08 -->
<!-- changes: Initial version -->

<!-- PTC_PROMPT_START -->

### Single-Shot Execution

The expression result IS your answer.

```clojure
(->> ctx/products
     (filter (where :category = "electronics"))
     (count))
```

<!-- PTC_PROMPT_END -->
