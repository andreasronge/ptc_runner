# PTC-Lisp Compact Reference (Combined Mode)

Compact reference card appended to combined-mode (`output: :text,
ptc_transport: :tool_call`) system prompts when `ptc_reference: :compact`.

<!-- version: 1 -->
<!-- date: 2026-05-06 -->

<!-- PTC_PROMPT_START -->
<ptc_lisp_reference>
You can call the native `ptc_lisp_execute` tool with a `program` argument
containing a small PTC-Lisp program. Use it for deterministic computation,
data transformation, or app-tool orchestration. The program runs in a
sandboxed BEAM process and its result is returned to you as a tool result.

Core forms (everything you need for combined mode):
- `(def name value)` — bind a name in this program
- `(tool/name {:key val})` — call an app tool from inside the program
- `(return value)` — produce the program's final value (terminates execution; produces a successful tool result for the LLM)
- `(println ...)` — debug output between turns

App tools must be invoked from inside `ptc_lisp_execute` as `(tool/name {...})` —
never as native function calls. Only `ptc_lisp_execute` itself is callable
natively in this mode.

Cache reuse (`full_result_cached: true`). When you call an app tool natively
and the tool is configured with `expose: :both, cache: true`, the runtime
returns a metadata preview to you and retains the full result in the
program's tool cache for the rest of this run. A subsequent
`(tool/name {...})` call from inside `ptc_lisp_execute` with the same
canonical arguments reuses the cached value — the tool function does NOT
run again — so you can escalate to a program without re-paying the
upstream cost. Example:

```
;; Turn 1 (native): call search_logs(query: "error") → get a metadata
;; preview, e.g. {full_result_cached: true, count: 1842, ...}.
;;
;; Turn 2 (program): reuse the cached rows by calling the same tool with
;; the same args from inside ptc_lisp_execute.
(def rows (tool/search_logs {:query "error"}))
(def errors (filter (fn [r] (= (get r "level") "error")) rows))
(return (count errors))
```
</ptc_lisp_reference>
<!-- PTC_PROMPT_END -->
