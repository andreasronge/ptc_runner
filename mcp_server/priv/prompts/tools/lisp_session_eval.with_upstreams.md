# lisp_session_eval with upstreams

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1000 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_session_eval -->
<!-- mcp-profiles: mcp_session_eval_with_upstreams_description -->
<!-- composed-with: reference.md after this card; optional dynamic catalog after reference -->

<!-- PTC_PROMPT_START -->
Tools below. For details:
- `(catalog/describe-tool "server" "tool")`
- `(catalog/search-tools "query" {:limit 8})`
- `(catalog/list-tools "server" {:limit 20})`
Call: `(tool/mcp-call {:server "server" :tool "tool" :args {...}})`.

Evaluates PTC-Lisp against committed session memory
- `def`/`defn` persist for later evals in the same session
- Use `let` for temporary values
- `output_schema` validates result; mismatch rejects the commit.

Upstreams:
`(tool/mcp-call {:server s :tool t :args {...}})`
=> `Result<T>`: success `{:ok true :value T}`; failure `{:ok false :reason kw :message text}`.
Catalog `-> Result<T>` shows T. Check `:ok`.
Wrap `tool/mcp-call` in `fn`/`#(...)` for higher-order use.

Unknown result shape:
- Check `:ok`; inspect with `println`: `(keys (:value r))` or `(pr-str (:value r))`.
- Use `(fail (:message r))` for unhandled upstream faults.
<!-- PTC_PROMPT_END -->
