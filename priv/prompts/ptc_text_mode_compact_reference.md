# PTC-Lisp Compact Reference (Combined Mode)

Compact reference card appended to combined-mode (`output: :text,
ptc_transport: :tool_call`) system prompts when `ptc_reference: :compact`.

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: combined-text-ptc-system-prompt -->
<!-- budget: target<=1100 bytes, hard<=1500 bytes -->
<!-- priority: native lisp_eval call shape and app-tool namespace split -->
<!-- used-by: PtcRunner.SubAgent.SystemPrompt -->
<!-- profiles: output:text with ptc_transport:tool_call and compact PTC reference -->
<!-- shown-in: provider system message for combined text plus PTC-Lisp tool-call mode -->
<!-- composed-with: text-mode system prompt and dynamically appended app-tool inventory -->

<!-- PTC_PROMPT_START -->
<ptc_lisp_reference>
Call native `lisp_eval` with `program` containing a small PTC-Lisp program. Use for deterministic computation, data transforms, or app-tool orchestration. Result returns as the tool result.

Common forms:
- `(def name value)`, `(let [name value ...] body)`, `(if test then else)`
- `map`, `filter`, `reduce`, `get`, `get-in`
- `(tool/name {:key val})` calls an app tool inside the program
- `(return value)` terminates with success
- `(println ...)` prints debug for the next turn
- `(json/parse-string s)`, `(json/generate-string v)`

Inside PTC-Lisp, app tools are `(tool/name {...})`; only `lisp_eval` is native-callable in this mode.

Cache reuse: if a native app-tool result says `full_result_cached: true`, the same `(tool/name {...})` call with canonical same args inside `lisp_eval` reuses the cached full result; upstream tool does not run again.

```
(def rows (tool/search_logs {:query "error"}))
(def errors (filter (fn [r] (= (get r "level") "error")) rows))
(return (count errors))
```
</ptc_lisp_reference>
<!-- PTC_PROMPT_END -->
