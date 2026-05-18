# PTC-Lisp Language Reference

Core language reference for PTC-Lisp. Optional — included by default, can be omitted for capable models.

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Renamed from lisp-base.md as part of 2-axis prompt refactor -->

<!-- PTC_PROMPT_START -->

<java_interop>
Minimal Java interop for Date/Time and string methods only:
- `(java.util.Date.)` / `(java.util.Date. arg)` — current time or construct from millis/ISO-8601 string
- `(java.time.LocalDate/parse "2026-01-15")` — parse ISO-8601 date
- `(.getTime date)` — Unix millis from Date object
- `(System/currentTimeMillis)` — current time in millis
- String methods: `.contains`, `.indexOf`, `.lastIndexOf`, `.toLowerCase`, `.toUpperCase`, `.startsWith`, `.endsWith`

No other Java interop is supported.
</java_interop>

<restrictions>
- Comments (`;`) MUST be on their own line, never inline — `;` mid-line breaks operators like `<=` and `->>`
- NOT available: lazy-seq, atom, ref, future, promise, try/catch/throw, dotimes, iterate, repeat, cycle, transients, metadata, **namespace declaration (`ns` / `require` / `refer` / `import`)**, macros, general Java interop, I/O (except println). A fixed allowlist of namespaces *is* available: `tool/`, `data/`, `catalog/`, `budget/`, `clojure.core/`, `clojure.string/`, `clojure.set/`, `clojure.walk/`, `regex/`, `Math/`, `System/`, `Double/`, `LocalDate/`, `Instant/`, `json/`, `mcp/`.
- No mutable state: `atom`, `swap!`, `reset!`, `@deref` are NOT supported. Use `reduce` or `map`/`filter` instead of `doseq` + `swap!` to accumulate results.
</restrictions>

<json>
- `(json/parse-string s)`, `(json/generate-string v)` — Cheshire-style; `nil` on failure (no raise; map keys parse as strings).
- `(mcp/text r)`, `(mcp/json r)` — extract MCP `content[0].text` / parse it. `mcp/json` prefers `r["structuredContent"]`.
</json>

<!-- PTC_PROMPT_END -->
