# PTC-Lisp Compact Reference (Combined Mode)

Compact reference card appended to combined-mode (`output: :text,
ptc_transport: :tool_call`) system prompts when `ptc_reference: :compact`.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: combined-text-ptc-system-prompt -->
<!-- budget: target<=1100 bytes, hard<=1500 bytes -->
<!-- priority: native ptc_lisp_execute call shape and app-tool namespace split -->

<!-- PTC_PROMPT_START -->
<ptc_lisp_reference>
Call native `ptc_lisp_execute` with `program` containing a small PTC-Lisp program. Use for deterministic computation, data transforms, or app-tool orchestration. Result returns as the tool result.

Common forms:
- `(def name value)`, `(let [name value ...] body)`, `(if test then else)`
- `map`, `filter`, `reduce`, `get`, `get-in`
- `(tool/name {:key val})` calls an app tool inside the program
- `(return value)` terminates with success
- `(println ...)` prints debug for the next turn
- `(json/parse-string s)`, `(json/generate-string v)`

Inside PTC-Lisp, app tools are `(tool/name {...})`; only `ptc_lisp_execute` is native-callable in this mode.

Cache reuse: if a native app-tool result says `full_result_cached: true`, the same `(tool/name {...})` call with canonical same args inside `ptc_lisp_execute` reuses the cached full result; upstream tool does not run again.

```
(def rows (tool/search_logs {:query "error"}))
(def errors (filter (fn [r] (= (get r "level") "error")) rows))
(return (count errors))
```
</ptc_lisp_reference>
<!-- PTC_PROMPT_END -->
