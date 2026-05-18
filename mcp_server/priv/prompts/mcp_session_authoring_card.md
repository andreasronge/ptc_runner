# PTC-Lisp sessions

<!-- version: 1 -->
<!-- date: 2026-05-18 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tool-description -->
<!-- budget: target<=700 bytes, hard<=1000 bytes -->
<!-- priority: persisted defs, println capture, result history -->

<!-- PTC_PROMPT_START -->
PTC-Lisp sessions:
- Stateful PTC-Lisp eval. `(def name value)` and `(defn name [args] body)` persist for later `ptc_session_eval` calls in the same session.
- Use `let` for temporary values.
- `println` output is captured and returned; it is not stdout.
- `*1`, `*2`, and `*3` reference the last three successful eval results.
- Use `ptc_session_forget` to remove stale or large bindings.
- Keep programs short; store only values needed again.
<!-- PTC_PROMPT_END -->
