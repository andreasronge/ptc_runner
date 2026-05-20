# Agentic real-provider eval findings

Issue: #931
Date: 2026-05-13
Model: `gemini-flash-lite` (`openrouter:google/gemini-3.1-flash-lite`)
Runs per cell: 1
Upstream: local filesystem MCP server rooted at the repository root

Command, from `mcp_server/`:

```bash
mix run --no-start bench/agentic_real_eval.exs \
  --runs=1 \
  --models=gemini-flash-lite \
  --catalog-modes=inline,lazy \
  --json-out=../tmp/agentic_real_eval.json \
  --md-out=../tmp/agentic_real_eval.md \
  --fail-on-skip
```

The command exited non-zero because two eval cells failed. That is the
intended behavior for this harness when any real-provider case fails.

## Summary

| Model | Catalog mode | Case | Pass | Median ms | Planner ms | Prompt bytes | Completion bytes | Upstream calls | Catalog op mentions |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| gemini-flash-lite | inline | multi_file_reduce | 1/1 | 2156 | 2013 | 4907 | 911 | 1 | 0 |
| gemini-flash-lite | inline | negative_missing_capability | 1/1 | 1840 | 1804 | 4890 | 277 | 1 | 0 |
| gemini-flash-lite | inline | retry_after_bad_path_type | 1/1 | 1376 | 1278 | 5046 | 565 | 2 | 0 |
| gemini-flash-lite | inline | single_read | 1/1 | 3015 | 2334 | 4854 | 518 | 1 | 0 |
| gemini-flash-lite | lazy | lazy_catalog_discovery | 0/1 | 1557 | 1478 | 3157 | 1052 | 0 | 3 |
| gemini-flash-lite | lazy | multi_file_reduce | 0/1 | 2047 | 1928 | 3157 | 874 | 2 | 0 |
| gemini-flash-lite | lazy | negative_missing_capability | 1/1 | 2529 | 2352 | 3140 | 1098 | 0 | 2 |
| gemini-flash-lite | lazy | retry_after_bad_path_type | 1/1 | 1211 | 1157 | 3296 | 453 | 2 | 0 |
| gemini-flash-lite | lazy | single_read | 1/1 | 1549 | 1441 | 3104 | 671 | 1 | 2 |

## Findings

- Inline mode passed all four non-lazy-only cases in this one-sample run.
- Lazy mode reduced planner prompt bytes from roughly 4.9-5.0 KB to
  roughly 3.1-3.3 KB for comparable tasks.
- The lazy `single_read` case passed, but the generated program used
  catalog builtins before the filesystem read, confirming that the case
  is exercising runtime catalog discovery.
- The lazy `multi_file_reduce` case failed after reading `README.md`
  successfully, then attempting `mcp_server/README.md` from the wrong
  effective filesystem base path.
- The lazy `lazy_catalog_discovery` case failed before any upstream tool
  call. The generated program referenced catalog operations, but the
  executor exhausted the one-turn limit after catalog/list handling failed.
- `catalog_op_mentions` is inferred from generated program text because
  `lisp_task` does not yet expose catalog operation counts as structured
  metrics.
- ReqLLM warns that `openrouter:google/gemini-3.1-flash-lite` is not in
  its local model catalog. Provider-reported token fields were still
  present in `ptc_metrics.server_side_llm` for this run.
