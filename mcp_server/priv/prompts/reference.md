# PTC-Lisp reference

<!-- version: 1 -->
<!-- date: 2026-05-22 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- composed-with: composed after each tool card in upstream-enabled and no-tools descriptions -->

<!-- PTC_PROMPT_START -->
PTC-Lisp reference

Core includes `let`, `fn`, `defn`, `#(...)`, `loop`/`recur`, collections/strings/sets/regex/math, `parse-*`, destructing.

Syntax:
- One or more top-level forms. Final value = result.
- Use `(fn [x] body)` or `#(...)`; No `lambda`, `let*`.
- Inspect shapes with `println`, `pr-str`, `keys`.

Data:
- literals: `nil`, bools, numbers, strings, keywords, vectors/maps/sets.
- JSON maps use string keys.
- No `sorted-map`; use `{}` or `(hash-map)`.
- Context example: `{"orders":[...]}` -> `(count (filter #(= "paid" (get % "status")) data/orders))`.
- Use `data/orders`, not `(data/orders)`, `orders`, or bare `data`.

Helpers:
- Namespaces are fixed; no `require`/`import`.
- `json/parse-string`, `json/generate-string`; `str/join`, `set/union`.
- Java-shaped: `Double/parseDouble`, `LocalDate/parse`.
- Discover: `apropos`, `dir`, `doc`, `meta`; `ns-publics` is local only.
- Prefer core fns; use `pmap`/`pcalls` when useful.

No: `let*`, `ns`, `require`, `refer`, `import`, macros; lazy/infinite seqs; atoms/refs; futures/promises; try/catch/throw; transients; metadata; filesystem/network
<!-- PTC_PROMPT_END -->
