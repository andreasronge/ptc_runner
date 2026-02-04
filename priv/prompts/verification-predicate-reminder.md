# Verification Predicate Reminder

Use PTC-Lisp predicates to validate task outputs.

**Bindings:** `data/result`, `data/input`, `data/depends`

**Key forms:**
- `(get map "key")`, `(get-in map ["k1" "k2"])`
- `(count coll)`, `(empty? coll)`, `(nil? x)`
- `(if cond then_expr else_expr)`, `(let [x val] body)`

**Return:** `true` for success, or a string diagnosis for failure.
