# lisp_eval with upstreams

<!-- version: 1 -->
<!-- date: 2026-05-20 -->
<!-- prompt-guidelines: priv/prompts/README.md -->
<!-- audience: mcp-tools-list -->
<!-- budget: target<=1500 bytes, hard<=2000 bytes -->
<!-- mcp-tools: lisp_eval -->
<!-- mcp-profiles: mcp_aggregator_description -->
<!-- composed-with: reference.md after this card; optional dynamic catalog after reference -->

<!-- PTC_PROMPT_START -->
Synthetic discovery snapshot below. Live: `(mcp/servers)`, `(apropos "query" {:limit 8})`, `(dir "server" {:limit 20})`, `(doc "server/tool")`, `(meta "server/tool")`.
Discovery inspects schemas only. Execute: `(tool/mcp-call {:server "server" :tool "tool" :args {...}})` -> `Result<T>`: `{:ok true :value T}` or `{:ok false :reason kw :message text}`. Check `:ok`; `:raw` optional.

One stateless PTC-Lisp program
Final value = result
No persistence across calls

`doc` shows args/result. Use `(map tool/mcp-call calls)` for batches.
Unknown result shape: inspect `(keys (:value r))` or `(pr-str (:value r))`; use `(fail (:message r))` for unhandled faults.
<!-- PTC_PROMPT_END -->
