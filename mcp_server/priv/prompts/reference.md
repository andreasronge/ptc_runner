# PTC-Lisp reference

<!-- version: 1 -->
<!-- date: 2026-05-22 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- composed-with: composed after each tool card in upstream-enabled and no-tools descriptions -->

<!-- PTC_PROMPT_START -->
PTC-Lisp reference

Clojure-core subset. Includes `let`, `fn`, `defn`, `#(...)`, `loop`/`recur`, collections/strings/sets/regex/math, `parse-*`, destructuring.

Syntax:
- One or more top-level forms. Final value = result.
- No `lambda`, `let*`, `ns`, `require`, `refer`, `import`, macros.
- Inspect shapes with `println`, `pr-str`, `keys`.

Data:
- literals: `nil`, bools, numbers, strings, keywords, vectors, maps, sets.
- JSON maps use string keys.
- No `sorted-map`; use `{}` or `(hash-map)`.
- Context example: `{"orders":[...]}` -> `(count (filter #(= "paid" (get % "status")) data/orders))`.
- Use `data/orders`, not `(data/orders)` or bare `data`.

Helpers:
- Namespaces are fixed; no `require`/`import`.
- `json/parse-string`, `json/parse-lines`, `json/generate-string`; `str/join`, `set/union`; `fail`.
- Java: `Double/parseDouble`, `LocalDate/parse`, `System/currentTimeMillis`, String methods.
- Discover: `apropos`, `dir`, `doc`, `meta`; `ns-publics` local only.
- Prefer core fns; use `pmap`/`pcalls`.

No: lazy/infinite seq producers; atoms/refs; futures/promises; try/catch/throw; transients; metadata; filesystem/network I/O; general Java interop.
<!-- PTC_PROMPT_END -->
