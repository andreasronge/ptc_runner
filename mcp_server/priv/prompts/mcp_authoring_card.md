# PTC-Lisp authoring

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tool-description -->
<!-- budget: target<=900 bytes, hard<=1200 bytes -->
<!-- priority: context data namespace, output schema, sandbox limits -->

<!-- PTC_PROMPT_START -->
PTC-Lisp authoring:
- Deterministic sandboxed Clojure subset. Program = one or more top-level forms; final value is the result.
- `context` keys are under `data/`: pass `{"records":[...]}`, read `data/records`. No `context` binding.
- `output_schema` validates the return value with JSON Schema and returns structured `validated` JSON.
- `(fail v)` terminates with an error value for domain failures.
- JSON: `(json/parse-string s)`, `(json/generate-string v)`; parse failure returns `nil`.
- No mutable state, filesystem, network, or general Java interop. I/O is `println` only.
- No cross-call memory. Limits: 1s wall clock, 10MB memory, 64KB program, 4MB context.

Example:
```clojure
(let [big (filter #(> (get % "total") 10) data/orders)]
  {:count (count big)
   :sum (reduce + (map #(get % "total") big))})
```
<!-- PTC_PROMPT_END -->
