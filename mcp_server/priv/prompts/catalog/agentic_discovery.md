# agentic catalog discovery

<!-- version: 1 -->
<!-- date: 2026-05-21 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-agentic-catalog-guidance -->
<!-- budget: target<=650 bytes, hard<=850 bytes -->

<!-- PTC_PROMPT_START -->
Upstream catalog: not inlined (catalog mode: lazy).
Discover tools:
- `(catalog/search-tools "query" {:limit 8})`
- `(catalog/describe-tool "server" "tool")`
- `(catalog/list-tools "server" {:limit 20})`
Call: `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.
catalog/* ops have their own budget and never consume the upstream-call quota.
<!-- PTC_PROMPT_END -->
