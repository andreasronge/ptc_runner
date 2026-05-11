# PTC-Lisp authoring (aggregator mode)

PTC-Lisp is a deterministic, sandboxed subset of Clojure with a small Java-interop surface (Date/Time + String methods). A program is one or more top-level expressions; the last expression's value is the result.

In aggregator mode, programs may invoke configured upstream MCP servers via `(tool/mcp-call ...)` and compose their results deterministically inside the sandbox. Only the final value crosses back to the calling client.

## Calling upstream tools

```
(tool/mcp-call {:server "<configured-name>"
                :tool   "<upstream-tool>"
                :args   {<args map>}})
```

`:server`, `:tool`, and `:args` are required. `:args` may be omitted only when the upstream tool takes no arguments — the safer default is `{}`.

`tool/mcp-call` is not a first-class function value; for higher-order use wrap in `#(tool/mcp-call ...)` or `(fn [x] (tool/mcp-call ...))`.

## Failure convention

`(tool/mcp-call ...)` returns `nil` on any of these world-fault failures (the call is recorded under `upstream_calls` in the response envelope):

- `upstream_unavailable` — the upstream could not be started or its handshake failed.
- `upstream_error` — the upstream returned a JSON-RPC error.
- `timeout` — the call exceeded the configured per-call timeout.
- `response_too_large` — the upstream's response exceeded the configured byte cap.
- `cap_exhausted` — the program made too many `(tool/mcp-call ...)` calls.

Use `(when result ...)`, `(remove nil? results)`, and similar guards to handle world faults gracefully.

Programmer-fault failures (unknown server, unknown tool on a healthy upstream, malformed args) raise a runtime error and terminate the program — fix the call and retry.

## `:json-null` sentinel

If an upstream legitimately returns JSON `null` as a successful payload (top-level only — nested `null` inside maps or arrays is unchanged), `(tool/mcp-call ...)` returns the keyword `:json-null` rather than `nil`. This preserves the invariant `nil` means "this call did not succeed."

Programs that don't care about the distinction can treat `:json-null` as truthy and continue. Programs that care can compare `(= result :json-null)`.

## JSON helpers

- `(json/parse-string s)`, `(json/generate-string v)` — Cheshire-style; return `nil` on failure (no raise; map keys parse as strings).
- `(mcp/text r)` — `r["content"][0]["text"]` or `nil`.
- `(mcp/json r)` — `r["structuredContent"]` if set, else `(json/parse-string (mcp/text r))`. Use for typed JSON results.

## Dialect quick reference

- Use Clojure-style forms, not Common Lisp or JavaScript.
- Use `(let [name value ...] body)`, never `let*` or parenthesized let bindings.
- Use `(fn [x] body)`, never `lambda`.
- Use the final expression as the result; avoid `print`.
- String helpers are unqualified: `(split-lines s)`, `(split s delimiter)`, `(trim s)`, `(count s)`, `(subs s start)`, `(join "\n" coll)`.
- Use `subs`, never `substring`.
- JSON helpers are `(json/parse-string s)` and `(json/generate-string v)`, never `json/stringify`.

## Authoring rules

- Unwrap upstream results before filtering: use `(mcp/json r)` for JSON payloads and `(mcp/text r)` for text.
- Return compact maps/vectors, not full upstream envelopes. Use `map`, `filter`, `take`, and selected fields.
- Keep returned strings short; long previews truncate. Prefer fewer items/fields over `println`.
- Do not pass `signature` in exploratory aggregator calls. Omit it unless the user explicitly needs validated output and you know the exact PTC signature syntax.

## Response envelope

Each call to `ptc_lisp_execute` returns a structured payload that may include an `upstream_calls` array — one entry per `(tool/mcp-call ...)` invocation, in completion order, recording `server`, `tool`, `status`, `duration_ms`, and (on error) `reason` and `error`. The field is omitted when no upstream calls were made.

## Restrictions inside the program

- No mutable state: `atom`, `swap!`, `reset!`, `@deref` are absent — use `reduce` / `map` / `filter`.
- No I/O except `println` and `(tool/mcp-call ...)`. No filesystem, no general network, no general Java interop.
- No state across calls — each invocation of `ptc_lisp_execute` is independent.
