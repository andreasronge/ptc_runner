# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 6 -->
<!-- date: 2026-02-11 -->
<!-- changes: Removed thinking example to prevent multi-block parsing failures -->

<!-- PTC_PROMPT_START -->

### Single-Shot Execution

Respond with EXACTLY ONE ```clojure code block. The last expression's value IS your answer.

```clojure
(->> data/products
     (filter #(= (:category %) "electronics"))
     (count))
```

<!-- PTC_PROMPT_END -->
