# PTC-Lisp Minimal Reference

<!-- version: 1 -->
<!-- date: 2025-01-02 -->
<!-- changes: Initial minimal prompt for token-efficient queries -->

Minimal prompt for token-efficient single-shot queries.

<!-- PTC_PROMPT_START -->
# PTC-Lisp Quick Reference

Write a single PTC-Lisp expression to query data.

## Data Access
```clojure
ctx/products    ; access dataset
```

## Core Functions
```clojure
(count list)                    ; count items
(filter pred list)              ; filter items
(where :field = value)          ; create filter predicate
(where :field)                  ; truthy check
(all-of pred1 pred2)            ; combine predicates (AND)
(any-of pred1 pred2)            ; combine predicates (OR)
(sum-by :field list)            ; sum a field
(avg-by :field list)            ; average a field
(min-by :field list)            ; find minimum
(max-by :field list)            ; find maximum
(group-by :field list)          ; group into {key => [items]}
(sort-by :field list)           ; sort ascending
(sort-by :field > list)         ; sort descending
(first list)                    ; get first item
(take n list)                   ; get first n items
(get map :key)                  ; get field from map
(pluck :field list)             ; extract field from all items
(empty? list)                   ; check if list is empty
(map fn list)                   ; transform each item
(if cond then else)             ; conditional (else required)
(let [x expr] body)             ; local binding
```

## Threading
```clojure
(->> list (filter pred) (count))  ; thread-last for collections
(-> map (assoc :k v))             ; thread-first for maps
```

Respond with ONLY a ```clojure code block, no explanation.
<!-- PTC_PROMPT_END -->
