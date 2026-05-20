# lisp_session_eval with upstreams

Composed with: `../reference.md` after this card; optional dynamic catalog after reference.

<!-- PTC_PROMPT_START -->
Evaluates PTC-Lisp against committed session memory, with upstream MCP calls available.
- Requires `session_id` and `program`.
- Explicit `def`/`defn` forms persist after successful evals; rejected evals do not commit state.
- Call upstreams with `(tool/mcp-call {:server s :tool t :args {...}})`.
- Inspect `:ok` before using `:value`; persist only derived values you need again.
- `context` keys are under `data/`; context and temporary tool caches are not persisted.
- Optional `output_schema` validates the program return. On mismatch, eval is rejected and session state is not committed.
<!-- PTC_PROMPT_END -->
