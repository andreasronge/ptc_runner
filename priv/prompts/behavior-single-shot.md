# PTC-Lisp Single-Shot Behavior

Rules for single-shot execution (one turn, no memory).

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Renamed from lisp-addon-single_shot.md as part of 2-axis prompt refactor -->

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
