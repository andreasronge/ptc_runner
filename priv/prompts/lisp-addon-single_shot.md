# PTC-Lisp Single-Shot Mode

Rules for single-shot execution (one turn, no memory).

<!-- version: 7 -->
<!-- date: 2026-02-18 -->
<!-- changes: Wrap in XML tag -->

<!-- PTC_PROMPT_START -->

<single_shot>
Respond with EXACTLY ONE ```clojure code block. The last expression's value IS your answer.

```clojure
(->> data/products
     (filter #(= (:category %) "electronics"))
     (count))
```
</single_shot>

<!-- PTC_PROMPT_END -->
