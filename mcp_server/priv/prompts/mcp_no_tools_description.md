# MCP no-tools description

<!-- version: 1 -->
<!-- date: 2026-05-19 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tool-description -->
<!-- budget: target<=350 bytes, hard<=500 bytes -->
<!-- priority: purpose, no app tools, context, stateless calls -->

<!-- PTC_PROMPT_START -->
Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. No app tools are available inside the program. Pass external data via the `context` argument; each invocation is independent - there is no memory of prior calls.
<!-- PTC_PROMPT_END -->
