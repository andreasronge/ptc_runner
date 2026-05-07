# PTC-Lisp authoring

PTC-Lisp is a deterministic, sandboxed subset of Clojure with a small Java-interop surface (Date/Time + String methods). A program is one or more top-level expressions; the last expression's value is the result.

## Non-obvious bits

- **`context` keys are bound under the `data/` namespace.** Pass `{"records": [...]}`, reference as `data/records` inside the program. There is no `context` binding.
- **`signature`** is a return-type schema, e.g. `() -> {count :int}` or `() -> [{name :string, score :int}]`. Supplying it makes the response carry a structured `validated` JSON value — the only path for a caller to receive programmatic data. Without it, the response only contains an LLM-readable preview.
- **`(fail v)`** terminates with an error value when you want to surface a domain failure to the caller.

## Restrictions

- No mutable state: `atom`, `swap!`, `reset!`, `@deref` are absent — use `reduce` / `map` / `filter`.
- No I/O except `println`. No filesystem, no network. No general Java interop.
- No state across calls — each invocation is independent.
- 1 s wall-clock, 10 MB memory, 64 KB program, 4 MB context.

If you reach for something that isn't there, the response will say so clearly — adjust and retry.

## Example

```
;; context:   {"orders": [{"total": 12}, {"total": 7}, {"total": 33}]}
;; signature: "() -> {count :int, sum :int}"
(let [big (filter #(> (get % "total") 10) data/orders)]
  {:count (count big)
   :sum   (reduce + (map #(get % "total") big))})
```

Full reference: https://hexdocs.pm/ptc_runner.
