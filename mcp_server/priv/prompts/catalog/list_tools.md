# catalog/list-tools

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-catalog-guidance -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- composed-with: sibling catalog/* cards in the catalog guidance block -->

<!-- PTC_PROMPT_START -->
`(catalog/list-tools "server-name" {:limit 20})` returns compact tool description strings for one configured upstream server.
Options: `:limit` is 1..200 and defaults to 50; `:offset` is a non-negative integer and defaults to 0.
Use it when you already know the server and need candidate tool names.
<!-- PTC_PROMPT_END -->
