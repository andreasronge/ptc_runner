# agentic catalog discovery

<!-- version: 1 -->
<!-- date: 2026-05-21 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-agentic-catalog-guidance -->
<!-- budget: target<=650 bytes, hard<=850 bytes -->

<!-- PTC_PROMPT_START -->
Discover: `(mcp/servers)`, `(apropos "query" {:limit 8})`, `(dir "server" {:limit 20})`, `(doc "server/tool")`, `(meta "server/tool")`.
Discovery inspects only; `doc` shows args/result. Execute only with `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.
Discovery ops have their own budget and never consume the upstream-call quota.
<!-- PTC_PROMPT_END -->
