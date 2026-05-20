# catalog/describe-tool

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-catalog-guidance -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- composed-with: sibling catalog/* cards in the catalog guidance block -->

<!-- PTC_PROMPT_START -->
`(catalog/describe-tool "server-name" "tool-name")` returns one detailed tool description string, including a call example.
Use it before `tool/mcp-call` when arguments or result shape are unclear.
<!-- PTC_PROMPT_END -->
