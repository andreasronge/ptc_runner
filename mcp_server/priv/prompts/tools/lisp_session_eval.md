# lisp_session_eval

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_eval -->
<!-- mcp-profiles: mcp_session_eval_description -->
<!-- composed-with: reference.md after this card -->

<!-- PTC_PROMPT_START -->
Evaluates PTC-Lisp against committed session memory.
- Requires `session_id` and `program`.
- `(def name value)` and `(defn name [args] body)` persist for later evals in the same session.
- Use `let` for temporary values.
- `*1`, `*2`, and `*3` reference the last three successful eval results.
- `context` keys are under `data/`; context itself is not persisted.
- Optional `output_schema` validates the program return. On mismatch, eval is rejected and session state is not committed.
<!-- PTC_PROMPT_END -->
