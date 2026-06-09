# lisp_session_eval with upstreams

<!-- version: 1 -->
<!-- date: 2026-06-09 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_eval -->
<!-- mcp-profiles: mcp_session_eval_with_upstreams_description -->
<!-- composed-with: reference.md after this card; optional dynamic catalog after reference -->

<!-- PTC_PROMPT_START -->
Upstream discovery snapshot below. Live: `(tool/servers)`, `(apropos "query" {:limit 8})`, `(dir "server" {:limit 20})`, `(doc "server/tool")`.
Discovery inspects upstream schemas only; `dir` lists names/descriptions, `doc` shows args/result. Execute: `(tool/call {:server "server" :tool "tool" :args {...}})` -> `Result<T>`: `{:ok true :value T}` or `{:ok false :reason kw :message text}`. Check `:ok`; `:raw` optional.

PTC-Lisp against committed session memory
- `def`/`defn` persist for later evals in the same session
- Use `let` for temporary values
- `output_schema` validates result; mismatch rejects the commit.

Use `(map tool/call calls)` for batches. Raw schema/debug: `(meta "server/tool")`.
Unknown result shape: inspect `(keys (:value r))` or `(pr-str (:value r))`; use `(fail (:message r))` for unhandled faults.
<!-- PTC_PROMPT_END -->
