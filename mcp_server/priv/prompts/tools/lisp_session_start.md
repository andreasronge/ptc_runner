# lisp_session_start

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_start -->
<!-- mcp-profiles: mcp_session_start_description -->

<!-- PTC_PROMPT_START -->
Creates a new empty stateful PTC-Lisp session. Optionally pass `preludes` to freeze versioned capability prelude refs into this session; the response returns them as `prelude_refs`. Use the returned `session_id` with `lisp_session_eval`. If attached prompt-visible preludes exist, the response includes compact namespace docs and discovery forms. `mode` defaults to `read_only`; use `write_capable` only when the server explicitly enables prelude authoring.
<!-- PTC_PROMPT_END -->
