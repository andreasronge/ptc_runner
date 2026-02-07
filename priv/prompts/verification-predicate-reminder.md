# Verification Predicate Reminder

Use PTC-Lisp predicates to validate task outputs.

**Bindings:** `data/result`, `data/input`, `data/depends` (no bare variable names)

**Key forms:**
- `(get map "key")`, `(get-in map ["k1" "k2"])`, `(contains? map "key")`
- `(count coll)`, `(empty? coll)`, `(every? pred coll)`, `(nil? x)`
- `(map? x)`, `(number? x)`, `(string? x)`, `(boolean? x)`, `(coll? x)`
- `(if cond then_expr else_expr)`, `(let [x val] body)`

Additional functions (`filter`, `map`, `reduce`, `sort-by`, `keys`, `vals`, etc.) are also available.

**Return:** `true` for success, or a string diagnosis for failure.
