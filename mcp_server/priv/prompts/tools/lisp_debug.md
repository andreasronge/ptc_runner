# lisp_debug

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_debug -->
<!-- mcp-profiles: lisp_debug_description -->

<!-- PTC_PROMPT_START -->
Read-only diagnostics for this MCP server. Inspect recent `tools/call` activity: aggregate stats, recent calls, or one redacted call record by `request_id`. Data is a bounded in-memory window since server start and payloads are redacted.
<!-- PTC_PROMPT_END -->
