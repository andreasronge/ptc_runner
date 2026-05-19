# PTC-Lisp Language Reference

Core language reference for PTC-Lisp. Optional — included by default, can be omitted for capable models.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: ptc-lisp-system-prompt -->
<!-- budget: target<=1100 bytes, hard<=1500 bytes -->
<!-- changes: Renamed from lisp-base.md as part of 2-axis prompt refactor -->
<!-- priority: supported Java interop shape; unavailable forms and namespaces -->

<!-- PTC_PROMPT_START -->

<java_interop>
Only this Java shape works:
- `(java.util.Date.)`, `(java.util.Date. millis-or-iso)`, `(.getTime date)`
- `(java.time.LocalDate/parse "2026-01-15")`
- `(System/currentTimeMillis)`
- String methods: `.contains`, `.indexOf`, `.lastIndexOf`, `.toLowerCase`, `.toUpperCase`, `.startsWith`, `.endsWith`
No other Java interop.
</java_interop>

<restrictions>
- Comments: only own-line `;;`; no inline `;` (breaks `<=`, `->>`).
- Not available: `ns`, `require`, `refer`, `import`, macros, lazy seqs, atoms/refs, futures/promises, try/catch/throw, dotimes, iterate/repeat/cycle, transients, metadata, I/O except `println`, general Java interop.
- Use `reduce`, `map`, `filter`; no `atom`/`swap!`/`reset!`/`@deref`.
- Namespaces are fixed: `tool/`, `data/`, `catalog/`, `budget/`, `clojure.core/`, `clojure.string/`, `clojure.set/`, `clojure.walk/`, `regex/`, `Math/`, `System/`, `Double/`, `LocalDate/`, `Instant/`, `json/`.
</restrictions>

<json>
- `(json/parse-string s)`, `(json/generate-string v)`; parse returns `nil` on failure, keys are strings.
</json>

<!-- PTC_PROMPT_END -->
