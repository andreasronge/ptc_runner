# catalog discovery

<!-- version: 1 -->
<!-- date: 2026-05-21 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-catalog-guidance -->
<!-- budget: target<=500 bytes, hard<=700 bytes -->

<!-- PTC_PROMPT_START -->
Discover tools:
- `(catalog/search-tools "query" {:limit 8})`
- `(catalog/describe-tool "server" "tool")`
- `(catalog/list-tools "server" {:limit 20})`
Call: `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.
<!-- PTC_PROMPT_END -->
