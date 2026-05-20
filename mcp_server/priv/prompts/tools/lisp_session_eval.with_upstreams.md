# lisp_session_eval with upstreams

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_eval -->
<!-- mcp-profiles: mcp_session_eval_with_upstreams_description -->
<!-- composed-with: reference.md after this card; optional dynamic catalog after reference -->

<!-- PTC_PROMPT_START -->
Evaluates PTC-Lisp against committed session memory
- Requires `session_id` and `program`
- `def`/`defn` persist for later evals in the same session
- Use `let` for temporary values
- Optional `output_schema` validates the program result; on mismatch, session state is not committed.

Upstreams:
`(tool/mcp-call {:server s :tool t :args {...}})`
=> `{:ok true :value payload :value_kind :json|:text|:none}` or
   `{:ok false :reason kw :message text}`.
Check `:ok`; `:value` is unwrapped domain data.
Wrap `tool/mcp-call` in `fn`/`#(...)` for higher-order use.

Unknown result shape:
- Inspect with `println`: `(keys (:value r))` or `(pr-str (:value r))`.
- Check `:ok` before using `:value`.
Example:
`(let [r (tool/mcp-call {:server s :tool t :args a})]
   (if (:ok r)
      (let [v (:value r)]
      (if (string? v) v (json/generate-string v)))
      (fail (:message r))))`
<!-- PTC_PROMPT_END -->
