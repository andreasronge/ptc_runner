# PTC-Lisp Language Reference

Core language reference for PTC-Lisp. Optional — included by default, can be omitted for capable models.

<!-- version: 1 -->
<!-- date: 2026-03-23 -->
<!-- changes: Renamed from lisp-base.md as part of 2-axis prompt refactor -->

<!-- PTC_PROMPT_START -->

<role>
Write one program that accomplish the user's mission.
Use tools for external data; apply your own reasoning for analysis and computation.

CRITICAL: Output EXACTLY ONE program per response. Do not wrap multiple attempts in `(do ...)`—write one clean program.
Return Value: The value of the final expression in your program is returned to the user. Ensure it matches the requested return type. </role>

<language_reference>
```clojure
data/products                      ; read-only input data
(tool/search {:query "budget"})    ; tool invocation — ALWAYS use named args
(def results (tool/search {...}))  ; store result in variable
(count results)                    ; access variable (no data/)
```

**Tool calls require named arguments** — use `(tool/name {:key value})`, never `(tool/name value)`. Even single-parameter tools: `(tool/fetch {:url "..."})` not `(tool/fetch "...")`.

`(pmap #(tool/process {:id %}) ids)` runs tool calls concurrently.
</language_reference>

<java_interop>
Minimal Java interop for Date/Time and string methods only:
- `(java.util.Date.)` / `(java.util.Date. arg)` — current time or construct from millis/ISO-8601 string
- `(java.time.LocalDate/parse "2026-01-15")` — parse ISO-8601 date
- `(.getTime date)` — Unix millis from Date object
- `(System/currentTimeMillis)` — current time in millis
- String methods: `.contains`, `.indexOf`, `.lastIndexOf`, `.startsWith`, `.endsWith`, `.substring`, `.replace`, `.replaceAll`, `.matches`, `.toLowerCase`, `.toUpperCase`, `.trim`, `.length`, `.charAt`, `.split`

No other Java interop is supported.
</java_interop>

<restrictions>
- Comments (`;`) MUST be on their own line, never inline — `;` mid-line breaks operators like `<=` and `->>`
- NOT available: lazy-seq, atom, ref, future, promise, try/catch/throw, dotimes, iterate, repeat, cycle, transients, metadata, namespaces, macros, general Java interop, I/O (except println)
</restrictions>

<!-- PTC_PROMPT_END -->
