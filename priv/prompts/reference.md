# PTC-Lisp Language Reference

Core language reference for PTC-Lisp. Optional — included by default, can be omitted for capable models.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: ptc-lisp-system-prompt -->
<!-- budget: target<=1100 bytes, hard<=1500 bytes -->
<!-- changes: Renamed from lisp-base.md as part of 2-axis prompt refactor -->
<!-- priority: supported Java interop shape; parallel forms; unavailable forms and namespaces -->
<!-- used-by: PtcRunner.Lisp.LanguageSpec via PtcRunner.Lisp.PromptRegistry -->
<!-- profiles: single_shot, explicit_return, explicit_journal unless reference:none is selected -->
<!-- shown-in: SubAgent PTC-Lisp system prompt -->
<!-- composed-with: one behavior card after this card; optional capability card after behavior cards -->

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
