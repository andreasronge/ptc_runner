# lisp_eval with upstreams

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_eval -->
<!-- mcp-profiles: mcp_aggregator_description -->
<!-- composed-with: reference.md after this card; optional dynamic catalog after reference -->

<!-- PTC_PROMPT_START -->
One stateless PTC-Lisp program
Final value = result
No persistence across calls

Upstreams:
`(tool/mcp-call {:server s :tool t :args {...}})`
=> `{:ok true :value payload :value_kind :json|:text|:none}` or
   `{:ok false :reason kw :message text}`.
Check `:ok`; `:value` is unwrapped domain data, not MCP envelope. `:raw` optional.
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
