# PTC-Lisp reference

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- composed-with: composed after each tool card in upstream-enabled and no-tools descriptions -->

<!-- PTC_PROMPT_START -->
PTC-Lisp reference

Clojure-core subset: assume common pure core fns exist unless listed under No.
Core includes `loop`/`recur`, `parse-double`/`parse-long`.

Syntax:
- Forms: `(let [x v ...] body)`, `(fn [x] body)`, `(defn f [x] body)`, `#(...)`.
- One or more top-level forms. Final value = result.
- No `lambda`, `let*`, `ns`, `require`, `import`, macros.

Data:
- literals: `nil`, bools, numbers, strings, keywords, vectors, maps, sets.
- JSON maps use string keys. `context`: `{"records":[...]}` -> `data/records`.
- Inspect shapes with `println`, `pr-str`, `keys`.

Helpers:
- collections, strings, sets, walk, regex, math.
- JSON: `(json/parse-string s)` -> data or `nil`; `(json/generate-string v)`.
- Parallel: `(pmap f coll)`, `(pcalls f1 f2 ...)`.
- Fail: `(fail v)`.

Java:
- Limited: dates/time, `System/currentTimeMillis`, common String methods.
- Prefer core fns over Java interop.

No:
- lazy/infinite seq producers: use eager fns or `loop`/`recur`.
- atoms/refs, futures/promises, try/catch/throw.
- transients, metadata, filesystem/network I/O, general Java interop.
<!-- PTC_PROMPT_END -->
