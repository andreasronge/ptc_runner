# PTC-Lisp authoring (aggregator mode)

<!-- version: 2 -->
<!-- date: 2026-05-19 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tool-description -->
<!-- budget: target<=800 bytes, hard<=1000 bytes -->
<!-- priority: tagged mcp-call result, :ok, :value, catalog fallback -->

<!-- PTC_PROMPT_START -->
Run one stateless PTC-Lisp program for compute plus upstream MCP calls.

Aggregator contract:
- Call upstreams: `(tool/mcp-call {:server s :tool t :args {...}})`.
- It returns tagged data; inspect `:ok` before using `:value`.
- Success: `{:ok true :value payload :value_kind :json|:text|:none}`.
- Failure: `{:ok false :reason kw :message text}`; handle or `(fail ...)`.
- `:value` is already unwrapped domain data, not an MCP envelope.
- `:raw` may be present when server config enables raw envelopes.
- Use catalog/search-tools, catalog/list-tools, catalog/describe-tool as needed.
- Return compact maps, vectors, or strings.
- Wrap `tool/mcp-call` in `fn` or `#(...)` before higher-order use.
- Use `output_schema` for typed final results.
- No mutable state, filesystem, general network, or general Java interop.
<!-- PTC_PROMPT_END -->
