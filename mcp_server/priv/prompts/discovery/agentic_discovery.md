# agentic REPL discovery

<!-- version: 1 -->
<!-- date: 2026-05-21 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-agentic-repl-discovery-guidance -->
<!-- budget: target<=650 bytes, hard<=850 bytes -->

<!-- PTC_PROMPT_START -->
Discover: `(mcp/servers)`, `(apropos "query" {:limit 8})`, `(dir "server" {:limit 20})`, `(doc "server/tool")`.
Discovery inspects only; `dir` lists names/descriptions, `doc` shows args/result. Execute only with `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`. Raw schema/debug: `(meta "server/tool")`.
Discovery ops have their own budget and never consume the upstream-call quota.
<!-- PTC_PROMPT_END -->
