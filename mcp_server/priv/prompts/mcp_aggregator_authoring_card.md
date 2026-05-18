# PTC-Lisp authoring (aggregator mode)

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tool-description -->
<!-- budget: target<=800 bytes, hard<=1000 bytes -->
<!-- priority: mcp-call shape, nil failure convention, catalog fallback -->

<!-- PTC_PROMPT_START -->
Aggregator authoring:
- `tool/mcp-call` takes `{:server s :tool t :args {...}}`; use `{}` for no args.
- It returns the upstream value or `nil`, not `{:ok ...}`.
- Wrap `tool/mcp-call` in `fn` or `#(...)` before higher-order use.
- World faults return `nil`; programmer faults raise.
- JSON `null` returns `:json-null`.
- Unwrap with `(mcp/text r)` or `(mcp/json r)`.
- Use `output_schema` for typed final results.
- Use catalog/search-tools, catalog/list-tools, or catalog/describe-tool when needed.
- No mutable state, filesystem, general network, or general Java interop.
<!-- PTC_PROMPT_END -->
