# PtcRunner MCP — PTC Payload Reduction Metrics

| Field | Value |
|---|---|
| Status | Draft |
| Date | 2026-05-12 |
| Prerequisite | **PR #903** (`feat/mcp-debug-tool`) — `Plans/ptc-runner-mcp-debug-tool.md`. This builds on the `upstream_calls[]` decoration and the `lisp_debug` tool. Implement *after* #903 merges; if implementing before, branch off `feat/mcp-debug-tool`, not `main`. |
| Related | `Plans/ptc-runner-mcp-aggregator.md` (the `upstream_calls[]` entry shape, `--max-upstream-response-bytes`), `Plans/agentic-mcp-aggregator.md` + `Plans/agentic-lisp-task-subagent-spec.md` (`lisp_task`, the planner LLM, `Agentic.Ledger`), `Plans/ptc-runner-mcp-server.md` (envelope contracts, `outputSchema`) |
| Decision basis | User use-case + Codex consult (2026-05-12, session `019e16f7`): per-call metric on the response envelope is the source of truth; `lisp_debug` aggregates; name it **payload reduction**, not "tokens saved"; expose honest separate fields, never a fabricated optimistic number; surface the server-side planner cost for `lisp_task` or the ratio is a lie |
| Revision | rev 2 (2026-05-12), review-tightened: `lisp_task.final_result_bytes` defined as JSON bytes of `{answer, structured_result}`; "client context reduction" → "answer/result payload reduction" (the MCP envelope mirrors the full structured payload — `ptc_metrics`, `upstream_calls`, `prints`, `feedback` — into `content[0].text`, so the literal response is larger than `final_result_bytes`); errors → `final_result_bytes: 0` and ratio `null` (Q4 resolved, consistent with §4.2); planner `prompt_bytes` = **all** message bytes sent to the provider incl. the fixed system message, not just the built prompt string; `oversize` → `result_bytes: null` is explicitly acceptable, don't parse detail strings; Q1/Q4/Q5 resolved |

## 1. Summary

Programmatic Tool Calling's whole point is that the LLM writes a program that fetches from upstream MCP tools and **collapses** the results down to a small answer before handing it back. Today the server discards that fact. This adds a deterministic, honest accounting of it:

- **Per-call**, on the `lisp_eval` (aggregator mode) and `lisp_task` response envelopes: each `upstream_calls[]` entry gains `result_bytes` (+ `oversize`), and the envelope gains a `ptc_metrics` block — `final_result_bytes`, `upstream_result_bytes`, `payload_reduction_ratio`, plus labeled token *estimates* and (for `lisp_task`) a `server_side_llm` line item for the hidden planner cost.
- **Aggregate**, in `lisp_debug stats` (gated by `--debug-tool` as today): a `payload_reduction` section — totals, p50/p95 ratio, top-N reducers, oversize/error counts, planner-token aggregates. `lisp_debug recent`/`get` records carry the per-call `ptc_metrics` and the new `upstream_calls[]` fields.

The headline framing is **"how much upstream tool-result payload the program collapsed into its answer"** — a real number the server can measure: `payload_reduction_ratio` = `upstream_result_bytes / final_result_bytes`. It is *not* "tokens saved by PTC" (that would require measuring the counterfactual no-PTC workflow and the server-side LLM usage, which the server cannot). And it is **not** the literal reduction in the MCP response the client receives — `Envelope.success/1` mirrors the full structured payload (the `ptc_metrics` block itself, the `upstream_calls` list, `prints`, `feedback`) into `content[0].text`, so the actual response is larger than `final_result_bytes`; the ratio is "the answer the program produced vs the upstream material it consumed", not "frame bytes in vs frame bytes out". Bytes are primary; token figures are explicitly estimates.

Nothing here changes the *no-tools* `lisp_eval` profile (no upstreams → no `ptc_metrics`), and `ptc_metrics` is additive — never breaks an existing client.

## 2. Motivation

The interesting question a client (or an operator, or a benchmark) wants answered: *"This `lisp_eval` call fetched 240 KB from three GitHub tool calls and the answer it returned is 1.8 KB — that's ~130× less upstream tool-result material than I'd have seen calling those tools directly."* That number is the value proposition of this whole server, and it's sitting right there in every aggregator-mode response (final result + the upstream calls that produced it) — the server just throws it away.

The honest version is narrow: it's the **upstream-result payload the program collapsed into its answer**, not total token cost, and not the literal MCP-response size. It excludes:
- the upstream **tool schemas/descriptions** a non-PTC client would have injected into context (separate baseline, not measured here),
- the **re-fetch / orchestration inefficiency** an LLM doing the same multi-step task with raw tool calls would incur (not measurable),
- prompt/system overhead (not the server's to know),
- and for `lisp_task`, the **server-side planner LLM** tokens (real cost, surfaced as a *separate* line item — see §6).

So this spec deliberately reports **separate, conservative fields** rather than one inflated "savings" number, and marks the optimistic baseline as `available: false` rather than inventing it.

## 3. Core principles

- **The per-call response envelope is the source of truth.** It already has the causal evidence (final result bytes + the `upstream_calls[]` it produced). `lisp_debug` *summarizes* this history; it never computes anything the per-call response didn't already carry.
- **Bytes are primary, deterministic, redaction-independent.** `result_bytes` is the size of the upstream response *as the aggregator received it* — before `--trace-payloads` redaction, before the count-bounded ring, before any envelope size cap. Token figures are estimates only, always labeled `token_estimate_method: "utf8_bytes_div_4"` (a real tokenizer is a future option, not v1).
- **Name it "payload reduction", not "tokens saved".** The headline is `payload_reduction_ratio` over upstream-result bytes; "tokens saved" is marketing language the data doesn't support.
- **Never fabricate the optimistic baseline.** The conservative baseline ("bytes of successful upstream tool results the program fetched") is reported; the optimistic one ("what an LLM would have spent doing this without PTC") is `{ "available": false }`.
- **`lisp_task` must surface the planner cost.** `payload_reduction_ratio` for `lisp_task` is *answer/result-payload reduction only*; the server-side planner LLM usage is a separate `server_side_llm` block, with an `efficiency_note` saying the ratio excludes it.
- **Additive & opt-out-safe.** `ptc_metrics` and the new `upstream_calls[]` fields are additive to existing envelopes. `lisp_debug` stays behind `--debug-tool`. No new flags introduced by this feature (token estimation has no knob; if a real tokenizer is added later that's a new flag then).
- **Honesty invariants are hard rules** (§7), not "nice to have": denominator guards, oversize/error exclusion, pre-redaction sizes, explicit `null` (never `0` or `∞`) for undefined ratios, v1's "all successful calls" baseline flagged as an upper bound on the denominator.

## 4. Data shapes (the contract)

These are the exact JSON shapes. A subagent implements *to these*.

### 4.1 `upstream_calls[]` entry — additions

Today (per `Plans/ptc-runner-mcp-aggregator.md` and `DebugRecorder.redacted_upstream_calls/1`): `{ server, tool, status, duration_ms, reason }` (plus optional `auth`, `http_status` etc. on the envelope decoration; `DebugRecorder` keeps the first five). Add two fields, to **both** the envelope decoration and the `DebugRecorder` projection:

```json
{
  "server": "github",
  "tool": "search_issues",
  "status": "ok",
  "duration_ms": 142,
  "reason": null,
  "result_bytes": 48122,        // NEW: byte size of the upstream response as received by the
                                // aggregator (pre-redaction). null when not applicable / unknown.
  "oversize": false             // NEW: true iff the response exceeded --max-upstream-response-bytes
                                // (→ the program received nil, not the data). When oversize is
                                // true, result_bytes is the exact size only if it is cheaply known;
                                // `null` is acceptable and expected for HTTP-overflow paths that
                                // abort without retaining a byte count. Do NOT parse human-readable
                                // detail strings to recover a number.
}
```

- For `status: "ok"` calls: `result_bytes` = exact byte size of the response payload the program received; `oversize: false`.
- For `status: "error"` / world-fault calls (`timeout`, `upstream_unavailable`, `upstream_error`, `cap_exhausted`): `result_bytes` = bytes received before the failure if any (often `0`/`null`), `oversize: false`. These bytes do **not** count toward `upstream_result_bytes` (§4.2) — they're failures, not useful compression.
- For `status` ... `reason: "response_too_large"`: `oversize: true`, `result_bytes` = the exact size if cheaply known, else `null` (the overflow path may halt without retaining a count — `null` is fine). These bytes do **not** count toward `upstream_result_bytes` either — the data never reached the program. The count of such calls is `upstream_oversize_count`; their bytes (when known) are summed into `upstream_oversize_bytes`.
- `Agentic.Ledger` already has `result_bytes`; this spec adds `oversize` to the ledger entry and ensures both flow into the `lisp_task` `upstream_calls[]` projection.

### 4.2 `ptc_metrics` — on the `lisp_eval` (aggregator mode) envelope

Attached next to the existing `upstream_calls` decoration, on **both** success and error envelopes, **only in the `:mcp_aggregator` profile and only when the program made ≥ 1 upstream call** (no upstream calls → no `ptc_metrics`; nothing to measure):

```json
{
  "ptc_metrics": {
    "schema_version": 1,

    "final_result_bytes": 812,                 // byte_size of the `result` field returned to the
                                               // client (the program's answer; NOT prints/feedback/
                                               // upstream_calls). 0 on error or empty result.
    "prints_bytes": 0,                          // byte_size of the serialized `prints` array (also
                                               // returned to the client; separate so the headline
                                               // ratio isn't muddied by debug prints).

    "upstream_call_count": 3,
    "upstream_ok_count": 3,
    "upstream_error_count": 0,
    "upstream_oversize_count": 0,

    "upstream_result_bytes": 48122,             // Σ result_bytes over status==ok, non-oversize calls.
                                               // THIS is the conservative baseline / the denominator
                                               // source.
    "upstream_error_bytes": 0,                  // Σ result_bytes over failed calls (informational).
    "upstream_oversize_bytes": 0,               // Σ result_bytes over oversize calls (informational).

    "payload_reduction_ratio": 59.26,           // round(upstream_result_bytes / max(final_result_bytes, 1), 2).
                                               // null when upstream_result_bytes == 0 OR
                                               // final_result_bytes == 0 (see §7). Never 0, never ∞.

    "estimated_final_result_tokens": 203,       // ceil(final_result_bytes / 4)
    "estimated_upstream_result_tokens": 12031,  // ceil(upstream_result_bytes / 4)
    "token_estimate_method": "utf8_bytes_div_4",

    "baseline": {
      "conservative": {
        "name": "successful_upstream_results_only",
        "bytes": 48122,
        "ratio": 59.26,
        "note": "Σ bytes of successful, non-oversize upstream tool responses the program fetched. Upper bound on the true denominator: a program may fetch data it then discards. Excludes upstream tool schemas/descriptions and any no-PTC orchestration overhead. Not equal to the literal MCP response size: the envelope mirrors the full structured payload (this `ptc_metrics` block, `upstream_calls`, `prints`, `feedback`) into `content[0].text`, so the actual response the client receives is larger than `final_result_bytes`."
      },
      "optimistic": {
        "name": "no_ptc_direct_llm_workflow",
        "available": false,
        "note": "What an LLM would have spent doing this task with direct tool calls (incl. tool-schema injection, re-fetching, prompt overhead) is not measurable by the server."
      }
    }
  }
}
```

### 4.3 `ptc_metrics` — on the `lisp_task` envelope

Same block as §4.2, plus a `server_side_llm` line item and an `efficiency_note`. Attached on both success and error `lisp_task` envelopes whenever the SubAgent made ≥ 1 upstream call (if it made none, still attach the block — the planner ran regardless — but `upstream_result_bytes: 0` and `payload_reduction_ratio: null`).

`lisp_task` has no single `result` field — it returns `answer` + `structured_result` (and `warnings`, `planner`, `execution`, `upstream_calls`, `trace_id`; see `mcp_server/lib/ptc_runner_mcp/agentic.ex`). So define **`final_result_bytes` for `lisp_task` = `byte_size(Jason.encode!(%{"answer" => answer, "structured_result" => structured_result}))`** — the user-facing answer subset, mirroring how §4.2's `final_result_bytes` is the `lisp_eval` `result` field. On error: `final_result_bytes: 0`, `payload_reduction_ratio: null` (same rule as §4.2 — no inconsistency).

```json
{
  "ptc_metrics": {
    "schema_version": 1,
    "final_result_bytes": 1200,                  // byte_size(Jason.encode!(%{"answer"=>..,"structured_result"=>..})); 0 on error
    "prints_bytes": 0,                            // byte_size of the lisp_task response's `prints`-equivalent if it has one, else 0 (shape parity with §4.2)
    "upstream_call_count": 4,
    "upstream_ok_count": 4,
    "upstream_error_count": 0,
    "upstream_oversize_count": 0,
    "upstream_result_bytes": 90000,
    "upstream_error_bytes": 0,
    "upstream_oversize_bytes": 0,
    "payload_reduction_ratio": 75.0,
    "estimated_final_result_tokens": 300,
    "estimated_upstream_result_tokens": 22500,
    "token_estimate_method": "utf8_bytes_div_4",

    "server_side_llm": {
      "planner_calls": 1,                       // number of LLM calls the SubAgent made (planner + retries)
      "provider_reported": true,                 // true iff the LLM adapter surfaced real usage
      "prompt_tokens": 8412,                     // real provider count, or null when provider_reported == false
      "completion_tokens": 901,                  // real provider count, or null when provider_reported == false
      "total_tokens": 9313,                      // real, or null
      "prompt_bytes": 33648,                     // byte size of ALL message content sent to the provider —
                                                 // the fixed system message + the built user prompt (+ any
                                                 // prior turns) — NOT just the dynamically-built prompt string.
                                                 // (Today `Planner.call/3` counts only `byte_size(prompt)`; this
                                                 // must be widened to include the system content too.) Always available.
      "completion_bytes": 3604,                  // byte size of the completion(s) received from the provider. Always available.
      "estimated_prompt_tokens": 8412,           // ceil(prompt_bytes / 4) — present even when provider_reported
      "estimated_completion_tokens": 901,        // ceil(completion_bytes / 4)
      "estimate_method": "utf8_bytes_div_4"
    },

    "efficiency_note": "payload_reduction_ratio is answer/result-payload reduction only. It excludes (a) the server-side planner LLM usage in `server_side_llm` (real cost), and (b) the MCP envelope overhead the client also receives — `prints`, `feedback`, the `upstream_calls` list, this `ptc_metrics` block itself — all mirrored into `content[0].text`. Total token/cost efficiency vs a no-PTC workflow is not computed.",

    "baseline": { "conservative": { ... as §4.2 ... }, "optimistic": { "name": "no_ptc_direct_llm_workflow", "available": false, "note": "..." } }
  }
}
```

**`provider_reported`**: implementer checks what `Agentic.Planner`'s LLM call returns. If the adapter (`PtcRunner.LLM.ReqLLMAdapter` / `ReqLLM`) surfaces `usage` (input/output tokens), record it (`provider_reported: true`, real counts). If not, `provider_reported: false`, the `*_tokens` fields are `null`, and clients fall back to `estimated_*`. The `*_bytes` and `estimated_*` fields are always populated. **If wiring real usage turns out to be more than a small change, ship the byte-estimate-only version (`provider_reported: false`) and file a follow-up issue — do not block the rest of the feature on it.**

### 4.4 `lisp_debug stats.payload_reduction` — aggregate

Added to the `stats` payload (alongside `by_tool`, `errors`, `upstream_calls`, `agentic`). Omitted (or `null`) when the window contains no calls that carried a `ptc_metrics` block:

```json
{
  "payload_reduction": {
    "schema_version": 1,
    "calls_with_metrics": 42,                    // calls in the window that carried ptc_metrics
    "total_final_result_bytes": 51200,
    "total_upstream_result_bytes": 6553600,
    "total_upstream_error_bytes": 4096,
    "total_upstream_oversize_bytes": 0,
    "total_upstream_calls": 137,

    "reduction_ratio": { "p50": 41.0, "p95": 210.0, "max": 1840.0, "weighted": 128.0 },
                                                 // p50/p95/max over the per-call payload_reduction_ratio
                                                 // (excluding calls where it's null). `weighted` =
                                                 // total_upstream_result_bytes / max(total_final_result_bytes, 1).

    "estimated_tokens": { "final_result": 12800, "upstream_result": 1638400, "method": "utf8_bytes_div_4" },

    "top_reducers": [                            // up to 10, by per-call ratio, newest tie-break
      { "request_id": "abc-123", "ts": "2026-05-12T09:01:02.123Z", "tool": "lisp_eval",
        "final_result_bytes": 200, "upstream_result_bytes": 368000, "ratio": 1840.0 }
    ],

    "agentic_planner": {                         // present only if the window has lisp_task calls
      "tasks": 7,
      "provider_reported_tasks": 7,
      "total_prompt_tokens": 58900, "total_completion_tokens": 6307,    // real, or null if any task lacked it
      "total_prompt_bytes": 235600, "total_completion_bytes": 25228,
      "estimated_total_tokens": 65207
    }
  }
}
```

### 4.5 `lisp_debug recent` / `get` records — additions

The ring record (per `Plans/ptc-runner-mcp-debug-tool.md` §5.1) already keeps a redacted `upstream_calls` list. Add: `result_bytes` + `oversize` to each entry, and a `ptc_metrics` field (the §4.2/§4.3 block — already small, no extra redaction needed; it's pure counts/ratios, no payload). `recent_call_json` surfaces `ptc_metrics`; `full_record_json` (the `get` view) surfaces the full per-entry `upstream_calls` incl. `result_bytes`.

## 5. `outputSchema` updates

- `Tools.output_schema_for(:mcp_aggregator)` — add an optional `ptc_metrics` property (a generic `{"type": ["object", "null"]}` is fine; the discriminated `oneOf` stays keyed on `status`) and add `result_bytes` / `oversize` to the `upstream_calls[]` item schema.
- The `lisp_task` `outputSchema` (in `PtcRunnerMcp.Agentic`) — same additions.
- `DebugTool.output_schema/0` — the `stats` `oneOf` branch gains an optional `payload_reduction` property; the `recent` branch's `calls[]` and the `get` branch's `record` are already `array`/`{}` so no schema change needed there (but the spec'd shapes change).
- v1 `:mcp_no_tools` profile `outputSchema` is **unchanged** (no upstreams, no `ptc_metrics`).

## 6. Where it hooks in (per file)

Explore each before changing it (per CLAUDE.md). Likely targets:

| Concern | File(s) |
|---|---|
| Aggregator measures the upstream response size (for `--max-upstream-response-bytes`); record it | `mcp_server/lib/ptc_runner_mcp/aggregator_tools.ex` (the `tool/mcp-call` impl + the `[:ptc_runner_mcp, :upstream, :call]` span) |
| `upstream_calls[]` entry construction (ok/error entries) | `mcp_server/lib/ptc_runner_mcp/upstream_calls.ex` (`UpstreamCalls`; the `DebugRecorder` comment references `UpstreamCalls.error_entry/5`) |
| Agentic per-upstream-call accounting | `mcp_server/lib/ptc_runner_mcp/agentic/ledger.ex` (already has `result_bytes`; add `oversize`), `mcp_server/lib/ptc_runner_mcp/agentic/mcp_call.ex` (the SubAgent's upstream-call wrapper) |
| Agentic response projection → `upstream_calls[]` + `ptc_metrics` on the `lisp_task` envelope | `mcp_server/lib/ptc_runner_mcp/agentic/projection.ex`, `mcp_server/lib/ptc_runner_mcp/agentic.ex` |
| Planner LLM call — capture provider `usage` if available; count **all** message bytes sent (incl. the fixed system message), not just `byte_size(prompt)` | `mcp_server/lib/ptc_runner_mcp/agentic/planner.ex` (`Planner.call/3` already has a `"tokens"` slot — check whether it carries reliable provider usage before adding new plumbing; and it builds a system message + the prompt for `LLM.call`, so `prompt_bytes` must sum both) and how it calls `PtcRunner.LLM` / the ReqLLM adapter |
| The `ptc_metrics` builder (pure function) | **NEW:** `mcp_server/lib/ptc_runner_mcp/payload_metrics.ex` — `build(final_result_bytes, prints_bytes, upstream_calls_entries, opts)` → the §4.2 map; `build/4` with a `server_side_llm:` opt → the §4.3 map. Used by both the `lisp_eval` aggregator path and the `lisp_task` path. No I/O, fully unit-testable. |
| `lisp_eval` aggregator-mode envelope decoration (where `upstream_calls` is attached today) | `mcp_server/lib/ptc_runner_mcp/tools.ex` (the success/error envelope decoration in the `:mcp_aggregator` profile; possibly `json_rpc.ex`'s `execute_with_aggregator` path) |
| `lisp_debug` recorder keeps the new fields | `mcp_server/lib/ptc_runner_mcp/debug_recorder.ex` (`redacted_upstream_calls/1` keeps `result_bytes`/`oversize`; the record map gains `ptc_metrics`) |
| `lisp_debug stats` aggregation | `mcp_server/lib/ptc_runner_mcp/debug_buffer.ex` (`stats/1` builds `payload_reduction`) |
| `lisp_debug` output formatting + outputSchema + size-cap shrink (drop `payload_reduction.top_reducers` first when over `--max-debug-response-bytes`) | `mcp_server/lib/ptc_runner_mcp/debug_tool.ex` |
| Docs | `mcp_server/README.md` (a "Payload reduction" subsection), `mcp_server/CHANGELOG.md`, `Plans/ptc-runner-mcp-aggregator.md` (the `upstream_calls[]` shape), cross-link from `Plans/ptc-runner-mcp-debug-tool.md` |

No changes to `:ptc_runner` (the main lib) are expected. No new telemetry events. No new CLI flags.

## 7. Honesty invariants (hard rules)

1. `result_bytes` / `upstream_result_bytes` / `final_result_bytes` are **pre-redaction** byte sizes (what the program / a no-PTC client would actually see). They are independent of `--trace-payloads` and `--max-debug-response-bytes`. Debug output that surfaces them says so.
2. `payload_reduction_ratio` = `round(upstream_result_bytes / max(final_result_bytes, 1), 2)`. It is `null` (JSON `null`, never `0`, never a sentinel like `-1` or `∞`) whenever `upstream_result_bytes == 0` **or** `final_result_bytes == 0`. (So: a pure-compute program, an all-upstream-calls-failed program, or an errored program → `null`.)
3. Only `status == "ok"` **and** `oversize == false` upstream calls contribute to `upstream_result_bytes`. Failed-call bytes → `upstream_error_bytes`. Oversize-call bytes → `upstream_oversize_bytes`. Neither inflates the ratio.
4. v1's denominator (`upstream_result_bytes`) is **all** successful upstream-result bytes the program fetched — an *upper bound* on the true "data that influenced the answer" (a program may fetch and discard). The `baseline.conservative.note` says this. A tighter, provenance-tracked `used_upstream_result_bytes` is an explicit Open Question (Q1), not v1.
5. The optimistic baseline is `{ "name": "no_ptc_direct_llm_workflow", "available": false, "note": "..." }`. **Never** populate it with a guess.
6. Token figures are estimates: every place a token count appears that isn't from a provider, it carries `token_estimate_method`/`estimate_method: "utf8_bytes_div_4"`. Provider-reported `lisp_task` planner tokens are the *only* non-estimate token figures; when absent, the field is `null` and `provider_reported: false` — never `0`.
7. For `lisp_task`, `payload_reduction_ratio` excludes `server_side_llm`; `efficiency_note` states this verbatim; `lisp_task` and `lisp_eval` are reported under the same `stats.payload_reduction` aggregate but `agentic_planner` is a distinct sub-block so the planner cost is never hidden.
8. `ptc_metrics` only appears when there's something to measure: `:mcp_aggregator` profile with ≥ 1 upstream call (`lisp_eval`), or any `lisp_task` call (the planner always ran). No `ptc_metrics` on `:mcp_no_tools` `lisp_eval`.
9. `final_result_bytes` is the **answer the program produced**: for `lisp_eval` the `result` field; for `lisp_task` `byte_size(Jason.encode!(%{"answer" => answer, "structured_result" => structured_result}))`. `prints` are reported separately as `prints_bytes`. The envelope's own framing (`feedback`, `upstream_calls`, `ptc_metrics` itself, and the duplication of all of it into `content[0].text` by `Envelope.success/1`) is *not* counted — it's protocol overhead, not "the answer". On error, `final_result_bytes` is `0` (and the ratio is `null` per #2) — do **not** try to count a partial/error-payload result; if partial-result accounting matters later, add a separate field.

## 8. Implementation plan (phases & ownership)

Designed so one or more subagents can build it. Phases A→B→C→D are sequential by dependency; B′ is parallel-ish to B but its output feeds B's `lisp_task` decoration, so a single agent should do B′ then B, or two agents must agree the `server_side_llm` shape (§4.3) up front. **A single subagent doing A→B′→B→C→D sequentially is the simplest and recommended.** If parallelizing, hand each worker §4's contract and the relevant §6 row.

- **Phase A — aggregator byte accounting (foundation).** Add `result_bytes` + `oversize` to `upstream_calls[]` for `lisp_eval` (aggregator mode) and to `Agentic.Ledger` + the `lisp_task` `upstream_calls[]` projection. Update `Plans/ptc-runner-mcp-aggregator.md`'s `upstream_calls[]` shape. Tests: an aggregator-mode program that calls an upstream tool → the envelope's `upstream_calls[]` entry has the right `result_bytes`; a `response_too_large` → `oversize: true`; a failed upstream call → `result_bytes` (0/null) not counted later. *No `ptc_metrics` yet.* Depends on: #903 (the decoration already exists).

- **Phase B′ — agentic planner token usage.** First check `Agentic.Planner.call/3`'s existing `"tokens"` slot — if it already carries reliable provider usage, route it through (`provider_reported: true`) and you're nearly done. Otherwise, capture `usage` from the provider response in the LLM-call path. Either way, thread `{provider_reported, prompt_tokens, completion_tokens, total_tokens, prompt_bytes, completion_bytes, planner_calls}` to the `lisp_task` envelope builder. `prompt_bytes` = byte size of **all** message content sent to the provider (the fixed system message + the built prompt + any prior turns), not just `byte_size(prompt)`. Byte counts always; provider tokens when surfaced (`null` + `provider_reported: false` otherwise). Tests: a `lisp_task` run → `server_side_llm` populated; with a stubbed adapter that reports usage → `provider_reported: true` with the stubbed numbers; without → `provider_reported: false`, `*_tokens: null`, `estimated_*` present; `prompt_bytes` includes the system message. **Escape hatch:** if real-usage plumbing is more than a small change, ship `provider_reported: false` everywhere + the byte estimates, file a follow-up, move on. Depends on: nothing (can start any time); coordinate the §4.3 `server_side_llm` shape with B.

- **Phase B — `ptc_metrics` envelope decoration.** New `PtcRunnerMcp.PayloadMetrics` pure module (§6 row). Decorate the `lisp_eval` (aggregator, ≥1 upstream call) and `lisp_task` envelopes with `ptc_metrics` (the `lisp_task` one includes B′'s `server_side_llm`). Implement every §7 invariant in `PayloadMetrics` (denominator guard, oversize/error exclusion, `null` ratios, token estimates, baseline blocks, `efficiency_note`). Update `Tools.output_schema_for(:mcp_aggregator)` and the `lisp_task` `outputSchema`. Tests: success envelope carries `ptc_metrics` with correct sums/ratio; **error envelope carries `ptc_metrics` with `final_result_bytes: 0` and `payload_reduction_ratio: null`** (and whatever upstream bytes were fetched); tiny-result → ratio sane (`null` only when numerator or denominator is 0); pure-compute / no-upstream-calls → no `ptc_metrics` (lisp_eval) or `ptc_metrics` with `null` ratio + `server_side_llm` (lisp_task); `:mcp_no_tools` lisp_eval → no `ptc_metrics`; `lisp_task` `final_result_bytes` == JSON bytes of `{answer, structured_result}`; outputSchema accepts the decorated envelopes. **`PayloadMetrics` deserves real unit tests** (it's where the math/honesty lives) — this is the exception to "no low-value unit tests". Depends on: A (+ B′ for the `lisp_task` part).

- **Phase C — `lisp_debug` aggregation & surfacing.** `DebugRecorder`: keep `result_bytes`/`oversize` per `upstream_calls[]` entry; copy the envelope's `ptc_metrics` into the ring record. `DebugBuffer.stats/1`: build `payload_reduction` (§4.4) — totals, p50/p95/max/weighted ratio (skip `null`s), `top_reducers`, `agentic_planner` sub-block. `DebugTool`: `stats` output includes `payload_reduction`; `recent`/`get` records carry `ptc_metrics` + the per-entry `result_bytes`; `outputSchema` `stats` branch gains `payload_reduction`; the size-cap `shrink(:stats)` step list drops `payload_reduction.top_reducers` first, then the `payload_reduction` block, before touching `by_server`/`by_tool`. Tests: drive a mix of aggregator-mode + `lisp_task` calls, then `lisp_debug op=stats` → `payload_reduction` totals/percentiles match the per-call `ptc_metrics`; `top_reducers` ordered by ratio; `recent`/`get` carry `ptc_metrics`; a `lisp_task` call's planner tokens show in `agentic_planner`; a `:mcp_no_tools`-only window → no `payload_reduction`. Depends on: B (and #903).

- **Phase D — docs.** `mcp_server/README.md` "Payload reduction" subsection (what `ptc_metrics` is, the honest framing, the `lisp_debug stats.payload_reduction` aggregate, the bytes-vs-tokens caveat, the `lisp_task` planner-cost line item); `mcp_server/CHANGELOG.md`; the `Plans/ptc-runner-mcp-aggregator.md` shape update (also done in A — final pass here); a cross-link line in `Plans/ptc-runner-mcp-debug-tool.md` ("see `ptc-runner-mcp-payload-reduction.md` for the `payload_reduction` stats section"). Depends on: A–C.

(All four phases are small-to-medium; can land in one PR or split A | B′+B | C+D.)

## 9. Quality gates & review (every PR)

Run from `mcp_server/` in the working tree/worktree: `mix format && mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix credo --strict`; `mix dialyzer`; `mix test` (all green). If there's a `mix precommit` / `mix prepush` alias (there is — see `mcp_server/mix.exs`), run those. Re-run any tool used to fix an issue to confirm. Then run `codex review --base <branch-point>` and fix findings (each with a regression test) until a clean pass — per `feedback_codex_review_gate.md` / `feedback_codex_rounds_subagent_code.md` (budget ~5–6 rounds, stop on the first clean one). Commit messages end with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`. Don't push unless asked. Note: a fresh worktree may lack the *root* `:ptc_runner` deps (the pre-push hook runs the root test suite) — this feature touches only `mcp_server/`, so `git push --no-verify` is acceptable if that's the only failure; say so in the PR.

## 10. Testing notes

- **Integration over low-value unit tests** (repo guideline) — *except* `PtcRunnerMcp.PayloadMetrics`, which is pure and is where the honesty math lives: give it focused unit tests covering every §7 invariant (denominator guard, `null` ratios for the 0-numerator / 0-denominator / error cases, oversize/error exclusion from `upstream_result_bytes`, token-estimate rounding, the `server_side_llm` provider-reported vs estimated branches, the `baseline` blocks always present with `optimistic.available: false`).
- Aggregator integration tests reuse the fake-upstream harness already used by the aggregator/agentic tests; assert the envelope `upstream_calls[]` and `ptc_metrics` match the fake upstream's response sizes.
- `lisp_task` tests: a stubbed planner LLM adapter — one variant that returns `usage`, one that doesn't — to exercise both `server_side_llm` branches.
- `lisp_debug` tests build on `debug_tool_test.exs`'s harness: drive calls, `flush_ring`, `op=stats`/`recent`/`get`, assert `payload_reduction` and the per-call `ptc_metrics`.
- Domain-blind: example programs/tasks in tests must not overlap existing test/benchmark domains (CLAUDE.md).

## 11. Non-goals / out of scope (v1)

- A real tokenizer (`cl100k_base` / provider-specific). v1 is `utf8_bytes_div_4`, clearly labeled; clients tokenize if they care. A future `--token-estimator <bytes-div-4|cl100k|...>` flag is possible later.
- Provenance tracking ("which upstream calls actually influenced the program's output") → `used_upstream_result_bytes`, a tighter denominator. v1 counts all successful calls (an upper bound) — see Q1.
- Measuring the no-PTC counterfactual (tool-schema injection bytes, LLM re-fetch/orchestration cost, prompt overhead) → the optimistic baseline. v1 reports `available: false`.
- `tool_catalog_bytes` (the size of the upstream tool schemas/descriptions the server advertises) as a separate baseline — interesting, but a distinct measurement; not part of "upstream-result payload reduction". Future.
- `ptc_metrics` on the `:mcp_no_tools` `lisp_eval` profile (no upstreams → nothing to measure).
- A trace-file / `ptc_viewer` rendering of `payload_reduction` — observability consumers; can come later off the same data.
- Streaming / per-`mcp-call` realtime metrics. v1 is per-completed-call.

## 12. Open questions

- **Q1 — resolved (deferred).** A tighter denominator (`used_upstream_result_bytes` — only bytes that actually influenced the program's output) needs Lisp-level provenance tracking, which doesn't exist and would be a `:ptc_runner` interpreter change far bigger than this spec. v1's "all successful upstream-result bytes" is the right answer; the upper-bound caveat is in `baseline.conservative.note` and §7 #4. Revisit only as its own project.
- **Q2 — resolved (keep separate), one possible future add.** `final_result_bytes` is the answer only; `prints_bytes` is separate; the headline ratio uses neither prints nor envelope overhead. A future `client_visible_answer_bytes = final_result_bytes + prints_bytes` could be added if real usage shows prints mattering — not v1.
- **Q3 — direction set, finalize in B′.** Use `Planner.call/3`'s existing `"tokens"` slot if it's a reliable provider count (→ `provider_reported: true`); else `provider_reported: false` + byte estimates. Byte estimates are fine for "is the planner overhead big or small", **not** for billing — the `estimate_method` label and `efficiency_note` say so. The only thing left to decide during B′ is whether the existing slot is trustworthy enough or new plumbing is needed; that's an implementation detail, not a spec question.
- **Q4 — resolved.** `ptc_metrics` **is** attached on error envelopes (the upstream bytes fetched + the error are useful diagnostics), with `final_result_bytes: 0` and `payload_reduction_ratio: null`. No partial/error-result accounting in v1 (consistent across §4.2, §4.3, §7 #9 — the earlier "from the error payload's result if any" wording is dropped).
- **Q5 — resolved (keep the naming).** `ptc_metrics` / `payload_reduction_ratio` / `payload_reduction`. `context_savings` overclaims; `compression` implies lossless. "Payload reduction" is accurate and hard to misread.
