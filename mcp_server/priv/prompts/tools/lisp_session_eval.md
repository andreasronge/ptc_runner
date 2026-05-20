# lisp_session_eval

Composed with: `../reference.md` after this card.

<!-- PTC_PROMPT_START -->
Evaluates PTC-Lisp against committed session memory.
- Requires `session_id` and `program`.
- `(def name value)` and `(defn name [args] body)` persist for later evals in the same session.
- Use `let` for temporary values.
- `*1`, `*2`, and `*3` reference the last three successful eval results.
- `context` keys are under `data/`; context itself is not persisted.
- Optional `output_schema` validates the program return. On mismatch, eval is rejected and session state is not committed.
<!-- PTC_PROMPT_END -->
