# PTC-Lisp Multi-Turn Reference

Emphasizes memory persistence for conversational sessions.

<!-- PTC_PROMPT_START -->
# PTC-Lisp Quick Reference

Write a single PTC-Lisp expression to query data.

## Data Access
```clojure
ctx/products    ; access dataset
memory/key      ; access stored values from previous turns
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
(map fn list)                   ; transform each item
(let [x expr] body)             ; local binding
(return value)                  ; return final result
```

## Threading
```clojure
(->> list (filter pred) (count))  ; thread-last for collections
(-> map (assoc :k v))             ; thread-first for maps
```

## Memory (Multi-Turn)

Store values by returning a map (keys merge into memory):
```clojure
{:my-data (->> ctx/orders (filter (where :status = "done")))}
```

Read stored values in later turns:
```clojure
(count memory/my-data)
```

Return a specific value (rest merges to memory):
```clojure
{:cached data, :result (count data)}
```

Respond with ONLY a ```clojure code block, no explanation.
<!-- PTC_PROMPT_END -->
