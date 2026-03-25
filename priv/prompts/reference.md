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
- String methods: `.contains`, `.indexOf`, `.lastIndexOf`, `.toLowerCase`, `.toUpperCase`

No other Java interop is supported.
</java_interop>

<restrictions>
- Comments (`;`) MUST be on their own line, never inline — `;` mid-line breaks operators like `<=` and `->>`
- NOT available: lazy-seq, atom, ref, future, promise, try/catch/throw, dotimes, iterate, repeat, cycle, transients, metadata, namespaces, macros, general Java interop, I/O (except println)
- No mutable state: `atom`, `swap!`, `reset!`, `@deref` are NOT supported. Use `reduce` or `map`/`filter` instead of `doseq` + `swap!` to accumulate results.
</restrictions>

<!-- PTC_PROMPT_END -->
