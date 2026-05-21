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
Tools below. For details:
- `(catalog/describe-tool "server" "tool")`
- `(catalog/search-tools "query" {:limit 8})`
- `(catalog/list-tools "server" {:limit 20})`
Call: `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.

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
- Check `:ok`; inspect with `println`: `(keys (:value r))` or `(pr-str (:value r))`.
- Use `(fail (:message r))` for unhandled upstream faults.
<!-- PTC_PROMPT_END -->
