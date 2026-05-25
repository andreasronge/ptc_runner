# PTC-Lisp Compact Reference (Combined Mode)

Compact reference card appended to combined-mode (`output: :text,
ptc_transport: :tool_call`) system prompts when `ptc_reference: :compact`.

<!-- version: 1 -->
<!-- date: 2026-05-25 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: combined-text-ptc-system-prompt -->
<!-- budget: target<=1800 bytes, hard<=2200 bytes -->
<!-- priority: native lisp_eval call shape, supported syntax, and app-tool namespace split -->
<!-- used-by: PtcRunner.SubAgent.SystemPrompt -->
<!-- profiles: output:text with ptc_transport:tool_call and compact PTC reference -->
<!-- shown-in: provider system message for combined text plus PTC-Lisp tool-call mode -->
<!-- composed-with: text-mode system prompt and dynamically appended app-tool inventory -->

<!-- PTC_PROMPT_START -->
<ptc_lisp_reference>
Call native `lisp_eval` with `program` containing a small PTC-Lisp program. Use it for deterministic computation, data transforms, or app-tool orchestration.

PTC-Lisp syntax:
- One or more top-level forms. Final value = result; `(return value)` also terminates with success.
- Use `(let [name value ...] body)`, `(fn [x] body)`, or `#(...)`. No `let*`, `lambda`, `equal?`, or `length`.
- Core includes `def`, `defn`, `if`, `loop`/`recur`, collections, strings, sets, regex, math, parse functions.
- Use `count`, `filter`, `map`, `reduce`, `get`, `get-in`; use `println`, `pr-str`, `keys` to inspect shapes.
- Data literals: `nil`, bools, numbers, strings, keywords, vectors/maps/sets. JSON maps use string keys.
- Context example: `{"orders":[...]}` -> `(count (filter #(= "paid" (get % "status")) data/orders))`. Use `data/orders`, not `(data/orders)`, `orders`, or bare `data`.
- Namespaces are fixed; no `ns`, `require`, `refer`, or `import`.
- Helpers include `json/parse-string`, `json/generate-string`, `str/join`, `set/union`, `Double/parseDouble`, `LocalDate/parse`.
- No macros, lazy/infinite seqs, atoms/refs, futures/promises, try/catch/throw, transients, metadata, filesystem, or network.

Inside PTC-Lisp, app tools are `(tool/name {...})`; only `lisp_eval` is native-callable in this mode.

Cache reuse: if a native app-tool result says `full_result_cached: true`, the same `(tool/name {...})` call with canonical same args inside `lisp_eval` reuses the cached full result; upstream tool does not run again.

```
(def rows (tool/search_logs {:query "error"}))
(def errors (filter (fn [r] (= (get r "level") "error")) rows))
(return (count errors))
```
</ptc_lisp_reference>
<!-- PTC_PROMPT_END -->
