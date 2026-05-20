# PTC-Lisp reference

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- composed-with: composed after each tool card in upstream-enabled and no-tools descriptions -->

<!-- PTC_PROMPT_START -->
PTC-Lisp reference

Syntax:
- Clojure forms. `(let [x v ...] body)`, `(fn [x] body)`, `(defn f [x] body)`, `#(...)`.
- One or more top-level forms.
- No `lambda`, `let*`, `ns`, `require`, `refer`, `import`, macros.

Data:
- literals: `nil`, booleans, numbers, strings, keywords, vectors, maps, sets.
- JSON parse maps use string keys.

Helpers:
- collections, strings, sets, walk, regex, math.
- JSON: `(json/parse-string s)` -> data or `nil`; `(json/generate-string v)`.
- Parallel: `(pmap f coll)`, `(pcalls f1 f2 ...)`.

Java:
- `(java.util.Date.)`, `(java.util.Date. millis-or-iso)`, `(.getTime date)`.
- `(java.time.LocalDate/parse "2026-01-15")`.
- `(System/currentTimeMillis)`.
- String methods: `.contains`, `.indexOf`, `.lastIndexOf`, `.toLowerCase`, `.toUpperCase`, `.startsWith`, `.endsWith`.

No:
- lazy seqs, atoms/refs, futures/promises, try/catch/throw, dotimes, iterate/repeat/cycle.
- transients, metadata, filesystem/network I/O, general Java interop.
<!-- PTC_PROMPT_END -->
