# lisp_eval with upstreams

Composed with: `../reference.md` after this card; optional dynamic catalog after reference.

<!-- PTC_PROMPT_START -->
One stateless PTC-Lisp program. Final value = result. Use `println` briefly to inspect shapes.
Context: `{"items":[...]}` -> `data/items`; no `context` binding.
Example: `{"records":[{"name":"a"}]}` -> `(get (first data/records) "name")`; no `context`.
Fail: `(fail v)`. No persistence across calls.

Upstreams:
`(tool/mcp-call {:server s :tool t :args {...}})`
=> `{:ok true :value payload :value_kind :json|:text|:none}` or
   `{:ok false :reason kw :message text}`.
Check `:ok`; `:value` is unwrapped domain data, not MCP envelope. `:raw` optional.
Wrap `tool/mcp-call` in `fn`/`#(...)` for higher-order use.

Unknown result shape:
Catalog lookups return tool description strings.
Inspect `(keys (:value r))` or `(pr-str (:value r))`.
`(let [r (tool/mcp-call {:server s :tool t :args a}) v (:value r)]
   (if (:ok r) (if (string? v) v (json/generate-string v)) (fail (:message r))))`
<!-- PTC_PROMPT_END -->
