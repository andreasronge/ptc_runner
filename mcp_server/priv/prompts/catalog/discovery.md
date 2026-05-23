# catalog discovery

<!-- version: 1 -->
<!-- date: 2026-05-21 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-catalog-guidance -->
<!-- budget: target<=500 bytes, hard<=700 bytes -->

<!-- PTC_PROMPT_START -->
Discover: `(mcp/servers)`, `(apropos "query" {:limit 8})`, `(dir "server" {:limit 20})`, `(doc "server/tool")`, `(meta "server/tool")`.
Discovery inspects only; `doc` shows args/result. Execute only with `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.
<!-- PTC_PROMPT_END -->
