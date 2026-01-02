# PTC-Lisp Single Shot Reference

<!-- version: 1 -->
<!-- date: 2025-01-02 -->
<!-- changes: Initial single-shot prompt for one-turn queries -->

Optimized for one-turn queries with concrete examples.

<!-- PTC_PROMPT_START -->
# PTC-Lisp (Single Query Mode)

Write ONE PTC-Lisp expression to answer the question directly.

## Data
Access datasets via `ctx/name` (e.g., `ctx/products`, `ctx/orders`).

## Common Patterns
```clojure
; Count with filter
(->> ctx/items (filter (where :status = "active")) (count))

; Sum a field
(sum-by :amount ctx/orders)

; Find specific item
(first (filter (where :id = 123) ctx/items))

; Top N by field
(->> ctx/items (sort-by :score >) (take 5))

; Group and count
(-> (group-by :category ctx/items) (update-vals count))

; Simple arithmetic - just return the expression
(+ 2 2)
```

## Key Functions
`count`, `filter`, `where`, `sum-by`, `avg-by`, `min-by`, `max-by`,
`first`, `take`, `sort-by`, `group-by`, `pluck`, `get`

## Predicates
- `(where :field = value)` - equality
- `(where :field > n)` - comparison (>, <, >=, <=)
- `(where :field)` - truthy check
- `(all-of p1 p2)` - AND predicates
- `(any-of p1 p2)` - OR predicates

Just write the expression - it returns automatically.

Respond with ONLY a ```clojure code block.
<!-- PTC_PROMPT_END -->
