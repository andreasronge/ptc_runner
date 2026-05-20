# catalog/search-tools

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-catalog-guidance -->
<!-- budget: target<=1000 bytes, hard<=1500 bytes -->
<!-- composed-with: sibling catalog/* cards in the catalog guidance block -->

<!-- PTC_PROMPT_START -->
`(catalog/search-tools "query" {:limit 8})` returns compact tool description strings matching the query.
Options: `:limit` is 1..50 and defaults to 8; `:load` is a boolean and defaults to false.
Use it first when you know the capability you need but not the server or tool name.
<!-- PTC_PROMPT_END -->
