# lisp_session_start

<!-- version: 1 -->
<!-- date: 2026-07-03 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_start -->
<!-- mcp-profiles: mcp_session_start_description -->

<!-- PTC_PROMPT_START -->
Creates a new empty stateful PTC-Lisp session. Optionally pass `preludes` to freeze versioned capability prelude refs; the response returns `prelude_refs`. With a configured store and no separate runtime prelude, read-only sessions can inspect store preludes via `prelude/forms`, `prelude/form`, and related read forms. If attached prompt-visible preludes exist, the response includes compact namespace docs and discovery forms. Use the returned `session_id` with `lisp_session_eval`. `mode` defaults to `read_only`; use `write_capable` only when the server explicitly enables prelude authoring.
<!-- PTC_PROMPT_END -->
